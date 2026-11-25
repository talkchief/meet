#!/bin/sh
# HAProxy start for the meet-haproxy StatefulSet (k8s-pods/meet-haproxy/README.md).
# - The local peer is this pod's name (meet-haproxy-0 or -1, `haproxy -L`); it listens on 0.0.0.0.
# - The other peer's address is its pod IP from the headless Service meet-haproxy-peers. A pod IP
#   changes when that pod restarts, so a watchdog re-resolves it every 10 s and, when it changed,
#   re-renders the config and reloads HAProxy (SIGUSR2 to the master; the stick table is handed to
#   the new worker through the local peer). Until the other peer resolves (it may not be scheduled),
#   127.0.0.2 stands in: nothing is synced, routing still works by the hash.
# - TC_STARTED is set once here; a reload keeps it (startup grace in haproxy.cfg.template).
set -eu
SELF=$(hostname)
DOMAIN=meet-haproxy-peers.meet.svc.cluster.local
TEMPLATE=/usr/local/etc/haproxy/haproxy.cfg.template
CFG=/tmp/haproxy.cfg
TC_STARTED=$(date +%s)
export TC_STARTED

addr_of() {
  if [ "$1" = "$SELF" ]; then echo 0.0.0.0; return; fi
  a=$(getent hosts "$1.$DOMAIN" | awk '{print $1; exit}') || a=
  echo "${a:-127.0.0.2}"
}

render() {
  p0=$(addr_of meet-haproxy-0); p1=$(addr_of meet-haproxy-1)
  sed -e "s/@PEER0@/$p0/" -e "s/@PEER1@/$p1/" "$TEMPLATE" > "$CFG.new"
  if haproxy -c -q -L "$SELF" -f "$CFG.new"; then mv "$CFG.new" "$CFG"; fi
}

# Give the other pod up to 60 s to get its address (both start in parallel).
i=0
while [ $i -lt 30 ]; do
  render
  grep -q '127.0.0.2' "$CFG" 2>/dev/null || break
  i=$((i + 1)); sleep 2
done
[ -f "$CFG" ] || { echo "meet-haproxy event=config_invalid"; exit 1; }
grep -q '127.0.0.2' "$CFG" && echo "meet-haproxy event=peer_unresolved self=$SELF"

haproxy -W -db -L "$SELF" -f "$CFG" &
MASTER=$!
trap 'kill -USR1 "$MASTER" 2>/dev/null; wait "$MASTER"; exit 0' TERM INT

while kill -0 "$MASTER" 2>/dev/null; do
  sleep 10 &
  wait $! || true
  before=$(cat "$CFG")
  render
  if [ "$before" != "$(cat "$CFG")" ]; then
    echo "meet-haproxy event=peer_moved reload=1"
    kill -USR2 "$MASTER"
  fi
done
wait "$MASTER"

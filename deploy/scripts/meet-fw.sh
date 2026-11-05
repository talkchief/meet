#!/usr/bin/env bash
# Private-network allowlist (iptables DOCKER-USER) for a TalkChief Meet port
# that Docker publishes on a private IP. Hetzner Cloud Firewalls do not filter
# the private network and Docker-published ports bypass ufw, so without this
# every host on 10.1.0.0/16 could reach the port.
#
#   --role main   (default, main meeting host): Prosody c2s 5222 on
#                 PROSODY_C2S_BIND from /opt/talkchief-meet/.env. Allowed
#                 sources: /opt/talkchief-meet/bridges.allow, one private IPv4
#                 per line ("#" starts a comment). No file = nobody.
#   --role bridge (bridge node): JVB colibri 8080 on BRIDGE_PRIVATE_IP from
#                 /opt/talkchief-meet-bridge/.env. Allowed source: MAIN_PRIVATE_IP
#                 (the main host's monitor).
#
# Usage: meet-fw.sh [--role main|bridge] apply|remove|status
#
# apply is idempotent and atomic: the allowlist chain is rebuilt in one
# iptables-restore transaction, so the port is never briefly open. Everything
# not allowlisted is dropped. Matching on the conntrack original destination is
# needed because Docker DNATs published ports before FORWARD; container to
# container traffic (the main host's own jvb and jicofo reach Prosody on the
# compose network) has a different original destination and is not touched.
# IPv4 only: the port is published on an IPv4 address.
set -euo pipefail

ROLE=main
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE=${2:-}; shift 2 ;;
    --role=*) ROLE=${1#--role=}; shift ;;
    apply|remove|status) break ;;
    *) echo "usage: $0 [--role main|bridge] apply|remove|status" >&2; exit 64 ;;
  esac
done
ACTION=${1:-}
case "$ACTION" in apply|remove|status) ;; *) echo "usage: $0 [--role main|bridge] apply|remove|status" >&2; exit 64 ;; esac

valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && [ "$o" -le 255 ] || return 1
  done
}
is_private_ipv4() {   # RFC 1918
  valid_ipv4 "$1" || return 1
  local a b; IFS=. read -r a b _ _ <<<"$1"
  [ "$a" -eq 10 ] || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; }
}
# Last value wins, like docker compose and scripts/install.sh.
envval() { [ -r "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | tr -d '"'"'"'\r' || true; }

SOURCES=()
case "$ROLE" in
  main)
    DEST=${MEET_DEST:-/opt/talkchief-meet}
    ALLOW=${MEET_BRIDGES_ALLOW:-$DEST/bridges.allow}
    PORT=5222
    CHAIN=TC-MEET-XMPP
    DST=$(envval "$DEST/.env" PROSODY_C2S_BIND)
    # Still on the 127.0.0.1 default: nothing is published off-host, so the
    # rule is a no-op until the runbook moves the bind to the private IP.
    if ! is_private_ipv4 "$DST"; then DST=${MEET_PRIVATE_IP:-10.1.0.44}; fi
    is_private_ipv4 "$DST" || { echo "meet-fw: MEET_PRIVATE_IP '$DST' is not a private IPv4 address" >&2; exit 1; }
    if [ -f "$ALLOW" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}; read -r ip _ <<<"$line" || true
        [ -n "${ip:-}" ] || continue
        if is_private_ipv4 "$ip"; then SOURCES+=("$ip"); else echo "meet-fw: ignoring '$ip' in $ALLOW (not a private IPv4 address)" >&2; fi
      done <"$ALLOW"
    fi
    ;;
  bridge)
    DEST=${MEET_BRIDGE_DEST:-/opt/talkchief-meet-bridge}
    PORT=8080
    CHAIN=TC-MEET-COLIBRI
    DST=$(envval "$DEST/.env" BRIDGE_PRIVATE_IP)
    main_ip=$(envval "$DEST/.env" MAIN_PRIVATE_IP)
    is_private_ipv4 "$DST" || { echo "meet-fw: BRIDGE_PRIVATE_IP missing or invalid in $DEST/.env" >&2; exit 1; }
    is_private_ipv4 "$main_ip" || { echo "meet-fw: MAIN_PRIVATE_IP missing or invalid in $DEST/.env" >&2; exit 1; }
    SOURCES=("$main_ip")
    ;;
  *) echo "meet-fw: unknown role '$ROLE' (main or bridge)" >&2; exit 64 ;;
esac

# The rule's comment carries role, destination and port, using only characters
# iptables -S prints unquoted, so stale rules (an older destination) can be
# found and deleted exactly.
TAG="tc-meet-fw-$ROLE"
WANT="$TAG-${DST//./-}-$PORT"
RULE=(-p tcp -m conntrack --ctorigdst "$DST/32" --ctorigdstport "$PORT" --ctdir ORIGINAL
      -m comment --comment "$WANT" -j "$CHAIN")

# Our DOCKER-USER rules (any destination), or only the stale ones with $1.
our_rules() {
  { iptables -w -S DOCKER-USER 2>/dev/null || true; } | awk -v tag="$TAG-" -v keep="${1:-}" '
    { for (i = 1; i < NF; i++) if ($i == "--comment" && index($(i + 1), tag) == 1 && $(i + 1) != keep) { print; next } }'
}
delete_rules() {
  local line args
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -ra args <<<"${line/#-A /-D }"
    iptables -w "${args[@]}"
  done
}

case "$ACTION" in
  apply)
    command -v iptables-restore >/dev/null || { echo "meet-fw: iptables-restore not found" >&2; exit 1; }
    # Docker creates DOCKER-USER and never flushes it; creating it first means
    # the rules are in place before any container publishes the port.
    iptables -w -N DOCKER-USER 2>/dev/null || true
    {
      echo '*filter'
      echo ":$CHAIN - [0:0]"
      for s in "${SOURCES[@]}"; do echo "-A $CHAIN -s $s/32 -j RETURN"; done
      echo "-A $CHAIN -j DROP"
      echo 'COMMIT'
    } | iptables-restore -w --noflush
    iptables -w -C DOCKER-USER "${RULE[@]}" 2>/dev/null || iptables -w -I DOCKER-USER 1 "${RULE[@]}"
    our_rules "$WANT" | delete_rules
    echo "meet-fw ($ROLE): tcp $DST:$PORT open to ${#SOURCES[@]} source(s)${SOURCES[*]:+: ${SOURCES[*]}}; everything else dropped"
    ;;
  remove)
    our_rules | delete_rules
    if iptables -w -S "$CHAIN" >/dev/null 2>&1; then iptables -w -F "$CHAIN"; iptables -w -X "$CHAIN"; fi
    echo "meet-fw ($ROLE): removed (tcp $DST:$PORT is no longer filtered)"
    ;;
  status)
    echo "# DOCKER-USER rules ($ROLE)"; our_rules
    echo "# $CHAIN"; iptables -w -S "$CHAIN" 2>/dev/null || echo "(chain $CHAIN does not exist)"
    ;;
esac

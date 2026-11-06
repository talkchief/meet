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
#                 /opt/talkchief-meet-bridge/.env. Allowed sources: MAIN_PRIVATE_IP
#                 (the main host's monitor) and, with shards, every address
#                 in SHARD_PRIVATE_IPS (comma list) from the same file.
#   --role shard  (shard host, shard mode only): the web container's HTTPS
#                 8443 on SHARD_PRIVATE_IP from /opt/talkchief-meet/.env.
#                 Allowed sources: the shard hosts in
#                 /opt/talkchief-meet/shards.list ("<private-ip> <name>").
#
# Usage: meet-fw.sh [--role main|bridge|shard] apply|remove|status|enable|disable
#
# apply is idempotent and atomic: the allowlist chain is rebuilt in one
# iptables-restore transaction, so the port is never briefly open. Everything
# not allowlisted is dropped. Matching on the conntrack original destination is
# needed because Docker DNATs published ports before FORWARD; container to
# container traffic (the main host's own jvb and jicofo reach Prosody on the
# compose network) has a different original destination and is not touched.
# IPv4 only: the port is published on an IPv4 address.
#
# apply fails closed on bad input: an unreadable or partly invalid allowlist
# still yields a complete rule set (invalid entries skipped, everything else
# dropped). It exits non-zero only when iptables itself fails, and then Docker
# could not publish ports either.
#
# enable (as root, once the firewall is needed): enables the role's systemd
# unit, starts it or reloads it, and installs a docker.service drop-in
# (Requires= + After=), so Docker never starts, at boot or otherwise, without
# a successfully applied allowlist. The unit refuses manual stop and restart:
# a restart of a unit Docker requires would restart Docker and drop every
# meeting. To change the allowlist use `systemctl reload <unit>` (or enable
# again); it never touches Docker.
# disable: removes the drop-in and disables the unit (the rules stay until
# `remove` or a reboot).
set -euo pipefail

USAGE="usage: $0 [--role main|bridge|shard] apply|remove|status|enable|disable"
ROLE=main
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE=${2:-}; shift 2 ;;
    --role=*) ROLE=${1#--role=}; shift ;;
    apply|remove|status|enable|disable) break ;;
    *) echo "$USAGE" >&2; exit 64 ;;
  esac
done
ACTION=${1:-}
case "$ACTION" in apply|remove|status|enable|disable) ;; *) echo "$USAGE" >&2; exit 64 ;; esac
case "$ROLE" in
  main) UNIT=talkchief-meet-fw.service ;;
  bridge) UNIT=talkchief-meet-bridge-fw.service ;;
  shard) UNIT=talkchief-meet-shard-fw.service ;;
  *) echo "meet-fw: unknown role '$ROLE' (main, bridge or shard)" >&2; exit 64 ;;
esac
DROPIN_DIR=${MEET_FW_SYSTEMD_DIR:-/etc/systemd/system}/docker.service.d
DROPIN=$DROPIN_DIR/10-$UNIT.conf

# enable / disable only manage systemd and need none of the settings below.
case "$ACTION" in
  enable)
    install -d -m 0755 "$DROPIN_DIR"
    want=$(printf '# Installed by talkchief-meet-fw enable: Docker starts only after the\n# private-network allowlist is applied (scripts/meet-fw.sh).\n[Unit]\nRequires=%s\nAfter=%s\n' "$UNIT" "$UNIT")
    if [ "$(cat "$DROPIN" 2>/dev/null || true)" != "$want" ]; then
      printf '%s\n' "$want" >"$DROPIN.tmp" && chmod 644 "$DROPIN.tmp" && mv -f "$DROPIN.tmp" "$DROPIN"
    fi
    systemctl daemon-reload            # a running Docker is not restarted by this
    systemctl enable --quiet "$UNIT"
    if systemctl is-active --quiet "$UNIT"; then systemctl reload "$UNIT"; else systemctl start "$UNIT"; fi
    echo "meet-fw ($ROLE): $UNIT enabled and applied; docker.service requires it ($DROPIN)"
    exit 0
    ;;
  disable)
    rm -f "$DROPIN"
    systemctl daemon-reload
    systemctl disable --quiet "$UNIT" || true
    echo "meet-fw ($ROLE): $UNIT disabled and Docker no longer requires it; rules stay until '$0 --role $ROLE remove' or a reboot"
    exit 0
    ;;
esac

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
# Allowlist file reader: one private IPv4 first on each line ("#" comments).
read_allow() {
  local file=$1 line ip
  if [ -e "$file" ] && ! [ -r "$file" ]; then
    echo "meet-fw: cannot read $file; allowing nobody" >&2; return 0
  fi
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; read -r ip _ <<<"$line" || true
    [ -n "${ip:-}" ] || continue
    if is_private_ipv4 "$ip"; then SOURCES+=("$ip"); else echo "meet-fw: ignoring '$ip' in $file (not a private IPv4 address)" >&2; fi
  done <"$file"
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
    if [ -e "$ALLOW" ] && ! [ -r "$ALLOW" ]; then
      echo "meet-fw: cannot read $ALLOW; allowing nobody" >&2
    elif [ -f "$ALLOW" ]; then
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
    IFS=, read -ra shard_ips <<<"$(envval "$DEST/.env" SHARD_PRIVATE_IPS)"
    for ip in "${shard_ips[@]}"; do
      ip=${ip// /}; [ -n "$ip" ] || continue
      if is_private_ipv4 "$ip"; then SOURCES+=("$ip"); else echo "meet-fw: ignoring '$ip' in SHARD_PRIVATE_IPS (not a private IPv4 address)" >&2; fi
    done
    ;;
  shard)
    DEST=${MEET_DEST:-/opt/talkchief-meet}
    PORT=8443
    CHAIN=TC-MEET-SHARD
    DST=$(envval "$DEST/.env" SHARD_PRIVATE_IP)
    is_private_ipv4 "$DST" || { echo "meet-fw: SHARD_PRIVATE_IP missing or invalid in $DEST/.env" >&2; exit 1; }
    read_allow "${MEET_SHARDS_LIST:-$DEST/shards.list}"
    ;;
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

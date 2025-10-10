#!/usr/bin/env bash
# wg-per-peer-shaper (low-latency, stable, TCP/UDP)

set -Eeuo pipefail
# =============== Config ======================
ENV_FILE="/etc/wg-shaper/config.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${MAX_UP:=10mbit}"      # uplink (server -> client)
: "${MAX_DOWN:=10mbit}"    # downlink (client -> server)
: "${SLEEP_SEC:=15}"
: "${WG_DIR:=/etc/wireguard}"
: "${STATE_DIR:=/var/run/wg-shaper}"
mkdir -p "$STATE_DIR"

# =============== Helpers =====================
log() { echo "[$(date +'%F %T')] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found"; exit 1; }; }

minor_from_pubkey() {
  local pub="$1"; local ck; ck=$(cksum <<<"$pub" | awk '{print $1}')
  local min=$(( ck % 65535 + 1 ))
  printf "%04x" "$min"
}

class_exists() { tc class show dev "$1" parent 1: 2>/dev/null | grep -q "class htb 1:$2 "; }

ensure_ifb() {
  local iface="$1"; local ifb="ifb-$iface"
  ip link show "$ifb" &>/dev/null || { ip link add "$ifb" type ifb; ip link set "$ifb" up; }
  echo "$ifb"
}

# --- Micro helpers
qdisc_root_htb_add_or_change() {
  local dev="$1"
  tc qdisc add dev "$dev" root handle 1: htb default 30 2>/dev/null \
  || tc qdisc change dev "$dev" root handle 1: htb default 30 2>/dev/null \
  || true
}
qdisc_fqcodel_add_or_change() {
  local dev="$1" parent="$2" handle="$3"
  tc qdisc add dev "$dev" parent "$parent" handle "$handle" fq_codel 2>/dev/null \
  || tc qdisc change dev "$dev" parent "$parent" handle "$handle" fq_codel 2>/dev/null \
  || true
}
class_htb_add_or_change() {
  local dev="$1" minor="$2" rate="$3" ceil="$4"
  tc class add dev "$dev" parent 1: classid 1:$minor htb rate "$rate" ceil "$ceil" 2>/dev/null \
  || tc class change dev "$dev" parent 1: classid 1:$minor htb rate "$rate" ceil "$ceil" 2>/dev/null \
  || true
}

setup_roots() {
  local iface="$1"; local ifb="$2"
  qdisc_root_htb_add_or_change "$iface"
  class_htb_add_or_change "$iface" "0030" "1gbit" "1gbit"
  qdisc_fqcodel_add_or_change "$iface" "1:30" "30:"
  tc qdisc add dev "$iface" handle ffff: ingress 2>/dev/null || true
  tc filter del dev "$iface" parent ffff: prio 1 2>/dev/null || true
  tc filter add dev "$iface" parent ffff: protocol all prio 1 u32 match u32 0 0 \
    action mirred egress redirect dev "$ifb"
  qdisc_root_htb_add_or_change "$ifb"
  class_htb_add_or_change "$ifb" "0030" "1gbit" "1gbit"
  qdisc_fqcodel_add_or_change "$ifb" "1:30" "30:"
}

nuke_prio10_filters() {
  local dev="$1"
  while tc filter show dev "$dev" parent 1: 2>/dev/null | grep -q "prio 10"; do
    tc filter del dev "$dev" parent 1: prio 10 2>/dev/null || true
  done
}

ensure_peer_classes() {
  local iface="$1"; local ifb="$2"; local minor="$3"; local up="$4"; local down="$5"
  class_htb_add_or_change "$iface" "$minor" "$up" "$up"
  qdisc_fqcodel_add_or_change "$iface" "1:$minor" "${minor}:"
  class_htb_add_or_change "$ifb"   "$minor" "$down" "$down"
  qdisc_fqcodel_add_or_change "$ifb" "1:$minor" "${minor}:"
}

add_filters_for_cidr() {
  local iface="$1"; local ifb="$2"; local minor="$3"; local cidr="$4"
  if [[ "$cidr" == *:* ]]; then
    tc filter replace dev "$iface" protocol ipv6 parent 1: prio 10 u32 match ip6 dst "$cidr" flowid 1:$minor
    tc filter replace dev "$ifb"   protocol ipv6 parent 1: prio 10 u32 match ip6 src "$cidr" flowid 1:$minor
  else
    tc filter replace dev "$iface" protocol ip   parent 1: prio 10 u32 match ip  dst "$cidr" flowid 1:$minor
    tc filter replace dev "$ifb"   protocol ip   parent 1: prio 10 u32 match ip  src "$cidr" flowid 1:$minor
  fi
}

existing_minors() {
  local dev="$1"
  tc class show dev "$dev" parent 1: 2>/dev/null \
    | awk '/class htb 1:/{print $3}' \
    | cut -d: -f2 \
    | sed 's/^/0000/;s/.*\(....\)$/\1/' \
    | grep -vi '^0030$' || true
}

remove_stale_minors() {
  local dev="$1"; shift
  local desired=("$@")
  if [[ ${#desired[@]} -eq 0 ]]; then
    while read -r m; do
      [[ -z "$m" ]] && continue
      tc class del dev "$dev" classid 1:$m 2>/dev/null || true
    done < <(existing_minors "$dev")
    return
  fi
  local desired_pat="^($(printf '%s|' "${desired[@]}" | sed 's/|$//'))$"
  local cur; mapfile -t cur < <(existing_minors "$dev")
  for m in "${cur[@]:-}"; do
    [[ -z "$m" ]] && continue
    if ! [[ "$m" =~ $desired_pat ]]; then
      tc class del dev "$dev" classid 1:$m 2>/dev/null || true
    fi
  done
}

hash_state() {
  local iface="$1"
  { wg show "$iface" dump 2>/dev/null || true; echo "UP=$MAX_UP DOWN=$MAX_DOWN"; } \
    | sha256sum | awk '{print $1}'
}

# =============== Main loop ===================
need tc; need wg; need ip; modprobe ifb 2>/dev/null || true
log "Starting wg-per-peer-shaper"

while true; do
  IFS=' ' read -r -a ifaces <<< "$(wg show interfaces 2>/dev/null || true)"
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    sleep "$SLEEP_SEC"; continue
  fi

  for iface in "${ifaces[@]}"; do
    [[ -z "$iface" ]] && continue
    ip link show "$iface" &>/dev/null || continue

    new_hash=$(hash_state "$iface")
    hash_file="$STATE_DIR/$iface.hash"
    old_hash=""; [[ -f "$hash_file" ]] && old_hash=$(<"$hash_file")
    if [[ "$new_hash" == "$old_hash" ]]; then
      continue
    fi

    log ">> Syncing $iface (change detected)"

    ifb=$(ensure_ifb "$iface")
    setup_roots "$iface" "$ifb"

    nuke_prio10_filters "$iface"
    nuke_prio10_filters "$ifb"

    desired_minors=()

    while IFS=$'\t' read -r pub psk ep aips hs rx tx ka; do
      [[ -z "$pub" || "$pub" == "public_key" ]] && continue
      [[ -z "$aips" || "$aips" == "(none)" ]] && continue

      minor=$(minor_from_pubkey "$pub")
      [[ "$minor" == "0030" ]] && minor="0031"
      desired_minors+=("$minor")

      ensure_peer_classes "$iface" "$ifb" "$minor" "$MAX_UP" "$MAX_DOWN"

      IFS=',' read -r -a arr <<< "$aips"
      declare -A seen=()
      for cidr in "${arr[@]}"; do
        cidr_trimmed="${cidr// /}"
        [[ -z "$cidr_trimmed" ]] && continue
        [[ ${seen["$cidr_trimmed"]+x} ]] && continue
        seen["$cidr_trimmed"]=1
        add_filters_for_cidr "$iface" "$ifb" "$minor" "$cidr_trimmed"
      done
    done < <(wg show "$iface" dump | tail -n +2)

    remove_stale_minors "$iface" "${desired_minors[@]}"
    remove_stale_minors "$ifb"   "${desired_minors[@]}"

    echo "$new_hash" >"$hash_file"
    peer_count=${#desired_minors[@]}
    log ">> $iface synced: peers=$peer_count up=$MAX_UP down=$MAX_DOWN"
  done

  sleep "$SLEEP_SEC"
done

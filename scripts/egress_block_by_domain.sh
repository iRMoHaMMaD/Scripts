#!/usr/bin/env bash
set -Eeuo pipefail

# ================== CONFIG ==================
DOMAINS_FILE="/root/tools/domains.txt"       # هر خط یک دامنه/ساب‌دامنه/ IP / رنج / CIDR
BLOCKSET_V4="blocked_dst_ips"                # ipset مقصدهای بلاک (IPv4) — حالا hash:net
WHITESET_V4="whitelist_ips"                  # ipset وایت‌لیست (IPv4)
ALLOW_IPV6="1"                               # اگر 1 شود IPv6 هم اعمال می‌شود (ست و chain جدا)
BLOCKSET_V6="blocked_dst_ips6"               # برای IPv6 — hash:net
WHITESET_V6="whitelist_ips6"
MAXELEM="20000000"                           # ظرفیت ipset
RULE_COMMENT="egress-block-by-domain"        # تگ برای حذف تمیز
# Resolve timeouts / batching
MASSDNS_CHUNK_LINES="50000"
MASSDNS_DEADLINE_SEC="180"
RETRY_ON_TIMEOUT="1"
PER_DOMAIN_TIMEOUT_SEC="1.5"
PARALLEL_JOBS="256"
# ============================================

# ---- پارامتر اختیاری: --ext-if <IFACE> برای override اینترفیس خروجی
EXT_IF=""
if [[ "${1:-}" == "--ext-if" && -n "${2:-}" ]]; then
  EXT_IF="$2"; shift 2
fi

[[ -f "$DOMAINS_FILE" ]] || { echo "[ERROR] $DOMAINS_FILE not found"; exit 1; }
command -v ipset >/dev/null    || { echo "[ERROR] ipset not found"; exit 1; }
command -v iptables >/dev/null || { echo "[ERROR] iptables not found"; exit 1; }

# ---- کشف اینترفیس خروجی (در صورت عدم override)
get_main_if() {
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] && { echo "$dev"; return; }
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] && { echo "$dev"; return; }
  echo ""
}
if [[ -z "$EXT_IF" ]]; then
  EXT_IF="$(get_main_if)"
  [[ -n "$EXT_IF" ]] || { echo "[ERROR] نتوانستم اینترفیس خروجی را پیدا کنم. از --ext-if استفاده کن."; exit 1; }
fi
echo "[INFO] External interface: $EXT_IF"

# جلوگیری از persist ناخواسته
is_active(){ systemctl is-active --quiet "$1"; }
if command -v systemctl >/dev/null; then
  if is_active iptables-persistent || is_active netfilter-persistent; then
    echo "[ABORT] netfilter/iptables-persistent فعال است؛ برای اپمرال بودن غیرفعالشان کنید:"
    echo "sudo systemctl disable --now netfilter-persistent iptables-persistent"
    exit 1
  fi
fi

# ---- کارهای موقت
WORKDIR="$(mktemp -d /tmp/block-egress.XXXXXX)"; trap 'rm -rf "$WORKDIR"' EXIT
RAW_V4="$WORKDIR/raw_v4.txt"; IPS_V4="$WORKDIR/ips_v4.txt"
RAW_V6="$WORKDIR/raw_v6.txt"; IPS_V6="$WORKDIR/ips_v6.txt"
UNRESOLVED="$WORKDIR/unresolved.txt"
RES_A="$WORKDIR/res_a.txt"; RES_B="$WORKDIR/res_b.txt"
SPLIT_DIR="$WORKDIR/split"; mkdir -p "$SPLIT_DIR"

# فایل‌های ورودی مستقیم (IP/CIDR/Range) که بلاک می‌شوند:
DIRECT_V4_NETS="$WORKDIR/direct_v4_nets.txt"   # شامل CIDR و تبدیل رنج‌ها + IP/32
DIRECT_V6_NETS="$WORKDIR/direct_v6_nets.txt"   # شامل CIDR و IP/128
DOMAINS_ONLY="$WORKDIR/domains_only.txt"       # فقط دامنه‌ها برای رزولوشن
> "$DIRECT_V4_NETS"; > "$DIRECT_V6_NETS"; > "$DOMAINS_ONLY"

# ---------- پاکسازی اجرای قبلی (OUTPUT/ FORWARD / chainهای ما) ----------
flush_chain() { local bin="$1" ch="$2"; $bin -F "$ch" 2>/dev/null || true; $bin -X "$ch" 2>/dev/null || true; }
# حذف jump قبلی به زنجیره‌ی ما از OUTPUT و FORWARD (با و بدون -o)
del_jump_variants() {
  local bin="$1" ch="$2" ifc="$3"
  # حالت بدون -o
  while $bin -C OUTPUT  -j "$ch" &>/dev/null; do $bin -D OUTPUT  -j "$ch" || true; done
  while $bin -C FORWARD -j "$ch" &>/dev/null; do $bin -D FORWARD -j "$ch" || true; done
  # حالت با -o ifc
  while $bin -C OUTPUT  -o "$ifc" -j "$ch" &>/dev/null;  do $bin -D OUTPUT  -o "$ifc" -j "$ch" || true; done
  while $bin -C FORWARD -o "$ifc" -j "$ch" &>/dev/null; do $bin -D FORWARD -o "$ifc" -j "$ch" || true; done
}
# IPv4
del_jump_variants iptables OUT_BLOCK_DOMAINS "$EXT_IF"
flush_chain iptables OUT_BLOCK_DOMAINS
# IPv6 (در صورت نیاز)
if [[ "$ALLOW_IPV6" == "1" ]] && command -v ip6tables >/dev/null; then
  del_jump_variants ip6tables OUT_BLOCK_DOMAINS6 "$EXT_IF"
  flush_chain ip6tables OUT_BLOCK_DOMAINS6
fi
# ipsetهای قبلی ما را نابود کن
for set in "$BLOCKSET_V4" "$WHITESET_V4"; do ipset destroy "$set" 2>/dev/null || true; done
if [[ "$ALLOW_IPV6" == "1" ]]; then
  for set in "$BLOCKSET_V6" "$WHITESET_V6"; do ipset destroy "$set" 2>/dev/null || true; done
fi

# ---------- کمک‌تابع‌ها برای تشخیص و تبدیل ----------
is_ipv4(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
  awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<<"$1" >/dev/null
}

is_cidr_v4(){
  local mask
  if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
    mask="${1##*/}"
    (( mask>=0 && mask<=32 ))
  else
    return 1
  fi
}

is_range_v4(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6_addr(){
  # ساده: وجود ':' و نبود '/' (برای آدرس تکی)
  [[ "$1" == *:* && "$1" != */* ]]
}

is_cidr_v6(){
  # IPv6/CIDR
  [[ "$1" == *:*/* ]]
}

is_comment_or_blank(){
  [[ -z "${1// }" || "${1:0:1}" == "#" ]]
}

# تبدیل IPv4 به عدد و برعکس
ip2int(){ local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
int2ip(){ local x=$1; echo "$(( (x>>24)&255 )).$(( (x>>16)&255 )).$(( (x>>8)&255 )).$(( x&255 ))"; }

# بزرگ‌ترین بلاک هم‌تراز از start که از end جلو نزنه → خروجی CIDRها
range_to_cidrs_v4(){
  local start="$1" end="$2"
  local s e max_mask rem_mask size block
  s=$(ip2int "$start"); e=$(ip2int "$end")
  (( s<=e )) || { local t=$s; s=$e; e=$t; }
  while (( s<=e )); do
    # بیشترین ترازشدن به پایین (trailing zeros)
    local tz=0
    while (( ((s>>tz)&1)==0 && tz<32 )); do ((tz++)); done
    local max1=$((32 - tz))               # ماسک بر اساس تراز
    # محدودیت اندازه به‌خاطر باقیمانده فاصله تا end
    local diff=$(( e - s + 1 ))
    local hb=0; local tmp=1
    while (( tmp<<1 <= diff )); do ((hb++)); ((tmp<<=1)); done
    local max2=$((32 - hb))               # ماسک بر اساس ظرفیت باقی‌مانده
    local mask=$(( max1>max2 ? max1 : max2 ))
    block=$(( 1 << (32 - mask) ))
    echo "$(int2ip "$s")/$mask"
    s=$(( s + block ))
  done
}

# ---------- پیش‌پردازش ورودی: دامنه‌ها vs IP/CIDR/Range ----------
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%[[:space:]]*}"; line="${line//$'\r'/}"   # تا اولین فاصله + حذف CR
  is_comment_or_blank "$line" && continue
  if is_cidr_v4 "$line"; then
    echo "$line" >> "$DIRECT_V4_NETS"
  elif is_range_v4 "$line"; then
    start="${line%-*}"; end="${line#*-}"
    if is_ipv4 "$start" && is_ipv4 "$end"; then
      range_to_cidrs_v4 "$start" "$end" >> "$DIRECT_V4_NETS"
    else
      echo "[WARN] محدوده IPv4 نامعتبر: $line" >&2
    fi
  elif is_ipv4 "$line"; then
    echo "$line/32" >> "$DIRECT_V4_NETS"
  elif is_cidr_v6 "$line"; then
    echo "$line" >> "$DIRECT_V6_NETS"
  elif is_ipv6_addr "$line"; then
    echo "$line/128" >> "$DIRECT_V6_NETS"
  else
    # فرض: دامنه/ساب‌دامنه
    echo "$line" >> "$DOMAINS_ONLY"
  fi
done < "$DOMAINS_FILE"

TOTAL_DOMAINS=$(wc -l < "$DOMAINS_ONLY" 2>/dev/null || echo 0)
TOTAL_DIRECT_V4=$(wc -l < "$DIRECT_V4_NETS" 2>/dev/null || echo 0)
TOTAL_DIRECT_V6=$(wc -l < "$DIRECT_V6_NETS" 2>/dev/null || echo 0)
echo "[INFO] from file: domains=$TOTAL_DOMAINS | direct_v4=$TOTAL_DIRECT_V4 | direct_v6=$TOTAL_DIRECT_V6"

# ---------- رزولورها ----------
mk_resolvers(){
  local out="$1"
  awk '/^nameserver[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2":53"}' /etc/resolv.conf > "$out" || true
  [[ -s "$out" ]] || printf "1.1.1.1:53\n8.8.8.8:53\n9.9.9.9:53\n" > "$out"
}
if command -v massdns >/dev/null; then
  mk_resolvers "$RES_A"
  printf "8.8.4.4:53\n1.0.0.1:53\n208.67.222.222:53\n" > "$RES_B"
fi

# ---------- رزولوشن دامنه‌ها (فقط اگر دامنه‌ای داریم) ----------
ALL_V4_NETS="$WORKDIR/all_v4_nets.txt"
ALL_V6_NETS="$WORKDIR/all_v6_nets.txt"
> "$ALL_V4_NETS"; > "$ALL_V6_NETS"

if (( TOTAL_DOMAINS > 0 )); then
  echo "[+] Resolving ~${TOTAL_DOMAINS} domains (egress-only mode) ..."
  if command -v massdns >/dev/null; then
    split -l "$MASSDNS_CHUNK_LINES" -d --additional-suffix=.txt "$DOMAINS_ONLY" "$SPLIT_DIR/part_" || true
    >"$RAW_V4"; >"$RAW_V6"; >"$UNRESOLVED"
    run_massdns_chunk(){
      local infile="$1" resolvers="$2" qtype="$3" out="$4"
      timeout "${MASSDNS_DEADLINE_SEC}s" massdns -r "$resolvers" -t "$qtype" -o S -q "$infile" 2>/dev/null \
        | awk -v T="$qtype" '$2==T{print $3}' >> "$out"
      return $?
    }
    shopt -s nullglob
    for f in "$SPLIT_DIR"/part_*.txt; do
      run_massdns_chunk "$f" "$RES_A" "A" "$RAW_V4" || cat "$f" >> "$UNRESOLVED"
      if [[ "$ALLOW_IPV6" == "1" ]]; then
        run_massdns_chunk "$f" "$RES_A" "AAAA" "$RAW_V6" || cat "$f" >> "$UNRESOLVED"
      fi
    done
    if [[ "$RETRY_ON_TIMEOUT" == "1" && -s "$UNRESOLVED" ]]; then
      echo "[RETRY] unresolved quick retry ..."
      for f in "$SPLIT_DIR"/part_*.txt; do
        comm -12 <(sort -u "$f") <(sort -u "$UNRESOLVED") > "$WORKDIR/retry.txt" || true
        [[ -s "$WORKDIR/retry.txt" ]] || continue
        run_massdns_chunk "$WORKDIR/retry.txt" "$RES_B" "A" "$RAW_V4" || true
        [[ "$ALLOW_IPV6" == "1" ]] && run_massdns_chunk "$WORKDIR/retry.txt" "$RES_B" "AAAA" "$RAW_V6" || true
      done
    fi
  else
    if command -v parallel >/dev/null; then
      parallel -j "$PARALLEL_JOBS" --lb --halt now,fail=1 \
        "timeout ${PER_DOMAIN_TIMEOUT_SEC}s bash -c 'getent ahostsv4 {} | awk \"{print \\\$1}\"' || true" \
        :::: "$DOMAINS_ONLY" >> "$RAW_V4"
      if [[ "$ALLOW_IPV6" == "1" ]] && command -v ip6tables >/dev/null; then
        parallel -j "$PARALLEL_JOBS" --lb --halt now,fail=1 \
          "timeout ${PER_DOMAIN_TIMEOUT_SEC}s bash -c 'getent ahostsv6 {} | awk \"{print \\\$1}\"' || true" \
          :::: "$DOMAINS_ONLY" >> "$RAW_V6"
      fi
    else
      while IFS= read -r d || [[ -n "$d" ]]; do
        [[ -z "$d" ]] && continue
        timeout "${PER_DOMAIN_TIMEOUT_SEC}s" bash -c "getent ahostsv4 '$d' | awk '{print \$1}'" >> "$RAW_V4" || true
        if [[ "$ALLOW_IPV6" == "1" ]] && command -v ip6tables >/dev/null; then
          timeout "${PER_DOMAIN_TIMEOUT_SEC}s" bash -c "getent ahostsv6 '$d' | awk '{print \$1}'" >> "$RAW_V6" || true
        fi
      done < "$DOMAINS_ONLY"
    fi
  fi

  # IPv4/IPv6 IPها → نت‌های /32 و /128
  awk -F. 'NF==4 && ($1<256)&&($2<256)&&($3<256)&&($4<256)' "$RAW_V4" 2>/dev/null \
    | awk '{print $0"/32"}' | sort -u >> "$ALL_V4_NETS"
  if [[ -s "$RAW_V6" ]]; then
    awk '/:/' "$RAW_V6" | awk '{print $0"/128"}' | sort -u >> "$ALL_V6_NETS"
  fi
fi

# تجمیع ورودی مستقیم + رزولوشن‌ها
sort -u "$DIRECT_V4_NETS" >> "$ALL_V4_NETS" 2>/dev/null || true
sort -u "$DIRECT_V6_NETS" >> "$ALL_V6_NETS" 2>/dev/null || true
V4_COUNT=$(wc -l < "$ALL_V4_NETS" 2>/dev/null || echo 0)
V6_COUNT=$([[ -s "$ALL_V6_NETS" ]] && wc -l < "$ALL_V6_NETS" || echo 0)
echo "[INFO] unique IPv4 nets: $V4_COUNT | unique IPv6 nets: $V6_COUNT"

# ---------- ساخت ipsetها (اپمرال) ----------
# بلاک‌ست‌ها حالا hash:net هستند تا هم IP/32 هم CIDR را بپذیرند
ipset create "$BLOCKSET_V4" hash:net family inet  maxelem "$MAXELEM" -exist
ipset create "$WHITESET_V4" hash:ip  family inet  maxelem 4096 -exist
if [[ "$ALLOW_IPV6" == "1" ]] && command -v ip6tables >/dev/null; then
  ipset create "$BLOCKSET_V6" hash:net family inet6 maxelem "$MAXELEM" -exist
  ipset create "$WHITESET_V6" hash:ip  family inet6 maxelem 4096 -exist
fi

# وایت‌لیست: گیت‌وی پیش‌فرض و DNSها (سیستمی + چند عمومی)
DEF_GW="$(ip route | awk '/^default/ {print $3; exit}')"
[[ -n "$DEF_GW" ]] && ipset add "$WHITESET_V4" "$DEF_GW" 2>/dev/null || true
awk '/^nameserver[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2}' /etc/resolv.conf \
  | while read -r ns; do ipset add "$WHITESET_V4" "$ns" 2>/dev/null || true; done
for ip in 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9; do
  ipset add "$WHITESET_V4" "$ip" 2>/dev/null || true
done

# بارگذاری انبوه بلاک‌ست (اتمیک)
NEW_SET_V4="${BLOCKSET_V4}_new_$$"
{
  echo "create $NEW_SET_V4 hash:net family inet maxelem $MAXELEM -exist"
  [[ -s "$ALL_V4_NETS" ]] && awk '{printf "add %s %s\n", "'"$NEW_SET_V4"'", $0}' "$ALL_V4_NETS"
  echo "swap $BLOCKSET_V4 $NEW_SET_V4"
  echo "destroy $NEW_SET_V4"
} | ipset restore -!

if [[ "$ALLOW_IPV6" == "1" && -s "$ALL_V6_NETS" ]] && command -v ip6tables >/dev/null; then
  NEW_SET_V6="${BLOCKSET_V6}_new_$$"
  {
    echo "create $NEW_SET_V6 hash:net family inet6 maxelem $MAXELEM -exist"
    awk '{printf "add %s %s\n", "'"$NEW_SET_V6"'", $0}' "$ALL_V6_NETS"
    echo "swap $BLOCKSET_V6 $NEW_SET_V6"
    echo "destroy $NEW_SET_V6"
  } | ipset restore -!
fi

# ---------- زنجیره‌ی اختصاصی فقط برای DROP مقصدها ----------
# تضمین ESTABLISHED,RELATED در ابتدای OUTPUT
iptables -C OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -I OUTPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# زنجیره ما (IPv4)
iptables -N OUT_BLOCK_DOMAINS 2>/dev/null || true

# پرش از OUTPUT و FORWARD به زنجیره‌ی ما (فقط زمانی که خروجی به EXT_IF است)
iptables -C OUTPUT  -o "$EXT_IF" -j OUT_BLOCK_DOMAINS 2>/dev/null || iptables -I OUTPUT  2 -o "$EXT_IF" -j OUT_BLOCK_DOMAINS
iptables -C FORWARD -o "$EXT_IF" -j OUT_BLOCK_DOMAINS 2>/dev/null || iptables -I FORWARD 1 -o "$EXT_IF" -j OUT_BLOCK_DOMAINS

# قوانین داخل زنجیره:
iptables -A OUT_BLOCK_DOMAINS -m set --match-set "$WHITESET_V4" dst -j ACCEPT -m comment --comment "$RULE_COMMENT"
iptables -A OUT_BLOCK_DOMAINS -m set --match-set "$BLOCKSET_V4" dst -m conntrack --ctstate NEW -j DROP -m comment --comment "$RULE_COMMENT"
iptables -A OUT_BLOCK_DOMAINS -j RETURN

# IPv6 (اختیاری)
if [[ "$ALLOW_IPV6" == "1" ]] && command -v ip6tables >/dev/null; then
  # تضمین ESTABLISHED,RELATED در ابتدای OUTPUT6
  ip6tables -C OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  ip6tables -I OUTPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  ip6tables -N OUT_BLOCK_DOMAINS6 2>/dev/null || true

  ip6tables -C OUTPUT  -o "$EXT_IF" -j OUT_BLOCK_DOMAINS6 2>/dev/null || ip6tables -I OUTPUT  2 -o "$EXT_IF" -j OUT_BLOCK_DOMAINS6
  ip6tables -C FORWARD -o "$EXT_IF" -j OUT_BLOCK_DOMAINS6 2>/dev/null || ip6tables -I FORWARD 1 -o "$EXT_IF" -j OUT_BLOCK_DOMAINS6

  ip6tables -A OUT_BLOCK_DOMAINS6 -m set --match-set "$WHITESET_V6" dst -j ACCEPT -m comment --comment "$RULE_COMMENT"
  ip6tables -A OUT_BLOCK_DOMAINS6 -m set --match-set "$BLOCKSET_V6" dst -m conntrack --ctstate NEW -j DROP -m comment --comment "$RULE_COMMENT"
  ip6tables -A OUT_BLOCK_DOMAINS6 -j RETURN
fi

echo "[DONE] Egress blocking active on OUTPUT and FORWARD (via $EXT_IF)."
echo "[NOTE] همه‌چیز اپمرال است و با ریبوت از بین می‌رود."

# ---------- غیرفعال‌سازی IPv6 روی سرور (runtime, غیرپایدار) ----------
disable_ipv6_runtime(){
  if sysctl -a 2>/dev/null | grep -q 'net.ipv6.conf.all.disable_ipv6'; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null || true
    for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
      echo 1 > "$f" 2>/dev/null || true
    done
    echo "[NOTE] IPv6 به‌صورت runtime غیرفعال شد (persist نیست)."
  else
    echo "[WARN] به نظر می‌رسد Kernel شما گزینه disable_ipv6 را ندارد یا sysctl در دسترس نیست."
  fi
}
disable_ipv6_runtime

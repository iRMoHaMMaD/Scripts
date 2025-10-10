#!/usr/bin/env bash
set -euo pipefail

# =======================
# ثابت‌ها و مسیرها
# =======================
REPO_URL_DEFAULT="https://github.com/<YOUR_ACCOUNT>/<YOUR_REPO>.git"  # می‌توانی خالی بگذاری تا از کاربر بپرسد
REPO_DIR="/opt/cf-orchestrator-repo"      # مسیر کلون موقت
DEST_SCRIPTS="/root/scripts"              # محل نهایی اسکریپت‌ها
DEST_TOOLS="/root/tools"                  # محل نهایی domains.txt و ip-list.txt
CONFIG_DIR="/etc/cf-orchestrator"         # محل نهایی config.env
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOG_DIR="/var/log/cf-orchestrator"

# =======================
# توابع کمکی
# =======================
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[-] لطفاً اسکریپت را با sudo یا کاربر root اجرا کنید."
    exit 1
  fi
}

ensure_pkgs() {
  if ! command -v git >/dev/null 2>&1; then
    echo "[*] نصب git..."
    if command -v apt >/dev/null 2>&1; then
      apt update && apt install -y git
    elif command -v yum >/dev/null 2>&1; then
      yum install -y git
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y git
    else
      echo "[-] مدیر بسته ناشناخته؛ git را دستی نصب کنید."
      exit 1
    fi
  fi
}

ask_repo_url() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    REPO_URL="$1"
  elif [[ -n "${REPO_URL_DEFAULT}" ]]; then
    echo -n "URL ریپوزیتوری [پیش‌فرض: ${REPO_URL_DEFAULT}] : "
    read -r REPO_URL
    REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
  else
    echo -n "URL ریپوزیتوری را وارد کنید: "
    read -r REPO_URL
  fi
  if [[ -z "${REPO_URL:-}" ]]; then
    echo "[-] URL ریپو مشخص نیست."
    exit 1
  fi
}

clone_or_update_repo() {
  if [[ -d "${REPO_DIR}/.git" ]]; then
    echo "[*] Pull آخرین تغییرات..."
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" reset --hard origin/HEAD || git -C "${REPO_DIR}" pull --rebase
  else
    rm -rf "${REPO_DIR}"
    echo "[*] Clone ریپو در ${REPO_DIR} ..."
    git clone "${REPO_URL}" "${REPO_DIR}"
  fi
}

prepare_dirs() {
  mkdir -p "${DEST_SCRIPTS}" "${DEST_TOOLS}" "${CONFIG_DIR}" "${LOG_DIR}"
  chmod 750 "${DEST_SCRIPTS}" || true
  chmod 750 "${CONFIG_DIR}" || true
}

copy_scripts() {
  if [[ ! -d "${REPO_DIR}/scripts" ]]; then
    echo "[-] فولدر scripts/ داخل ریپو یافت نشد."
    exit 1
  fi
  cp -f "${REPO_DIR}/scripts/"*.sh "${DEST_SCRIPTS}/"
  chmod +x "${DEST_SCRIPTS}/"*.sh
  chown root:root "${DEST_SCRIPTS}/"*.sh
  echo "[+] اسکریپت‌ها به ${DEST_SCRIPTS} منتقل شدند."
}

interactive_build_config() {
  local source_cfg=""
  if [[ -f "${REPO_DIR}/config.env" ]]; then
    source_cfg="${REPO_DIR}/config.env"
  elif [[ -f "${REPO_DIR}/config.env.sample" ]]; then
    source_cfg="${REPO_DIR}/config.env.sample"
  else
    echo "[-] هیچ‌کدام از config.env یا config.env.sample در ریپو پیدا نشد."
    exit 1
  fi

  echo "[*] ساخت تعاملی ${CONFIG_FILE} (پیش‌فرض‌ها = مقادیر فعلی موجود در فایل ریپو)"
  local tmp_cfg; tmp_cfg="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
      echo "$line" >> "$tmp_cfg"
      continue
    fi
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      var="${line%%=*}"
      val="${line#*=}"
      val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      echo -n "$var (پیش‌فرض: $val) : "
      read -r input || true
      if [[ -z "$input" ]]; then
        echo "$var=$val" >> "$tmp_cfg"
      else
        if [[ "$val" =~ ^\".*\"$ ]]; then
          esc=$(printf '%s' "$input" | sed 's/"/\\"/g')
          echo "$var=\"$esc\"" >> "$tmp_cfg"
        else
          echo "$var=$input" >> "$tmp_cfg"
        fi
      fi
    else
      echo "$line" >> "$tmp_cfg"
    fi
  done < "$source_cfg"

  mv -f "$tmp_cfg" "${CONFIG_FILE}"
  chmod 640 "${CONFIG_FILE}"
  chown root:root "${CONFIG_FILE}"
  echo "[+] فایل پیکربندی نهایی: ${CONFIG_FILE}"
}

install_data_files() {
  # تلاش برای یافتن و کپی فایل‌های داده
  if [[ -f "${REPO_DIR}/domains.txt" ]]; then
    cp -f "${REPO_DIR}/domains.txt" "${DEST_TOOLS}/domains.txt"
  else
    : > "${DEST_TOOLS}/domains.txt"
  fi
  if [[ -f "${REPO_DIR}/ip-list.txt" ]]; then
    cp -f "${REPO_DIR}/ip-list.txt" "${DEST_TOOLS}/ip-list.txt"
  else
    : > "${DEST_TOOLS}/ip-list.txt"
  fi
  chown -R root:root "${DEST_TOOLS}"
  chmod 640 "${DEST_TOOLS}/domains.txt" "${DEST_TOOLS}/ip-list.txt"
  echo "[+] فایل‌های داده در ${DEST_TOOLS} آماده‌اند."
}

normalize_unit_name() {
  local base="$1"
  base="${base##*/}"
  base="${base%.sh}"
  base="${base//_/-}"
  echo "cf-${base}"
}

write_service_unit() {
  local script="$1"    # e.g., apply_wg_iptables.sh
  local unit_name="$2" # e.g., cf-apply-wg-iptables
  local boot="${3}"    # "yes" or "no"

  cat > "/etc/systemd/system/${unit_name}.service" <<EOF
[Unit]
Description=${unit_name} - run ${script}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=${CONFIG_FILE}
WorkingDirectory=${DEST_SCRIPTS}
ExecStart=/bin/bash ${DEST_SCRIPTS}/${script}
StandardOutput=append:${LOG_DIR}/${unit_name}.log
StandardError=append:${LOG_DIR}/${unit_name}.err

[Install]
$( [[ "$boot" == "yes" ]] && echo "WantedBy=multi-user.target" || echo "; enabled by its timer" )
EOF
}

write_timer_unit() {
  local unit_name="$1"
  local on_calendar="$2"
  cat > "/etc/systemd/system/${unit_name}.timer" <<EOF
[Unit]
Description=timer for ${unit_name}

[Timer]
OnCalendar=${on_calendar}
Persistent=true
Unit=${unit_name}.service

[Install]
WantedBy=timers.target
EOF
}

setup_units() {
  echo "[*] ایجاد سرویس‌ها و تایمرها..."
  systemctl daemon-reload || true

  # سرویس‌های بوت (هر ریبوت)
  for s in apply_wg_iptables.sh wg-tc-limiter.sh wgd_start.sh; do
    u="$(normalize_unit_name "$s")"
    write_service_unit "$s" "$u" "yes"
    systemctl enable --now "${u}.service" || true
  done

  # egress_block_by_domain.sh — هفتگی
  s="egress_block_by_domain.sh"
  u="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$u" "no"
  write_timer_unit "$u" "weekly"
  systemctl enable --now "${u}.timer"

  # cf.sh — ساعتی
  s="cf.sh"
  u="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$u" "no"
  write_timer_unit "$u" "hourly"
  systemctl enable --now "${u}.timer"

  # backup_to_telegram.sh — هر ۳۰ دقیقه
  s="backup_to_telegram.sh"
  u="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$u" "no"
  write_timer_unit "$u" "*:0/30"
  systemctl enable --now "${u}.timer"

  systemctl daemon-reload
  echo "[+] سرویس‌ها و تایمرها فعال شدند."
}

run_boot_services_now() {
  for u in cf-apply-wg-iptables cf-wg-tc-limiter cf-wgd-start; do
    systemctl start "${u}.service" || true
  done
}

# =======================
# Main
# =======================
need_root
ensure_pkgs
ask_repo_url "$@"
clone_or_update_repo
prepare_dirs
copy_scripts
interactive_build_config
install_data_files
setup_units
run_boot_services_now

echo
echo "[✓] نصب کامل شد."
echo "  اسکریپت‌ها:     ${DEST_SCRIPTS}"
echo "  پیکربندی:        ${CONFIG_FILE}"
echo "  فایل‌های داده:   ${DEST_TOOLS}/domains.txt , ${DEST_TOOLS}/ip-list.txt"
echo "  لاگ‌ها:          ${LOG_DIR}/*.log  و  ${LOG_DIR}/*.err"
echo
echo "چک‌کردن تایمرها:"
echo "  systemctl list-timers --all | grep cf-"
echo "لاگ سرویس:"
echo "  journalctl -u cf-*.service -e"

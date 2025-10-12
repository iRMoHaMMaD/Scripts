#!/usr/bin/env bash
set -euo pipefail

TARGET_SCRIPTS_DIR="/root/scripts"
TOOLS_DIR="/root/tools"
CONFIG_DIR="/etc/cf-orchestrator"
LOG_DIR="/var/log/cf-orchestrator"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[-] لطفاً با sudo اجرا کنید."
    exit 1
  fi
}

create_dirs() {
  mkdir -p "$TARGET_SCRIPTS_DIR" "$TOOLS_DIR" "$CONFIG_DIR" "$LOG_DIR"
  chmod 750 "$CONFIG_DIR"
}

copy_assets() {
  echo "[*] کپی اسکریپت‌ها به ${TARGET_SCRIPTS_DIR} ..."
  cp -f scripts/*.sh "$TARGET_SCRIPTS_DIR"/

  chmod +x "$TARGET_SCRIPTS_DIR"/*.sh || true

  # domains.txt و ip-list.txt
  if [[ -f "./domains.txt" ]]; then
    cp -f "./domains.txt" "${TOOLS_DIR}/domains.txt"
  else
    [[ -f "${TOOLS_DIR}/domains.txt" ]] || touch "${TOOLS_DIR}/domains.txt"
  fi

  if [[ -f "./ip-list.txt" ]]; then
    cp -f "./ip-list.txt" "${TOOLS_DIR}/ip-list.txt"
  else
    [[ -f "${TOOLS_DIR}/ip-list.txt" ]] || touch "${TOOLS_DIR}/ip-list.txt"
  fi
}

ensure_config() {
  if [[ ! -f "${CONFIG_DIR}/config.env" ]]; then
    echo "[*] ${CONFIG_DIR}/config.env موجود نیست؛ اجرای create_config_env.sh ..."
    if [[ -x "./create_config_env.sh" ]]; then
      bash ./create_config_env.sh --from ./config.env  || bash ./create_config_env.sh --from ./config.env.sample || bash ./create_config_env.sh
    else
      echo "[-] create_config_env.sh یافت نشد. ابتدا آن را اجرا کنید."
      exit 1
    fi
  fi
  chmod 640 "${CONFIG_DIR}/config.env"
}

normalize_unit_name() {
  local base="$1"
  base="${base##*/}"
  base="${base%.sh}"
  base="${base//_/-}"
  echo "cf-orch-${base}"
}

write_service_unit() {
  local script_name="$1"     # مثل cf.sh
  local unit_name="$2"       # مثل cf-orch-cf
  local boot="$3"            # yes/no

  cat > "/etc/systemd/system/${unit_name}.service" <<EOF
[Unit]
Description=Run ${script_name} (${unit_name})
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=${CONFIG_DIR}/config.env
WorkingDirectory=${TARGET_SCRIPTS_DIR}
ExecStart=/bin/bash ${TARGET_SCRIPTS_DIR}/${script_name}
StandardOutput=append:${LOG_DIR}/${unit_name}.log
StandardError=append:${LOG_DIR}/${unit_name}.err

[Install]
$( [[ "$boot" == "yes" ]] && echo "WantedBy=multi-user.target" || echo "; controlled by timer" )
EOF
}

write_timer_unit() {
  local unit_name="$1"
  local on_calendar="$2"
  cat > "/etc/systemd/system/${unit_name}.timer" <<EOF
[Unit]
Description=Timer for ${unit_name}

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

  # Boot services (هر ریبوت)
  for s in apply_wg_iptables.sh wg-tc-limiter.sh wgd_start.sh; do
    local_name="$(normalize_unit_name "$s")"
    write_service_unit "$s" "$local_name" "yes"
    systemctl enable --now "${local_name}.service" || true
  done

  # weekly: egress_block_by_domain.sh
  s="egress_block_by_domain.sh"
  local_name="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$local_name" "no"
  write_timer_unit "$local_name" "weekly"
  systemctl enable --now "${local_name}.timer"

  # hourly: cf.sh
  s="cf.sh"
  local_name="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$local_name" "no"
  write_timer_unit "$local_name" "hourly"
  systemctl enable --now "${local_name}.timer"

  # every 30 min: backup_to_telegram.sh
  s="backup_to_telegram.sh"
  local_name="$(normalize_unit_name "$s")"
  write_service_unit "$s" "$local_name" "no"
  write_timer_unit "$local_name" "*:0/30"
  systemctl enable --now "${local_name}.timer"

  systemctl daemon-reload
  echo "[+] یونیت‌ها و تایمرها ساخته و فعال شدند."
}

run_boot_now() {
  for u in cf-orch-apply-wg-iptables cf-orch-wg-tc-limiter cf-orch-wgd-start; do
    systemctl start "${u}.service" || true
  done
}

main() {
  need_root
  create_dirs
  copy_assets
  ensure_config
  setup_units
  run_boot_now

  echo
  echo "[✓] نصب و زمان‌بندی با موفقیت انجام شد."
  echo "مسیر اسکریپت‌ها: ${TARGET_SCRIPTS_DIR}"
  echo "پیکربندی: ${CONFIG_DIR}/config.env"
  echo "دیتا: ${TOOLS_DIR}/domains.txt , ${TOOLS_DIR}/ip-list.txt"
  echo "لاگ‌ها: ${LOG_DIR}/<unit>.log | <unit>.err"
  echo
  echo "دستورهای مفید:"
  echo "  systemctl list-timers | grep cf-orch-"
  echo "  journalctl -u cf-orch-*.service -e"
  echo "  systemctl start cf-orch-cf.service"
  echo "  systemctl start cf-orch-backup-to-telegram.service"
  echo "  systemctl start cf-orch-egress-block-by-domain.service"
}

main "$@"

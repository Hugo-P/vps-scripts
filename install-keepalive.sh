#!/usr/bin/env bash
#
# install-keepalive.sh
# Oracle Cloud Always Free 保活（降低 idle 回收機率）
#
# 背景：
#   依 Oracle 官方 Always Free 說明（2026 年版），Always Free 執行個體若在
#   「連續 7 天」內同時滿足以下三項，就會被判定為 idle，可能被停止
#   （不是刪除，開機磁碟通常保留）：
#     1. CPU 使用率（95th percentile）< 20%
#     2. 網路使用率 < 20%
#     3. 記憶體使用率 < 20%（僅適用 A1 / Ampere 機型）
#   https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
#
#   注意：Always Free 的 A1 額度只有 2 OCPU / 12 GB
#   （每月 1,500 OCPU 小時 + 9,000 GB 小時）。超過額度的 A1 若在免費帳戶，
#   試用期結束後會被停用、30 天後刪除，除非升級付費帳戶。
#
# 這支腳本用兩個 systemd 單元把指標盡量壓在門檻以上：
#   - oracle-keepalive.timer  每 30 分鐘跑一次：CPU 尖峰 + 小流量下載
#   - oracle-keepalive-mem    常駐持有總記憶體的 25%
#
# 為什麼 CPU 用尖峰、記憶體用常駐：
#   CPU 看的是 95th percentile，只要每小時有幾分鐘拉高就會過線，
#   平均用量可以很低；記憶體沒有寫 percentile，只能持續撐住。
#
# 支援：Ubuntu / Debian（需要 systemd）
# 特性：
#   - 只用 coreutils + python3，不安裝任何額外套件
#   - 記憶體守護行程 OOM 分數最高，資源吃緊時會第一個被殺，不影響主要服務
#   - 純選單操作，不接受任何參數
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-keepalive.sh | sudo bash
#   或先下載再執行：
#   curl -fsSLO https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-keepalive.sh
#   sudo bash install-keepalive.sh
#
# 注意：官方只說「7 天內三項都低於 20%」，取樣細節沒有公開，
#       任何腳本都只能「盡量」而無法保證。
#       升級成 Pay As You Go 後，資源不再屬於 "Always Free instance"，
#       實務上就不會被 idle 回收（官方沒有明文保證這一條）。
#
set -euo pipefail

# ---------- 固定設定 ----------
# 刻意不提供自訂：數值寫死，避免調歪
# 全部用「百分比」表達，換機型 / 改規格都不用重算絕對值
INTERVAL_MIN=30                 # 每隔幾分鐘觸發一次（分鐘）
DURATION=300                    # 每次尖峰持續幾秒
CPU_PERCENT=60                  # 尖峰時要吃掉的「整台機器」CPU 百分比
MEM_PERCENT=25                  # 常駐持有的記憶體百分比
ENABLE_NET=1                    # 是否在尖峰時順便下載一點流量
DOWNLOAD_URL="https://speed.cloudflare.com/__down?bytes=1048576"

UNIT_NAME="oracle-keepalive"
RUNTIME="/usr/local/sbin/${UNIT_NAME}.sh"
CONF_FILE="/etc/${UNIT_NAME}.conf"
UNIT_DIR="/etc/systemd/system"

# ---------- 顏色 ----------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi

log()  { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# ---------- 只接受選單 ----------
if [ $# -gt 0 ]; then
  err "這支腳本只提供選單，不接受參數：$*"
  err "直接執行即可：sudo bash $0"
  exit 1
fi

# 選單一定要有終端機才能讀輸入。
# curl ... | sudo bash 時 stdin 被腳本內容佔住，所以輸入一律從 /dev/tty 讀
MENU_INPUT="/dev/tty"
if ! { : < /dev/tty; } 2>/dev/null; then
  if [ -t 0 ]; then
    MENU_INPUT="/dev/stdin"
  else
    err "找不到終端機，選單需要互動式介面"
    err "  請先下載再執行："
    err "  curl -fsSLO https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-keepalive.sh"
    err "  sudo bash install-keepalive.sh"
    exit 1
  fi
fi

# 安裝 / 移除都需要 root，直接在這裡處理，程式碼就不用重複檢查
if [ "$(id -u)" -ne 0 ]; then
  if [ -f "$0" ] && [ -r "$0" ]; then
    exec sudo bash "$0"
  fi
  die "需要 root 權限（前面加 sudo，或直接 curl ... | sudo bash）"
fi

# ---------- 選單上的狀態摘要 ----------
# 摘要畫在選單上方；要更細的設定與執行紀錄再看「2. 查看狀態」
menu_status() {
  local nproc mem_total timer_state next mem_pid rss burst_state

  # 機器規格：不管有沒有安裝都先顯示，選單一打開就看得到
  nproc="$(nproc 2>/dev/null || echo 1)"
  mem_total="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  printf '  系統       ：%s 核 / %s MiB\n' "$nproc" "$mem_total"

  if [ ! -f "$CONF_FILE" ]; then
    printf '  狀態       ：%s未安裝%s\n' "$C_WARN" "$C_RESET"
    return 0
  fi

  printf '  狀態       ：%s已安裝%s\n' "$C_OK" "$C_RESET"

  # 尖峰正在跑時，timer 不會有「下次」時間，所以另外標示執行中
  burst_state="$(systemctl is-active "${UNIT_NAME}.service" 2>/dev/null || true)"
  timer_state="$(systemctl is-active "${UNIT_NAME}.timer" 2>/dev/null || true)"
  next="$(LC_ALL=C systemctl list-timers "${UNIT_NAME}.timer" --no-pager 2>/dev/null \
    | awk 'NR==2 && $1 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ {print $2" "$3}')"
  case "${timer_state:-unknown}" in
    active)       timer_text="${C_OK}運行中${C_RESET}" ;;
    activating)   timer_text="啟動中" ;;
    inactive)     timer_text="${C_WARN}未啟動${C_RESET}" ;;
    failed)       timer_text="${C_ERR}失敗${C_RESET}" ;;
    *)            timer_text="${timer_state:-unknown}" ;;
  esac
  printf '  定時器     ：%s' "$timer_text"
  if [ -n "$next" ]; then
    printf '（下次 %s）' "$next"
  elif [ "$burst_state" = "activating" ] || [ "$burst_state" = "active" ]; then
    printf '（尖峰執行中）'
  fi
  printf '\n'

  mem_pid="$(systemctl show -p MainPID --value "${UNIT_NAME}-mem.service" 2>/dev/null || echo 0)"
  if [ "${mem_pid:-0}" -gt 0 ] 2>/dev/null; then
    rss="$(awk '/VmRSS/{print int($2/1024)}' "/proc/$mem_pid/status" 2>/dev/null || echo 0)"
    printf '  記憶體守護 ：%s MiB（PID %s）\n' "${rss:-0}" "$mem_pid"
  fi

  # 最近一次尖峰：執行中就直接講，跑完才看 Result 與結束時間
  local last_result last_exit
  last_result="$(systemctl show -p Result --value "${UNIT_NAME}.service" 2>/dev/null || true)"
  last_exit="$(systemctl show -p ExecMainExitTimestamp --value "${UNIT_NAME}.service" 2>/dev/null || true)"

  if [ "$burst_state" = "activating" ] || [ "$burst_state" = "active" ]; then
    printf '  最近尖峰   ：執行中'
  else
    case "${last_result:-unknown}" in
      success) printf '  最近尖峰   ：%s成功%s' "$C_OK" "$C_RESET" ;;
      *)       printf '  最近尖峰   ：%s%s%s' "$C_ERR" "${last_result:-unknown}" "$C_RESET" ;;
    esac
  fi
  if [ -n "$last_exit" ] && [ "$last_exit" != "n/a" ]; then
    printf '（%s）' "$(LC_ALL=C date -d "$last_exit" '+%m-%d %H:%M' 2>/dev/null || echo "$last_exit")"
  fi
  printf '\n'
}

# ---------- 詳細狀態 ----------
# 選單上方只放摘要，這裡看設定內容、單元狀態與最近的執行紀錄
do_status() {
  step "keepalive 狀態"

  if [ ! -f "$CONF_FILE" ]; then
    warn "尚未安裝（找不到 $CONF_FILE）"
    return 1
  fi

  ok "設定檔：$CONF_FILE"
  sed -n 's/^KEEPALIVE_/  KEEPALIVE_/p' "$CONF_FILE"

  echo
  for u in "${UNIT_NAME}.timer" "${UNIT_NAME}-mem.service" "${UNIT_NAME}.service"; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      printf '  %-30s %s / %s\n' "$u" \
        "$(systemctl is-active "$u" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$u" 2>/dev/null || true)"
    fi
  done

  echo
  log "最近一次尖峰："
  printf '  Result=%s  退出碼=%s  結束時間=%s\n' \
    "$(systemctl show -p Result --value "${UNIT_NAME}.service" 2>/dev/null || echo '?')" \
    "$(systemctl show -p ExecMainStatus --value "${UNIT_NAME}.service" 2>/dev/null || echo '?')" \
    "$(systemctl show -p ExecMainExitTimestamp --value "${UNIT_NAME}.service" 2>/dev/null || echo '?')"
  journalctl -u "${UNIT_NAME}.service" -n 4 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true

  echo
  log "下次觸發："
  systemctl list-timers "${UNIT_NAME}.timer" --no-pager 2>/dev/null | sed 's/^/  /' || true

  MEM_PID="$(systemctl show -p MainPID --value "${UNIT_NAME}-mem.service" 2>/dev/null || echo 0)"
  if [ "${MEM_PID:-0}" -gt 0 ] 2>/dev/null; then
    RSS_KB="$(awk '/VmRSS/{print $2}' "/proc/${MEM_PID}/status" 2>/dev/null || echo 0)"
    log "記憶體守護：PID ${MEM_PID}，目前持有 $(( ${RSS_KB:-0} / 1024 )) MiB"
  else
    warn "記憶體守護沒有在執行"
  fi

  return 0
}

# ---------- 移除 ----------
do_uninstall() {
  step "移除 keepalive"

  systemctl disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
  systemctl disable --now "${UNIT_NAME}-mem.service" >/dev/null 2>&1 || true

  for f in \
    "${UNIT_DIR}/${UNIT_NAME}.timer" \
    "${UNIT_DIR}/${UNIT_NAME}.service" \
    "${UNIT_DIR}/${UNIT_NAME}-mem.service"
  do
    if [ -f "$f" ]; then
      rm -f "$f"
      ok "已刪除 $f"
    fi
  done

  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  for f in "$RUNTIME" "$CONF_FILE"; do
    if [ -f "$f" ]; then
      rm -f "$f"
      ok "已刪除 $f"
    fi
  done

  ok "已完全移除"
  return 0
}

# ---------- 安裝 ----------
do_install() {
  step "檢查系統"

  command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl，只支援 systemd 系統"
  [ -d /run/systemd/system ] || die "systemd 未在執行中（容器環境？）"
  ok "systemd 可用"

  NPROC="$(nproc 2>/dev/null || echo 1)"
  MEM_TOTAL_MIB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  ok "CPU：${NPROC} 核，記憶體：${MEM_TOTAL_MIB} MiB"

  # Always Free 的 A1 額度只有 2 OCPU / 12 GB，超過就屬於付費或試用資源
  if [ "$NPROC" -gt 2 ] || [ "$MEM_TOTAL_MIB" -gt 12288 ]; then
    warn "這台是 ${NPROC} OCPU / ${MEM_TOTAL_MIB} MiB，超過 Always Free 的 A1 額度（2 OCPU / 12 GB）"
    warn "表示它屬於付費或 Free Trial 資源，不會走 idle 回收這條路；"
    warn "反而要注意：免費試用結束後超額的 A1 會被停用、30 天後刪除，除非升級付費帳戶"
  fi

  step "固定設定"

  # 百分比換算成實際數值（顯示用；runtime 會自己再算一次）
  MEM_MIB=$(( MEM_TOTAL_MIB * MEM_PERCENT / 100 ))

  # 換算成實際 worker 數（CPU_PERCENT 是「整台機器」的百分比）
  WORKERS=$(( CPU_PERCENT * NPROC / 100 ))
  [ "$WORKERS" -ge 1 ] || WORKERS=1
  [ "$WORKERS" -le "$NPROC" ] || WORKERS="$NPROC"

  ok "每 ${INTERVAL_MIN} 分鐘，用 ${WORKERS}/${NPROC} 核跑 ${DURATION} 秒（整機 ${CPU_PERCENT}%）"
  ok "常駐記憶體：${MEM_PERCENT}%（≈ ${MEM_MIB} MiB，門檻 20%）"
  ok "尖峰時下載：$DOWNLOAD_URL"

  step "檢查現有安裝"

  INSTALLED=0
  [ -f "${UNIT_DIR}/${UNIT_NAME}.timer" ] && INSTALLED=1
  [ -f "$RUNTIME" ] && INSTALLED=1

  if [ "$INSTALLED" -eq 1 ]; then
    warn "偵測到已安裝，直接覆蓋（單元 + 執行檔 + 設定）"
  fi

  # 記憶體守護需要 python3
  if [ "$MEM_PERCENT" -gt 0 ] && ! command -v python3 >/dev/null 2>&1; then
    warn "找不到 python3，停用常駐記憶體"
    MEM_PERCENT=0
  fi

  step "寫入設定檔"

  cat > "$CONF_FILE" <<EOF
# oracle-keepalive 設定（由 install-keepalive.sh 產生）
# 全部是百分比，換機型 / 改規格都不用重算絕對值
# 修改後執行：sudo systemctl restart ${UNIT_NAME}-mem.service
KEEPALIVE_CPU_PERCENT=$CPU_PERCENT
KEEPALIVE_DURATION=$DURATION
KEEPALIVE_DOWNLOAD_ENABLED=$ENABLE_NET
KEEPALIVE_DOWNLOAD_URL="$DOWNLOAD_URL"
KEEPALIVE_MEM_PERCENT=$MEM_PERCENT
EOF
  chmod 644 "$CONF_FILE"
  ok "已寫入 $CONF_FILE"

  step "寫入執行檔"

  cat > "$RUNTIME" <<'RUNTIME_EOF'
#!/usr/bin/env bash
#
# oracle-keepalive.sh（執行檔，由 install-keepalive.sh 產生）
# 由 systemd 呼叫，不需要手動執行：
#   run       CPU 尖峰 + 小流量下載（oneshot）
#   hold-mem  常駐持有記憶體（simple，Restart=always）
#
set -uo pipefail

CONF_FILE="/etc/oracle-keepalive.conf"

# 預設值，會被設定檔覆蓋
KEEPALIVE_CPU_PERCENT=60
KEEPALIVE_DURATION=300
KEEPALIVE_DOWNLOAD_ENABLED=1
KEEPALIVE_DOWNLOAD_URL="https://speed.cloudflare.com/__down?bytes=1048576"
KEEPALIVE_MEM_PERCENT=0

# shellcheck disable=SC1090
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

PIDS=()

cleanup() {
  local p
  for p in "${PIDS[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

trap 'cleanup; exit 143' INT TERM

run_burst() {
  local nproc workers i started
  nproc="$(nproc 2>/dev/null || echo 1)"
  workers=$(( KEEPALIVE_CPU_PERCENT * nproc / 100 ))
  [ "$workers" -ge 1 ] || workers=1
  [ "$workers" -le "$nproc" ] || workers="$nproc"

  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "keepalive: 尖峰開始 $started，${workers}/${nproc} 核，${KEEPALIVE_DURATION}s"

  # 下載放在背景，和 CPU 尖峰同時進行
  if [ "${KEEPALIVE_DOWNLOAD_ENABLED:-0}" -eq 1 ] && [ -n "${KEEPALIVE_DOWNLOAD_URL:-}" ]; then
    curl -fsS --max-time 60 --limit-rate 2M -o /dev/null "$KEEPALIVE_DOWNLOAD_URL" \
      >/dev/null 2>&1 &
    PIDS+=("$!")
  fi

  # yes 是 coreutils 內建，最輕量的「純 CPU」佔用方式
  for ((i = 0; i < workers; i++)); do
    yes > /dev/null &
    PIDS+=("$!")
  done

  sleep "$KEEPALIVE_DURATION"

  cleanup
  PIDS=()
  echo "keepalive: 尖峰結束"
}

hold_mem() {
  exec python3 - "$KEEPALIVE_MEM_PERCENT" <<'PY'
import sys
import time

# 目標是「總記憶體的百分之幾」，這樣主機規格改了也不用重算
try:
    percent = int(sys.argv[1])
except (IndexError, ValueError):
    percent = 0

percent = max(0, min(percent, 80))
if percent == 0:
    print("keepalive: 記憶體百分比為 0，結束", flush=True)
    raise SystemExit(0)

total_mib = 0
try:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                total_mib = int(line.split()[1]) // 1024
                break
except OSError:
    total_mib = 0

if total_mib <= 0:
    print("keepalive: 讀不到 MemTotal，結束", flush=True)
    raise SystemExit(1)

size_mib = max(1, total_mib * percent // 100)
size = size_mib * 1024 * 1024
buf = bytearray(size)

# 逐頁寫入，確保是真正 resident，而不是 lazy allocation
page = 4096
for off in range(0, size, page):
    buf[off] = 1

print(f"keepalive: 已持有 {size_mib} MiB（總記憶體 {total_mib} MiB 的 {percent}%）", flush=True)

# 每 5 分鐘輕觸一次，避免被核心回收
while True:
    time.sleep(300)
    for off in range(0, size, page * 64):
        buf[off] = 1
PY
}

case "${1:-}" in
  run)      run_burst ;;
  hold-mem) hold_mem ;;
  *) echo "用法：$0 {run|hold-mem}" >&2; exit 2 ;;
esac
RUNTIME_EOF

  chmod 755 "$RUNTIME"
  ok "已寫入 $RUNTIME"

  step "寫入 systemd 單元"

  cat > "${UNIT_DIR}/${UNIT_NAME}.service" <<EOF
[Unit]
Description=Oracle Always Free keep-alive burst (CPU + download)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNTIME run
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=$(( DURATION + 120 ))
EOF
  ok "${UNIT_NAME}.service"

  cat > "${UNIT_DIR}/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Periodic keep-alive burst for Oracle Always Free

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL_MIN}min
AccuracySec=30s
RandomizedDelaySec=30
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
EOF
  ok "${UNIT_NAME}.timer"

  if [ "$MEM_PERCENT" -gt 0 ]; then
    cat > "${UNIT_DIR}/${UNIT_NAME}-mem.service" <<EOF
[Unit]
Description=Oracle Always Free keep-alive memory holder
After=network-online.target

[Service]
Type=simple
ExecStart=$RUNTIME hold-mem
Restart=always
RestartSec=10
Nice=19
# 資源吃緊時第一個被犧牲，避免影響真正在跑的服務
OOMScoreAdjust=1000
# 留一點餘裕給 page table 等開銷，避免剛好壓到上限被 cgroup OOM
MemoryMax=$(( MEM_MIB + 512 ))M

[Install]
WantedBy=multi-user.target
EOF
    ok "${UNIT_NAME}-mem.service"
  fi

  step "啟用"

  systemctl daemon-reload
  ok "daemon-reload"

  systemctl enable --now "${UNIT_NAME}.timer" >/dev/null 2>&1
  ok "timer 已啟用"

  if [ "$MEM_PERCENT" -gt 0 ]; then
    systemctl enable --now "${UNIT_NAME}-mem.service" >/dev/null 2>&1
    ok "記憶體守護已啟用"
  fi

  step "驗證"

  if systemctl is-active --quiet "${UNIT_NAME}.timer"; then
    ok "timer 運行中"
  else
    die "timer 未能啟動，請執行：systemctl status ${UNIT_NAME}.timer"
  fi

  if [ "$MEM_PERCENT" -gt 0 ]; then
    MEM_OK=0
    for _ in $(seq 1 20); do
      if systemctl is-active --quiet "${UNIT_NAME}-mem.service"; then
        MEM_OK=1
        break
      fi
      sleep 1
    done
    if [ "$MEM_OK" -eq 1 ]; then
      MEM_PID="$(systemctl show -p MainPID --value "${UNIT_NAME}-mem.service" 2>/dev/null || echo 0)"
      # 配置記憶體需要時間逐頁寫入，等 RSS 爬到目標的 90% 再回報
      RSS_MIB=0
      for _ in $(seq 1 30); do
        RSS_MIB="$(awk '/VmRSS/{print int($2/1024)}' "/proc/${MEM_PID:-0}/status" 2>/dev/null || echo 0)"
        [ "${RSS_MIB:-0}" -ge $(( MEM_MIB * 90 / 100 )) ] && break
        sleep 1
      done
      ok "記憶體守護運行中（PID $MEM_PID，$RSS_MIB MiB）"
      if [ "${RSS_MIB:-0}" -lt $(( MEM_MIB * 90 / 100 )) ]; then
        warn "持有量還沒到目標（$MEM_MIB MiB），請執行：systemctl status ${UNIT_NAME}-mem.service"
      fi
    else
      warn "記憶體守護未能啟動，請執行：systemctl status ${UNIT_NAME}-mem.service"
    fi
  fi

  # 測試只確認「跑得起來」，不等那 300 秒跑完，不然安裝要卡五分鐘
  log "手動觸發一次尖峰測試（不等它跑完）…"
  if systemctl start --no-block "${UNIT_NAME}.service"; then
    sleep 3
    BURST_STATE="$(systemctl is-active "${UNIT_NAME}.service" 2>/dev/null || true)"
    if [ "$BURST_STATE" = "activating" ] || [ "$BURST_STATE" = "active" ]; then
      ok "尖峰已啟動（狀態：$BURST_STATE，約 ${DURATION} 秒後自動結束）"
    else
      warn "尖峰沒有啟動成功，請執行：journalctl -u ${UNIT_NAME}.service -n 30"
    fi
  else
    warn "尖峰測試失敗（不影響 timer，稍後會自動重試）"
  fi

  step "完成"

  cat <<EOF
${C_BOLD}keepalive 安裝摘要${C_RESET}
  設定檔    : $CONF_FILE
  執行檔    : $RUNTIME
  尖峰頻率  : 每 ${INTERVAL_MIN} 分鐘一次，持續 ${DURATION} 秒
  CPU 用量  : ${WORKERS}/${NPROC} 核（整機 ${CPU_PERCENT}%）
  常駐記憶體: ${MEM_PERCENT}%（≈ ${MEM_MIB} MiB）
  額外流量  : 每次峰值 1 MiB 下載
EOF

  # 這裡只列「不需要參數」的指令；腳本本身的大小事都走選單
  cat <<EOF

${C_BOLD}常用指令${C_RESET}
  sudo bash install-keepalive.sh              # 選單（2 = 狀態、3 = 移除）
  systemctl list-timers | grep keepalive
  journalctl -u ${UNIT_NAME}.service -n 50
  sudo systemctl restart ${UNIT_NAME}-mem.service
EOF

  cat <<EOF

${C_BOLD}提醒${C_RESET}
  1. 這是「盡量」不是保證。官方只公布「7 天內三項都低於 20%」，
     取樣方式與判定細節沒有公開。
  2. Always Free 的 A1 額度是 2 OCPU / 12 GB。超過額度的機器屬於付費/試用資源，
     免費試用結束後會被停用、30 天後刪除，除非升級付費帳戶——這點保活腳本救不了。
  3. 升級成 Pay As You Go 後資源不再算 "Always Free instance"，
     實務上就不會被 idle 回收（官方未明文保證）。
  4. A1 另一個風險是「被停之後搶不到容量」，那也只能靠升級付費解決。
EOF

  ok "全部完成"
  return 0
}

# ---------- 選單 ----------
# 安裝 / 移除共用一把鎖：同時跑兩份會互相覆蓋檔案，先擋掉
with_lock() {
  local rc
  if command -v flock >/dev/null 2>&1; then
    exec 9>/run/oracle-keepalive-install.lock
    if ! flock -w 30 9; then
      warn "另一個安裝 / 移除程序還在執行，請稍後再試"
      exec 9>&-
      return 1
    fi
    "$@"
    rc=$?
    exec 9>&-
    return $rc
  fi
  "$@"
}

while :; do
  printf '\n%sOracle Always Free 保活%s（固定設定：30 分鐘 / 5 分鐘 / CPU 60%% / 記憶體 25%%）\n\n' \
    "$C_BOLD" "$C_RESET"

  # 先把目前的安裝狀態畫出來，就不用再花一個選項去查
  menu_status

  printf '\n  1. 安裝 / 重裝\n  2. 查看狀態\n  3. 移除\n  4. 退出\n'

  printf '\n選擇 [1-4]: '
  MENU_CHOICE=""
  read -r MENU_CHOICE < "$MENU_INPUT" || exit 0

  case "$MENU_CHOICE" in
    1) with_lock do_install ;;
    2) do_status || true ;;
    3) with_lock do_uninstall ;;
    4|"") exit 0 ;;
    *) warn "請輸入 1~4" ;;
  esac

  printf '\n'
  read -r -p "按 Enter 回選單…" _ < "$MENU_INPUT" || exit 0
done

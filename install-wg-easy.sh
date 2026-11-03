#!/usr/bin/env bash
#
# install-wg-easy.sh
# 一鍵安裝 WireGuard Easy（wg-easy v15）
#
# 支援：Ubuntu / Debian（需要 Docker）
# 特性：
#   - --host 默認自動偵測公網 IP
#   - --password 默認隨機生成 20 位密碼（結尾印出）
#   - --port 默認 51820
#   - 可重跑（已存在容器會提示，--force 才重建）
#   - 自動檢查 Docker / wireguard 模組 / port 佔用
#   - 自動等待 healthy 並驗證 Web UI
#
# 用法：
#   sudo bash install-wg-easy.sh
#   sudo bash install-wg-easy.sh --host vpn.example.com
#   sudo bash install-wg-easy.sh --password 'MyStr0ngPass' --port 51820
#   sudo bash install-wg-easy.sh --ui-port 51821 --dns 1.1.1.1,8.8.8.8
#   sudo bash install-wg-easy.sh --data-dir /opt/wg-easy --name my-wg
#   sudo bash install-wg-easy.sh --force          # 已存在就重建
#
set -euo pipefail

# ---------- 參數預設 ----------
WG_HOST=""
WG_PASSWORD=""
WG_PORT="51820"
UI_PORT="51821"
WG_DNS="1.1.1.1,8.8.8.8"
DATA_DIR=""
CONTAINER="wg-easy"
IMAGE_TAG="15"
FORCE=0
INSECURE="true"
DISABLE_IPV6="true"

# 保存原始參數，供 sudo 重新執行時使用
ORIG_ARGS=("$@")

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

usage() {
  cat <<'HELP'

install-wg-easy.sh — 一鍵安裝 WireGuard Easy (wg-easy v15)

參數（全部可選，括號內為預設）：
  --host HOST        公網 IP 或域名（自動偵測）
  --password PASS    Web UI 密碼（隨機 20 位）
  --port PORT        WireGuard UDP port（51820）
  --ui-port PORT     Web UI TCP port（51821）
  --dns LIST         推送給 client 的 DNS（1.1.1.1,8.8.8.8）
  --data-dir DIR     資料目錄（~/.wg-easy）
  --name NAME        容器名稱（wg-easy）
  --image TAG        image tag（15）
  --insecure BOOL    是否關閉 HTTPS 強制（true）
  --ipv6             啟用 IPv6（預設停用）
  --no-ipv6          停用 IPv6（預設）
  --force            容器已存在時強制重建
  --help             顯示此說明

例子：
  sudo bash install-wg-easy.sh
  sudo bash install-wg-easy.sh --host vpn.example.com
  sudo bash install-wg-easy.sh --port 51820 --ui-port 8080 --force

HELP
  exit 0
}

# ---------- 解析參數 ----------
need_val() { [ $# -ge 2 ] || die "$1 需要一個值"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)       need_val "$@"; WG_HOST="$2"; shift ;;
    --host=*)     WG_HOST="${1#*=}" ;;
    --password)   need_val "$@"; WG_PASSWORD="$2"; shift ;;
    --password=*) WG_PASSWORD="${1#*=}" ;;
    --port)       need_val "$@"; WG_PORT="$2"; shift ;;
    --port=*)     WG_PORT="${1#*=}" ;;
    --ui-port)    need_val "$@"; UI_PORT="$2"; shift ;;
    --ui-port=*)  UI_PORT="${1#*=}" ;;
    --dns)        need_val "$@"; WG_DNS="$2"; shift ;;
    --dns=*)      WG_DNS="${1#*=}" ;;
    --data-dir)   need_val "$@"; DATA_DIR="$2"; shift ;;
    --data-dir=*) DATA_DIR="${1#*=}" ;;
    --name)       need_val "$@"; CONTAINER="$2"; shift ;;
    --name=*)     CONTAINER="${1#*=}" ;;
    --image)      need_val "$@"; IMAGE_TAG="$2"; shift ;;
    --image=*)    IMAGE_TAG="${1#*=}" ;;
    --insecure)   need_val "$@"; INSECURE="$2"; shift ;;
    --insecure=*) INSECURE="${1#*=}" ;;
    --ipv6)       DISABLE_IPV6="false" ;;
    --no-ipv6)    DISABLE_IPV6="true" ;;
    --force)      FORCE=1 ;;
    -h|--help)    usage ;;
    *) die "未知參數：$1（用 --help 查看用法）" ;;
  esac
  shift
done

# ---------- 權限 ----------
if [ "$(id -u)" -ne 0 ]; then
  if [ -f "$0" ] && [ -r "$0" ]; then
    log "需要 root 權限，自動用 sudo 重新執行…"
    exec sudo bash "$0" "${ORIG_ARGS[@]}"
  fi
  err "需要 root 權限。用 pipe 執行時請直接加 sudo："
  err "  curl -fsSL <url> | sudo bash -s -- --host vpn.example.com"
  exit 1
fi

# 記錄原本的使用者（資料目錄放在他的 home）
TARGET_USER="${SUDO_USER:-}"
[ "$TARGET_USER" = "root" ] && TARGET_USER=""
if [ -n "$TARGET_USER" ]; then
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
  USER_HOME="$HOME"
fi
[ -n "$USER_HOME" ] || USER_HOME="/root"

# ---------- 驗證參數 ----------
step "檢查參數"

case "$WG_PORT" in (*[!0-9]*|"") die "--port 必須是數字：$WG_PORT" ;; esac
[ "$WG_PORT" -ge 1 ] && [ "$WG_PORT" -le 65535 ] || die "--port 超出範圍：$WG_PORT"

case "$UI_PORT" in (*[!0-9]*|"") die "--ui-port 必須是數字：$UI_PORT" ;; esac
[ "$UI_PORT" -ge 1 ] && [ "$UI_PORT" -le 65535 ] || die "--ui-port 超出範圍：$UI_PORT"

[ "$WG_PORT" != "$UI_PORT" ] || die "--port 與 --ui-port 不能相同"

ok "WireGuard port：$WG_PORT/udp"
ok "Web UI port：$UI_PORT/tcp"

# 若資料目錄已存在 wg0.conf，沿用其 ListenPort（改 port 需在 Web UI 或用新目錄）
CHECK_DIR="${DATA_DIR:-$USER_HOME/.wg-easy}"
if [ -f "$CHECK_DIR/wg0.conf" ]; then
  EXISTING_PORT="$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$CHECK_DIR/wg0.conf" | head -1)"
  if [ -n "$EXISTING_PORT" ] && [ "$EXISTING_PORT" != "$WG_PORT" ]; then
    warn "現有設定使用 UDP $EXISTING_PORT，--port $WG_PORT 不會生效，將改用 $EXISTING_PORT"
    WG_PORT="$EXISTING_PORT"
  fi
fi

# ---------- 資料目錄 ----------
if [ -z "$DATA_DIR" ]; then
  DATA_DIR="$USER_HOME/.wg-easy"
fi

# ---------- 檢查 Docker ----------
step "檢查 Docker"

command -v docker >/dev/null 2>&1 || die "未安裝 Docker。請先執行：curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-docker.sh | sudo bash"
docker info >/dev/null 2>&1 || die "Docker daemon 未運行"
ok "Docker $(docker version --format '{{.Server.Version}}')"

# ---------- 檢查 wireguard 模組 ----------
step "檢查 WireGuard 模組"

if [ ! -d "/lib/modules/$(uname -r)" ]; then
  die "找不到 /lib/modules/$(uname -r)，無法掛載模組"
fi
ok "/lib/modules/$(uname -r) 存在"

if modinfo wireguard >/dev/null 2>&1; then
  ok "wireguard 模組可用"
else
  warn "modinfo wireguard 失敗（可能已 built-in，繼續嘗試）"
fi

# ---------- 檢查 port 佔用 ----------
step "檢查 port 佔用"

port_busy() {
  local p="$1" proto="$2" name="$3"
  if ss -Htuln 2>/dev/null | awk '{print $1" "$5}' | grep -qE "^${proto}.*:${p}$"; then
    # 如果是我們自己的容器就不算衝突
    local owner
    owner="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E ":${p}->" | awk '{print $1}' | head -1 || true)"
    if [ "$owner" = "$name" ]; then
      return 1
    fi
    return 0
  fi
  return 1
}

if port_busy "$WG_PORT" "udp" "$CONTAINER"; then
  die "UDP $WG_PORT 已被其他程式佔用"
fi
if port_busy "$UI_PORT" "tcp" "$CONTAINER"; then
  die "TCP $UI_PORT 已被其他程式佔用"
fi
ok "port 空閒"

# ---------- 已存在容器 ----------
step "檢查現有容器"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if [ "$FORCE" -eq 0 ]; then
    err "容器 '$CONTAINER' 已存在。"
    err "  - 想重建：加 --force（原有資料目錄會保留）"
    err "  - 想查看狀態：docker ps -a | grep $CONTAINER"
    exit 1
  fi
  warn "--force：將刪除現有容器（資料目錄保留）"
  docker rm -f "$CONTAINER" >/dev/null
  ok "已刪除舊容器"
else
  ok "沒有同名容器"
fi

# ---------- 自動偵測公網 IP ----------
step "決定連線主機"

if [ -z "$WG_HOST" ]; then
  log "未指定 --host，自動偵測公網 IP…"
  for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    detected="$(curl -fsS --max-time 6 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if printf '%s' "$detected" | grep -qE '^[0-9a-fA-F:.]+$' && [ -n "$detected" ]; then
      WG_HOST="$detected"
      break
    fi
  done
  if [ -n "$WG_HOST" ]; then
    ok "偵測到：$WG_HOST"
  else
    die "無法偵測公網 IP，請用 --host 指定（例如 --host vpn.example.com）"
  fi
else
  ok "使用指定主機：$WG_HOST"
fi

# ---------- 生成密碼 ----------
step "準備登入憑證"

PASSWORD_GENERATED=0
if [ -z "$WG_PASSWORD" ]; then
  # 注意：pipefail 下 head 提前關閉會導致 tr 收到 SIGPIPE，需要加 || true
  WG_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || true)"
  [ ${#WG_PASSWORD} -eq 20 ] || die "隨機密碼生成失敗，請用 --password 指定"
  PASSWORD_GENERATED=1
  ok "已生成隨機密碼（結尾會顯示）"
else
  ok "使用指定密碼"
fi

[ ${#WG_PASSWORD} -ge 8 ] || warn "密碼少於 8 位，建議加長"

# ---------- 建立目錄與 env ----------
step "建立資料目錄與環境設定"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

ENV_FILE="$DATA_DIR/wg-easy.env"

# 如果已有 db，代表已初始化，不需要再寫入 INIT_*
INIT_BLOCK=""
if [ ! -f "$DATA_DIR/wg-easy.db" ]; then
  INIT_BLOCK="$(cat <<EOF
INIT_ENABLED=true
INIT_USERNAME=admin
INIT_PASSWORD=$WG_PASSWORD
INIT_HOST=$WG_HOST
INIT_PORT=$WG_PORT
INIT_DNS=$WG_DNS
EOF
)"
else
  warn "偵測到已初始化的資料庫，跳過 INIT_*（沿用原有帳號密碼）"
fi

cat > "$ENV_FILE" <<EOF
INSECURE=$INSECURE
DISABLE_IPV6=$DISABLE_IPV6
PORT=$UI_PORT
HOST=0.0.0.0
$INIT_BLOCK
EOF
chmod 600 "$ENV_FILE"
ok "已寫入 $ENV_FILE"

# ---------- 啟動容器 ----------
step "啟動容器"

IMAGE="ghcr.io/wg-easy/wg-easy:$IMAGE_TAG"
log "使用 image：$IMAGE"
docker pull "$IMAGE" >/dev/null 2>&1 || warn "拉取 image 失敗，嘗試使用本地緩存"

docker run -d \
  --name "$CONTAINER" \
  --env-file "$ENV_FILE" \
  -v "$DATA_DIR:/etc/wireguard" \
  -v /lib/modules:/lib/modules:ro \
  -p "${WG_PORT}:${WG_PORT}/udp" \
  -p "${UI_PORT}:${UI_PORT}/tcp" \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --restart unless-stopped \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  "$IMAGE" >/dev/null

ok "容器已建立"

# ---------- 等待 healthy ----------
step "等待服務就緒"

HEALTH=""
for _ in $(seq 1 45); do
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  case "$HEALTH" in
    healthy) break ;;
    unhealthy) die "容器狀態 unhealthy，請執行：docker logs $CONTAINER" ;;
  esac
  sleep 2
done

RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"
[ "$RUNNING" = "true" ] || die "容器未能啟動，請執行：docker logs $CONTAINER"
ok "容器運行中（health: $HEALTH）"

# ---------- 驗證 Web UI ----------
step "驗證 Web UI"

HTTP_CODE="000"
for _ in $(seq 1 10); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${UI_PORT}/" 2>/dev/null || true)"
  [ -n "$HTTP_CODE" ] || HTTP_CODE="000"
  case "$HTTP_CODE" in
    200|301|302|307|308) break ;;
  esac
  sleep 2
done

case "$HTTP_CODE" in
  200|301|302|307|308) ok "本地 Web UI 回應 HTTP $HTTP_CODE" ;;
  *) warn "本地 Web UI 回應 HTTP $HTTP_CODE（可能仍在啟動，請查看 docker logs $CONTAINER）" ;;
esac

if docker exec "$CONTAINER" wg show >/dev/null 2>&1; then
  ok "WireGuard 介面已啟動"
else
  warn "wg show 失敗，檢查：docker logs $CONTAINER"
fi

# ---------- 摘要 ----------
step "完成"

PUBLIC_IP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"

cat <<EOF
${C_BOLD}wg-easy 安裝摘要${C_RESET}
  容器      : $CONTAINER
  Image     : $IMAGE
  資料目錄  : $DATA_DIR
  WireGuard : udp/$WG_PORT
  Web UI    : tcp/$UI_PORT
  DNS       : $WG_DNS
  IPv6      : $([ "$DISABLE_IPV6" = "true" ] && echo 已停用 || echo 已啟用)

${C_BOLD}登入資料${C_RESET}
  網址：http://$WG_HOST:$UI_PORT
  帳號：admin
  密碼：$WG_PASSWORD
EOF

if [ "$PASSWORD_GENERATED" -eq 1 ]; then
  warn "這個密碼是隨機生成，請立即記錄（只會顯示這一次）"
fi

cat <<EOF

${C_BOLD}防火牆提醒（一定要做）${C_RESET}
  1. 雲端安全組 / Security List 要開：
       UDP $WG_PORT   （VPN 連線）
       TCP $UI_PORT   （管理介面）
  2. 主機防火牆（ufw / firewalld）如有啟用，同樣要放行
EOF

if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$WG_HOST" ]; then
  warn "你指定的 host（$WG_HOST）與偵測到的公網 IP（$PUBLIC_IP）不一致，請確認 DNS 設定正確"
fi

cat <<EOF

${C_BOLD}常用指令${C_RESET}
  docker logs -f $CONTAINER        # 查看日誌
  docker restart $CONTAINER        # 重啟
  docker exec $CONTAINER wg show   # 查看連線狀態
EOF

ok "全部完成"

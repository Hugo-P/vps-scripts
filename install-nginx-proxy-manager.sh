#!/usr/bin/env bash
#
# install-nginx-proxy-manager.sh
# 一鍵安裝 Nginx Proxy Manager（NPM）
#
# 支援：任何已安裝 Docker 的 Linux（Ubuntu / Debian 等）
# 特性：
#   - 端口可自訂（host 端口被佔用時可換）
#   - 資料目錄持久化（data + letsencrypt）
#   - 可重跑（已存在容器會提示，--force 才重建）
#   - 自動檢查 Docker / port 佔用
#   - 自動等待 Web UI 就緒
#
# 用法：
#   sudo bash install-nginx-proxy-manager.sh
#   sudo bash install-nginx-proxy-manager.sh --http-port 8080 --https-port 8443 --admin-port 8181
#   sudo bash install-nginx-proxy-manager.sh --data-dir /opt/npm
#   sudo bash install-nginx-proxy-manager.sh --force
#
set -euo pipefail

# ---------- 參數預設 ----------
HTTP_PORT="80"
HTTPS_PORT="443"
ADMIN_PORT="81"
DATA_DIR=""
CONTAINER="nginx-proxy-manager"
IMAGE="jc21/nginx-proxy-manager:latest"
FORCE=0
# 預設停用容器 IPv6（--ipv6 可開啟）
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

install-nginx-proxy-manager.sh — 一鍵安裝 Nginx Proxy Manager

參數（全部可選，括號內為預設）：
  --http-port PORT    HTTP 對外端口（80）
  --https-port PORT   HTTPS 對外端口（443）
  --admin-port PORT   管理介面對外端口（81）
  --data-dir DIR      資料目錄（~/.nginx-proxy-manager）
  --name NAME         容器名稱（nginx-proxy-manager）
  --image TAG         image（jc21/nginx-proxy-manager:latest）
  --ipv6              啟用容器 IPv6（預設停用）
  --force             容器已存在時強制重建
  --help              顯示此說明

例子：
  sudo bash install-nginx-proxy-manager.sh
  sudo bash install-nginx-proxy-manager.sh --admin-port 8181
  sudo bash install-nginx-proxy-manager.sh --http-port 8080 --https-port 8443

注意：
  Let's Encrypt 的 HTTP-01 驗證必須由 port 80 回應，
  所以簽證書前 HTTP/HTTPS 一定要保持 80 / 443。

HELP
  exit 0
}

# ---------- 解析參數 ----------
need_val() { [ $# -ge 2 ] || die "$1 需要一個值"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --http-port)   need_val "$@"; HTTP_PORT="$2"; shift ;;
    --http-port=*) HTTP_PORT="${1#*=}" ;;
    --https-port)  need_val "$@"; HTTPS_PORT="$2"; shift ;;
    --https-port=*) HTTPS_PORT="${1#*=}" ;;
    --admin-port)  need_val "$@"; ADMIN_PORT="$2"; shift ;;
    --admin-port=*) ADMIN_PORT="${1#*=}" ;;
    --data-dir)    need_val "$@"; DATA_DIR="$2"; shift ;;
    --data-dir=*)  DATA_DIR="${1#*=}" ;;
    --name)        need_val "$@"; CONTAINER="$2"; shift ;;
    --name=*)      CONTAINER="${1#*=}" ;;
    --image)       need_val "$@"; IMAGE="$2"; shift ;;
    --image=*)     IMAGE="${1#*=}" ;;
    --ipv6)        DISABLE_IPV6="false" ;;
    --no-ipv6)     DISABLE_IPV6="true" ;;
    --force)       FORCE=1 ;;
    -h|--help)     usage ;;
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
  err "  curl -fsSL <url> | sudo bash -s -- --admin-port 8181"
  exit 1
fi

# 資料目錄放在原使用者 home
TARGET_USER="${SUDO_USER:-}"
[ "$TARGET_USER" = "root" ] && TARGET_USER=""
if [ -n "$TARGET_USER" ]; then
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
  USER_HOME="$HOME"
fi
[ -n "$USER_HOME" ] || USER_HOME="/root"
if [ -z "$DATA_DIR" ]; then
  DATA_DIR="$USER_HOME/.nginx-proxy-manager"
fi

# ---------- 驗證參數 ----------
step "檢查參數"

validate_port() {
  local name="$1" val="$2"
  case "$val" in (*[!0-9]*|"") die "$name 必須是數字：$val" ;; esac
  [ "$val" -ge 1 ] && [ "$val" -le 65535 ] || die "$name 超出範圍：$val"
}
validate_port "--http-port" "$HTTP_PORT"
validate_port "--https-port" "$HTTPS_PORT"
validate_port "--admin-port" "$ADMIN_PORT"

if [ "$HTTP_PORT" = "$HTTPS_PORT" ] || [ "$HTTP_PORT" = "$ADMIN_PORT" ] || [ "$HTTPS_PORT" = "$ADMIN_PORT" ]; then
  die "三個 port 不能重複（$HTTP_PORT / $HTTPS_PORT / $ADMIN_PORT）"
fi

ok "HTTP：$HTTP_PORT → 容器 80"
ok "HTTPS：$HTTPS_PORT → 容器 443"
ok "管理介面：$ADMIN_PORT → 容器 81"

# ---------- 檢查 Docker ----------
step "檢查 Docker"

command -v docker >/dev/null 2>&1 || die "未安裝 Docker。請先執行：curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-docker.sh | sudo bash"
docker info >/dev/null 2>&1 || die "Docker daemon 未運行"
ok "Docker $(docker version --format '{{.Server.Version}}')"

# ---------- 檢查 port 佔用 ----------
step "檢查 port 佔用"

port_busy() {
  local p="$1"
  local owner
  owner="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":${p}->" | awk '{print $1}' | head -1 || true)"
  if [ "$owner" = "$CONTAINER" ]; then
    return 1   # 自己的容器佔用，不算衝突
  fi
  if [ -n "$owner" ]; then
    PORT_OWNER="$owner"
    return 0
  fi
  if ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
    PORT_OWNER="(非 Docker 程序)"
    return 0
  fi
  return 1
}

PORT_OWNER=""
for pair in "$HTTP_PORT:HTTP" "$HTTPS_PORT:HTTPS" "$ADMIN_PORT:管理介面"; do
  p="${pair%%:*}"
  label="${pair##*:}"
  if port_busy "$p"; then
    die "port $p（$label）已被 $PORT_OWNER 佔用。請用 --http-port / --https-port / --admin-port 更換端口。"
  fi
done
ok "三個 port 都空閒"

# ---------- 已存在容器 ----------
step "檢查現有容器"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if [ "$FORCE" -eq 0 ]; then
    err "容器 '$CONTAINER' 已存在。"
    err "  - 想重建：加 --force（資料目錄會保留）"
    err "  - 想查看狀態：docker ps -a | grep $CONTAINER"
    exit 1
  fi
  warn "--force：將刪除現有容器（資料目錄保留）"
  docker rm -f "$CONTAINER" >/dev/null
  ok "已刪除舊容器"
else
  ok "沒有同名容器"
fi

# ---------- 建立目錄 ----------
step "建立資料目錄"

mkdir -p "$DATA_DIR/data" "$DATA_DIR/letsencrypt"
ok "資料：$DATA_DIR/data"
ok "憑證：$DATA_DIR/letsencrypt"

# ---------- 拉 image ----------
step "拉取 image"

log "使用 image：$IMAGE"
docker pull "$IMAGE" 2>&1 | tail -3 || warn "拉取失敗，嘗試使用本地緩存"

# ---------- 啟動容器 ----------
step "啟動容器"

ENV_ARGS=()
if [ "$DISABLE_IPV6" = "true" ]; then
  ENV_ARGS+=(-e DISABLE_IPV6=true)
fi

docker run -d \
  --name "$CONTAINER" \
  "${ENV_ARGS[@]}" \
  -p "${HTTP_PORT}:80" \
  -p "${HTTPS_PORT}:443" \
  -p "${ADMIN_PORT}:81" \
  -v "$DATA_DIR/data:/data" \
  -v "$DATA_DIR/letsencrypt:/etc/letsencrypt" \
  --restart unless-stopped \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  "$IMAGE" >/dev/null

ok "容器已建立"

# ---------- 等待就緒 ----------
step "等待服務就緒"

HTTP_CODE="000"
for _ in $(seq 1 40); do
  RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"
  [ "$RUNNING" = "true" ] || die "容器未能啟動，請執行：docker logs $CONTAINER"

  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null || true)"
  [ -n "$HTTP_CODE" ] || HTTP_CODE="000"
  case "$HTTP_CODE" in
    200|301|302|307|308) break ;;
  esac
  sleep 3
done

case "$HTTP_CODE" in
  200|301|302|307|308) ok "管理介面已就緒（HTTP $HTTP_CODE）" ;;
  *) warn "管理介面回應 HTTP $HTTP_CODE（NPM 首次啟動需要生成密鑰，可能要再等 1–2 分鐘）" ;;
esac

# ---------- 摘要 ----------
step "完成"

PUBLIC_IP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"

cat <<EOF
${C_BOLD}Nginx Proxy Manager 安裝摘要${C_RESET}
  容器      : $CONTAINER
  Image     : $IMAGE
  資料目錄  : $DATA_DIR
  HTTP      : $HTTP_PORT → 80
  HTTPS     : $HTTPS_PORT → 443
  管理介面  : $ADMIN_PORT → 81
  IPv6      : $([ "$DISABLE_IPV6" = "true" ] && echo 已停用 || echo 已啟用)

${C_BOLD}登入資料（首次）${C_RESET}
  網址：http://$([ -n "$PUBLIC_IP" ] && echo "$PUBLIC_IP" || echo "你的VPS IP"):$ADMIN_PORT
  帳號：admin@example.com
  密碼：changeme

${C_WARN}首次登入後會強制修改電子郵件和密碼。${C_RESET}
EOF

cat <<EOF

${C_BOLD}防火牆提醒${C_RESET}
  1. 雲端安全組 / Security List 要開：
       TCP $HTTP_PORT   （HTTP）
       TCP $HTTPS_PORT  （HTTPS）
       TCP $ADMIN_PORT  （管理介面，建議限制來源 IP）
  2. 主機 ufw / firewalld 如有啟用，同樣要放行

${C_BOLD}常見用法${C_RESET}
  docker logs -f $CONTAINER
  docker restart $CONTAINER
  docker exec $CONTAINER nginx -s reload
EOF

if [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTPS_PORT" -lt 1024 ]; then
  warn "你使用 1024 以下端口，如果主機有其他 web server（nginx/apache）需要先停用"
fi

# Let's Encrypt 的 HTTP-01 驗證必須由 port 80 回應，改了端口就無法簽發證書
if [ "$HTTP_PORT" != "80" ] || [ "$HTTPS_PORT" != "443" ]; then
  warn "你改了 HTTP/HTTPS 端口（$HTTP_PORT / $HTTPS_PORT）"
  warn "  Let's Encrypt HTTP-01 驗證需要 port 80 → 容器 80，否則簽發證書會失敗"
  warn "  解決方法：換回 80/443，或者在 NPM 使用 DNS Challenge / 上傳自有證書"
fi

if [ "$(uname -m)" = "armv7l" ]; then
  warn "armv7 不支援 2.14+，請改用 --image jc21/nginx-proxy-manager:2.13.7"
fi

ok "全部完成"

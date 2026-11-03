#!/usr/bin/env bash
#
# install-docker.sh
# 一鍵安裝 Docker CE（官方 APT repo 版本）
#
# 支援：Ubuntu / Debian，x86_64(amd64) / arm64
# 特性：
#   - 自動偵測 distro / codename / 架構
#   - 可重跑（已安裝會跳過，不會重複加 repo）
#   - 可選中國鏡像加速
#   - 默認寫入 daemon.json（log 輪替 + live-restore）
#
# 用法：
#   sudo bash install-docker.sh                    # 默認寫 daemon.json
#   sudo bash install-docker.sh --no-daemon-json  # 不寫 daemon.json
#   sudo bash install-docker.sh --mirror cn
#   sudo bash install-docker.sh --force            # 強制重裝
#
set -euo pipefail

# ---------- 參數預設 ----------
# 默認會寫入 daemon.json（log 輪替 + live-restore）
# 用 --no-daemon-json 可以關閉
USE_MIRROR=""
WRITE_DAEMON_JSON=1
FORCE=0

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

install-docker.sh — 一鍵安裝 Docker CE（官方 APT repo 版本）

支援：Ubuntu / Debian，x86_64(amd64) / arm64
特性：
  - 自動偵測 distro / codename / 架構
  - 可重跑（已安裝會跳過，不會重複加 repo）
  - 可選中國鏡像加速
  - 默認寫入 daemon.json（log 輪替 + live-restore）

用法：
  sudo bash install-docker.sh                    # 默認寫 daemon.json
  sudo bash install-docker.sh --no-daemon-json  # 不寫 daemon.json
  sudo bash install-docker.sh --mirror cn
  sudo bash install-docker.sh --force            # 強制重裝
  sudo bash install-docker.sh --help

HELP
  exit 0
}

# ---------- 解析參數 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --mirror)
      shift
      [ $# -gt 0 ] || die "--mirror 需要一個值（cn）"
      USE_MIRROR="$1"
      ;;
    --mirror=*) USE_MIRROR="${1#*=}" ;;
    --daemon-json) WRITE_DAEMON_JSON=1 ;;
    --no-daemon-json) WRITE_DAEMON_JSON=0 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    *) die "未知參數：$1（用 --help 查看用法）" ;;
  esac
  shift
done

# ---------- 權限 ----------
if [ "$(id -u)" -ne 0 ]; then
  # 由檔案執行：可以自動 sudo 重跑
  # 由 pipe 執行（curl | bash）：$0 不是真實檔案，只能提示使用 sudo
  if [ -f "$0" ] && [ -r "$0" ]; then
    log "需要 root 權限，自動用 sudo 重新執行…"
    exec sudo bash "$0" "${ORIG_ARGS[@]}"
  fi
  err "需要 root 權限。用 pipe 執行時請直接加 sudo："
  err "  curl -fsSL <url> | sudo bash -s -- --daemon-json"
  exit 1
fi

# 記錄原本的使用者（用來加入 docker group）
TARGET_USER="${SUDO_USER:-}"
[ "$TARGET_USER" = "root" ] && TARGET_USER=""

# ---------- 偵測系統 ----------
step "偵測系統"

[ -r /etc/os-release ] || die "找不到 /etc/os-release，無法判斷系統"
# shellcheck disable=SC1091
. /etc/os-release

DISTRO_ID="${ID:-}"
DISTRO_CODENAME="${VERSION_CODENAME:-}"
DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"

case "$DISTRO_ID" in
  ubuntu|debian) ;;
  *) die "只支援 Ubuntu / Debian，目前系統：${DISTRO_PRETTY}" ;;
esac

[ -n "$DISTRO_CODENAME" ] || die "無法取得 codename（VERSION_CODENAME 為空）"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64|armhf) ;;
  *) die "不支援的架構：$ARCH" ;;
esac

ok "系統：$DISTRO_PRETTY"
ok "Codename：$DISTRO_CODENAME"
ok "架構：$ARCH"

# ---------- 鏡像 ----------
REPO_HOST="download.docker.com"
case "$USE_MIRROR" in
  "") ;;
  cn|CN|china)
    REPO_HOST="mirrors.aliyun.com/docker-ce"
    warn "使用阿里雲鏡像：$REPO_HOST（GPG key 仍由官方下載）"
    ;;
  *) die "不支援的鏡像：$USE_MIRROR（目前只有 cn）" ;;
esac

# ---------- 已安裝檢查 ----------
step "檢查現有安裝"

ALREADY=0
if dpkg -s docker-ce >/dev/null 2>&1; then
  ALREADY=1
  CUR_VER="$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || echo unknown)"
  if [ "$FORCE" -eq 1 ]; then
    warn "已安裝 docker-ce ($CUR_VER)，--force 指定重裝"
  else
    ok "已安裝 docker-ce ($CUR_VER)，將跳過安裝步驟"
  fi
fi

# ---------- 前置工具 ----------
step "安裝前置工具"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || die "apt-get update 失敗（檢查網絡）"
apt-get install -y -qq ca-certificates curl gnupg >/dev/null
ok "ca-certificates / curl / gnupg 就緒"

# ---------- 移除衝突套件 ----------
if [ "$ALREADY" -eq 0 ] || [ "$FORCE" -eq 1 ]; then
  step "移除衝突套件（docker.io / podman-docker / 舊 containerd）"

  CONFLICTS=""
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      CONFLICTS="$CONFLICTS $pkg"
    fi
  done

  if [ -n "$CONFLICTS" ]; then
    warn "將移除：$CONFLICTS"
    # 注意：不使用 --purge，保留 /var/lib/docker 與 /var/lib/containerd 資料
    apt-get remove -y -qq $CONFLICTS >/dev/null 2>&1 || true
    ok "已移除衝突套件（容器資料保留）"
  else
    ok "沒有衝突套件"
  fi
fi

# ---------- GPG key ----------
step "設定官方 GPG key"

KEYRING="/etc/apt/keyrings/docker.asc"
install -m 0755 -d /etc/apt/keyrings

if [ -s "$KEYRING" ]; then
  ok "GPG key 已存在：$KEYRING"
else
  curl -fsSL --retry 3 --retry-delay 2 \
    https://download.docker.com/linux/"$DISTRO_ID"/gpg -o "$KEYRING" \
    || die "下載 GPG key 失敗"
  chmod a+r "$KEYRING"
  ok "已下載 GPG key"
fi

# ---------- APT repo ----------
step "設定 APT repo"

REPO_FILE="/etc/apt/sources.list.d/docker.list"
REPO_LINE="deb [arch=${ARCH} signed-by=${KEYRING}] https://${REPO_HOST}/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable"

CUR_REPO=""
[ -f "$REPO_FILE" ] && CUR_REPO="$(tr -d '\n' < "$REPO_FILE" | sed 's/  */ /g')"

if [ "$CUR_REPO" = "$REPO_LINE" ]; then
  ok "repo 已存在且正確"
else
  # 備份舊檔
  [ -f "$REPO_FILE" ] && cp -a "$REPO_FILE" "${REPO_FILE}.bak.$(date +%s)"
  printf '%s\n' "$REPO_LINE" > "$REPO_FILE"
  ok "已寫入：$REPO_FILE"
fi
printf '    %s\n' "$REPO_LINE"

apt-get update -qq || die "apt-get update 失敗（repo 可能無此 codename 的套件）"

# ---------- 安裝 Docker ----------
if [ "$ALREADY" -eq 0 ] || [ "$FORCE" -eq 1 ]; then
  step "安裝 Docker CE"

  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || die "安裝失敗"
  ok "Docker CE 安裝完成"
else
  step "確保套件齊全（buildx / compose）"
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
  ok "套件已是最新"
fi

# ---------- 啟動服務 ----------
step "啟動服務"

systemctl enable --now docker >/dev/null 2>&1 || die "啟動 docker 失敗"
systemctl is-active --quiet docker || die "docker 服務未啟動"
ok "docker 服務：active + enabled"

# ---------- 使用者群組 ----------
if [ -n "$TARGET_USER" ]; then
  step "設定免 sudo（docker group）"

  if id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
    ok "$TARGET_USER 已在 docker group"
  else
    usermod -aG docker "$TARGET_USER"
    ok "$TARGET_USER 已加入 docker group"
    warn "需要登出再登入（或執行 newgrp docker）才生效"
  fi
else
  warn "偵測不到一般使用者（可能直接以 root 執行），跳過 group 設定"
fi

# ---------- daemon.json ----------
if [ "$WRITE_DAEMON_JSON" -eq 1 ]; then
  step "寫入 /etc/docker/daemon.json"

  DAEMON_JSON="/etc/docker/daemon.json"
  mkdir -p /etc/docker

  NEW_JSON='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}'

  # 內容相同就不重啟（避免不必要的斷線）
  if [ -f "$DAEMON_JSON" ] && \
     [ "$(tr -d ' \t\n\r' < "$DAEMON_JSON")" = "$(printf '%s' "$NEW_JSON" | tr -d ' \t\n\r')" ]; then
    ok "daemon.json 已是相同設定，跳過重啟"
  else
    if [ -f "$DAEMON_JSON" ]; then
      BACKUP="${DAEMON_JSON}.bak.$(date +%s)"
      cp -a "$DAEMON_JSON" "$BACKUP"
      warn "已備份舊設定到 $BACKUP（注意：會被完整覆蓋）"
    fi

    printf '%s\n' "$NEW_JSON" > "$DAEMON_JSON"

    systemctl restart docker || die "重啟 docker 失敗（daemon.json 可能有誤）"
    systemctl is-active --quiet docker || die "重啟後 docker 未運行"
    ok "daemon.json 已寫入並重啟"
  fi
  ok "log 上限：每個容器 10m × 3 = 30MB"
else
  warn "未寫入 daemon.json（已用 --no-daemon-json 關閉）"
fi

# ---------- 驗證 ----------
step "驗證"

SERVER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
CLIENT_VER="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '?')"
ok "Docker Client：$CLIENT_VER"
ok "Docker Server：$SERVER_VER"

if docker compose version >/dev/null 2>&1; then
  ok "Compose：$(docker compose version --short 2>/dev/null || echo ok)"
else
  warn "docker compose 不可用"
fi

log "拉取 hello-world 做實際測試（首次會下載 image）…"
if timeout 120 docker run --rm hello-world >/dev/null 2>&1; then
  ok "容器執行正常"
else
  warn "hello-world 失敗（可能是網路問題，或需要 sudo）"
fi

# ---------- 摘要 ----------
step "完成"

if [ "$WRITE_DAEMON_JSON" -eq 1 ]; then
  if [ -f /etc/docker/daemon.json ]; then DAEMON_STATUS="已設定"; else DAEMON_STATUS="未設定"; fi
else
  DAEMON_STATUS="跳過（--no-daemon-json）"
fi

cat <<EOF
${C_BOLD}Docker 安裝摘要${C_RESET}
  系統      : $DISTRO_PRETTY ($ARCH)
  版本      : $SERVER_VER
  Repo      : https://$REPO_HOST/linux/$DISTRO_ID $DISTRO_CODENAME stable
  服務      : $(systemctl is-enabled docker) / $(systemctl is-active docker)
  daemon.json: $DAEMON_STATUS

  常用指令：
    docker ps -a
    docker images
    docker compose up -d
    docker system df          # 查看佔用空間
    docker system prune -af   # 清理（小心）
EOF

if [ -n "$TARGET_USER" ] && ! id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
  warn "提醒：請登出再登入，或執行 newgrp docker"
fi

ok "全部完成"

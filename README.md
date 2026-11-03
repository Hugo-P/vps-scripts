# vps-scripts

一鍵安裝腳本合集（Ubuntu / Debian，amd64 / arm64）。

## 腳本

| 腳本 | 用途 |
|---|---|
| `install-docker.sh` | 安裝 Docker CE（官方 APT repo） |
| `install-wg-easy.sh` | 安裝 WireGuard Easy（wg-easy v15） |
| `install-nginx-proxy-manager.sh` | 安裝 Nginx Proxy Manager |

## 快速開始

### 安裝 Docker

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-docker.sh | sudo bash
```

默認會同時寫入 `/etc/docker/daemon.json`（log 輪替 10m × 3 + live-restore）。

常用參數：

```bash
# 用阿里雲鏡像（中國 / 澳門網速慢）
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-docker.sh | sudo bash -s -- --mirror cn

# 不寫 daemon.json
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-docker.sh | sudo bash -s -- --no-daemon-json
```

### 安裝 wg-easy

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-wg-easy.sh | sudo bash
```

三個主要參數全部有智能預設：

| 參數 | 預設行為 |
|---|---|
| `--host` | 自動偵測公網 IP |
| `--password` | 隨機生成 20 位密碼（結尾顯示） |
| `--port` | `51820`（UDP） |

常用參數：

```bash
# 指定域名與密碼
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-wg-easy.sh \
  | sudo bash -s -- --host vpn.example.com --password 'MyStr0ngPass'

# 自訂端口與資料目錄
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-wg-easy.sh \
  | sudo bash -s -- --port 51820 --ui-port 8080 --data-dir /opt/wg-easy

# 已存在容器時重建（資料保留）
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-wg-easy.sh \
  | sudo bash -s -- --force
```

### 安裝 Nginx Proxy Manager

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-nginx-proxy-manager.sh | sudo bash
```

默認端口：HTTP `80`、HTTPS `443`、管理介面 `81`。

首次登入：`admin@example.com` / `changeme`（登入後會強制修改）。

常用參數：

```bash
# 80/443 已被佔用時改用其他端口
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-nginx-proxy-manager.sh \
  | sudo bash -s -- --http-port 8080 --https-port 8443 --admin-port 8181

# 自訂資料目錄
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-nginx-proxy-manager.sh \
  | sudo bash -s -- --data-dir /opt/npm

# 重建（資料保留）
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-nginx-proxy-manager.sh \
  | sudo bash -s -- --force
```

## 注意事項

- **wg-easy 需要先安裝 Docker**。腳本會檢查，沒有會提示。
- **雲端防火牆要自己開**：UDP `51820`（VPN）、TCP `51821`（Web UI）。
- `INIT_*` 環境變數只在**第一次啟動**有效；資料庫建立後請在 Web UI 修改。
- 資料目錄必須持久化，否則刪除容器等於所有 client 消失。

## 安全提醒

`install-wg-easy.sh` 默認使用 `INSECURE=true`（不強制 HTTPS）。建議：

1. 安裝後立即改強密碼
2. 用 Cloudflare Tunnel 或反向代理加上 HTTPS
3. 限制 Web UI port 的來源 IP

## 版本固定

想避免上游 `main` 變動，可改用 commit hash：

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/<COMMIT_HASH>/install-docker.sh | sudo bash
```

## 授權

MIT

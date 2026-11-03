# vps-scripts

一鍵安裝腳本合集（Ubuntu / Debian，amd64 / arm64）。

## 腳本

| 腳本 | 用途 |
|---|---|
| `install-docker.sh` | 安裝 Docker CE（官方 APT repo） |
| `install-wg-easy.sh` | 安裝 WireGuard Easy（wg-easy v15） |
| `install-nginx-proxy-manager.sh` | 安裝 Nginx Proxy Manager |
| `install-keepalive.sh` | Oracle Always Free 保活（降低 idle 回收機率） |

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

### Oracle Always Free 保活

依 [官方 Always Free 文件](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)，Always Free 執行個體若在**連續 7 天**內同時滿足：

- CPU 使用率（95th percentile）**< 20%**
- 網路使用率 **< 20%**
- 記憶體使用率 **< 20%**（僅適用 A1 / Ampere 機型）

就會被判定為 idle，可能被停止（不是刪除，但 A1/ARM 常卡在 `Out of host capacity` 開不回來）。

> 先確認你的機器是不是真的在「Always Free」範圍內：**A1 的免費額度只有 2 OCPU / 12 GB**
> （每月 1,500 OCPU 小時 + 9,000 GB 小時）。超過額度的 A1 屬於付費或 Free Trial 資源，
> 不會走 idle 回收；比較該擔心的是**試用期結束後超額部分會被停用、30 天後刪除**（除非升級付費）。

腳本只有選單、不接受任何參數。一行安裝也能用（沒有終端機時會自動改讀 `/dev/tty`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-keepalive.sh | sudo bash
```

或先下載再執行：

```bash
curl -fsSLO https://raw.githubusercontent.com/Hugo-P/vps-scripts/main/install-keepalive.sh
sudo bash install-keepalive.sh
```

```
Oracle Always Free 保活（固定設定：30 分鐘 / 5 分鐘 / CPU 60% / 記憶體 25%）

  系統       ：4 核 / 23972 MiB
  狀態       ：已安裝
  定時器     ：運行中（下次 2026-11-04 11:57:45）
  記憶體守護 ：6002 MiB（PID 3918）
  最近尖峰   ：成功（11-04 11:29）

  1. 安裝 / 重裝
  2. 查看狀態
  3. 移除
  4. 退出
```

摘要（有沒有在跑、上次跑成功沒）直接畫在選單上方；`2. 查看狀態` 則是細部資訊：
設定內容、三個單元的 active/enabled、最近一次尖峰的 Result / 退出碼 / 結束時間與最後幾行 log、
下次觸發時間、記憶體守護實際持有量。

所有數值都寫死在腳本開頭，選單不會問任何數字；選完一項後按 Enter 會回到選單。

腳本會安裝兩個 systemd 單元：

| 單元 | 作用 |
|---|---|
| `oracle-keepalive.timer` | 每 30 分鐘跑一次 5 分鐘的 CPU 尖峰 + 1 MiB 下載 |
| `oracle-keepalive-mem.service` | 常駐持有總記憶體 **25%**（`OOMScoreAdjust=1000`，資源吃緊時第一個被殺） |

CPU 用「尖峰」是因為指標看 95th percentile，短時間拉高就會過線、平均用量仍然很低；
記憶體沒有寫 percentile，只能持續撐住，所以用常駐服務。

移除在選單的 `3`、詳細狀態在 `2`，不需要另外記參數。
設定檔在 `/etc/oracle-keepalive.conf`，改完重啟單元即可生效。

> **效果邊界**：官方只公布「7 天內三項都低於 20%」，取樣與判定細節沒有公開，
> 這支腳本只能「盡量」把指標壓在門檻以上，不是保證。
> 升級成 **Pay As You Go** 之後資源不再算 `Always Free instance`，實務上就不會被 idle 回收
> （官方未明文保證這一點）。

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

# Proxmox tkcdc Manager

在 Proxmox VE 叢集上自動化批次部署 Ubuntu 24.04 VM 的管理工具。
每台 VM 開機後透過 cloud-init 自動完成完整環境建置：xRDP 遠端桌面、繁體中文輸入、Firefox 瀏覽器、Podman rootless container、k8s 工具鏈（CNI / kubectl / cilium / dive / auger）、taroko 套件、kernel 參數優化、PVE Console 資訊看板。

> **每台 VM 部署時間約 8~15 分鐘**：cloud-init 跑完後會**自動 reboot 一次**讓 kernel 升級生效，第二次 boot 才完成 IBus 設定與 tk8s 安裝（如有啟用）。

---

## 目錄

- [功能特色](#功能特色)
- [專案結構](#專案結構)
- [前置需求](#前置需求)
- [環境設定](#環境設定)
- [快速開始](#快速開始)
- [指令說明](#指令說明)
- [VM 部署邏輯](#vm-部署邏輯)
- [Cloud-Init 初始化流程](#cloud-init-初始化流程)
- [VM 環境說明](#vm-環境說明)
- [PVE Console Dialog](#pve-console-dialog)
- [Kernel 參數優化](#kernel-參數優化)
- [常見問題排查](#常見問題排查)
- [注意事項](#注意事項)

---

## 功能特色

- **批次建立**：依 `env.conf` 設定一鍵建立多台 VM，自動分配 VMID、hostname、IP
- **多節點分散**：以 Round Robin 方式平均分散至叢集各節點
- **增量部署**：`VMID_END` 增加後重跑 `create` 會自動跳過已存在 VM，只建立差集
- **衝突預檢**：建立前自動偵測 IP 是否被佔用（已存在 VMID 視為要 skip 的合法狀態）
- **冪等的 start/stop**：對已是目標狀態的 VM 自動跳過，不誤報失敗
- **批次 Snapshot**：`snapshot` 指令逐台 snapshot 所有 VM（支援自訂名稱或自動 timestamp）
- **APT 鏡像**：使用 NCHC 國網中心鏡像 + IPv4-only + retry 強化，避免 archive.ubuntu.com 不穩定造成安裝失敗
- **全自動初始化**：cloud-init 完成所有軟體安裝、IBus 中文輸入、xRDP、Podman、k8s 工具
- **自動 reboot**：cloud-init 完成後自動重啟，讓 kernel 升級生效，並在乾淨環境執行 tk8s
- **xRDP 遠端桌面**：xfce4 桌面環境 + 效能優化（compositor off、24-bit、4MB TCP buffer）
- **繁體中文輸入**：IBus + chewing 注音輸入法，**右 Shift** 切換中英文
- **PVE Console Dialog**：Serial Console 自動登入 + 全螢幕 dialog 顯示 VM 即時資訊（kiosk 模式）
- **Podman rootless container**：non-root 執行 container，適合在 container 內建置 k8s
- **Container 工具鏈**：kubectl、cilium、CNI plugins、**dive**（image 解構）、**auger**（etcd 除錯）
- **Go 環境**：預裝 `golang-go`，使用者 `go install` 的 binary 自動進 PATH (`~/go/bin`)
- **taroko k8s**：`ENABLE_TK8S=true` 時 reboot 後自動執行 `kto tk8s` 初始化
- **Shell 環境**：登入即具備 kubectl alias、IP/GW 環境變數、PS1 顯示 cluster 等
- **Kernel 參數優化**：xRDP 互動式流量 + container/k8s 工作負載
- **VM 狀態追蹤**：`status` 指令即時顯示每台 VM 的 cloud-init 進度

---

## 專案結構

```
Proxmox_tkcdc_manager/
├── pve_tkcdc_manager.sh     # 主要管理腳本
├── env.conf                 # 環境設定檔（VM 規格、IP、節點、Storage）
├── user-data.tpl            # Cloud-init user-data 模板
├── xrdp-installer-*.sh      # xRDP 安裝腳本（c-nergy，需自行下載）
└── README.md
```

> **xRDP 安裝腳本**：請至 [c-nergy.be](https://c-nergy.be/products.html) 下載對應版本的 `xrdp-installer-*.sh`，放置於專案目錄下。腳本執行時會自動偵測並使用。

---

## 前置需求

### Proxmox VE 環境

- Proxmox VE **7.x** 或 **8.x**
- 腳本須在 **EXECUTE_NODE** 指定的節點上以 **root** 身份執行
- 多節點叢集時，執行節點必須能以 **SSH 金鑰免密碼**登入其他 PVE 節點
  ```bash
  ssh-keygen -t ed25519
  ssh-copy-id root@<其他節點IP>
  ```

### Storage 設定

`local` storage 必須啟用 **Snippets** 內容類型（用於存放 cloud-init YAML）：

1. PVE Web UI → **Datacenter** → **Storage** → 點選 `local` → **Edit**
2. **Content** 欄位勾選 **Snippets**
3. 儲存

### 系統工具

執行節點需具備以下工具（PVE 預設已安裝）：

| 工具 | 用途 |
|------|------|
| `qm` | Proxmox VM 管理 |
| `pvesm` | Proxmox Storage 管理 |
| `python3` | Cloud-init YAML 生成、JSON 解析 |
| `wget` | Ubuntu Cloud Image 下載（支援 `-c` 續傳） |
| `scp` / `ssh` | 多節點檔案傳輸 |

**選配工具**（用於 `status` 指令的 SSH 備援機制）：
```bash
apt-get install -y sshpass
```

---

## 環境設定

編輯 `env.conf` 調整所有部署參數：

```bash
nano env.conf
```

### 節點設定

```bash
NODE_LIST=('pve1' 'pve2' 'pve3')
export EXECUTE_NODE="pve1"
NODE_IP_MAP=(['pve1']='172.20.7.60' ['pve2']='172.20.7.61' ['pve3']='172.20.7.62')
```

### VM 數量與命名

```bash
export VMID_START=900
export VMID_END=904          # 此範例建立 5 台 VM
export VM_NAME_PREFIX="tkcdc"
```

> **增量擴充**：之後把 `VMID_END` 改成 909 再跑一次 `create`，原本的 5 台保留，只新增 5 台（905~909）。

### 網路設定

```bash
export VM_NET_PREFIX="192.168.61"
export VM_IP_START=31
export NETMASK="24"
export GATEWAY="192.168.61.1"
export NAMESERVER="8.8.8.8"
export BRIDGE="vmbr0"
```

### VM 硬體規格

```bash
export CPU_SOCKET="1"
export CPU_CORE="2"
export CPU_TYPE="host"
export MEM="4096"
export DISK="50"
```

### Storage

```bash
export STORAGE="local-lvm"
```

### VM 使用者

```bash
export VM_USER="bigred"
export VM_PASSWORD="bigred"
```

### Taroko k8s 自動啟用

```bash
export ENABLE_TK8S="false"   # 改為 "true" 自動初始化 k8s
```

設為 `true` 後，cloud-init 完成 + reboot 後，systemd 服務會在乾淨環境執行 `kto tk8s`。

> **為何 reboot 後才裝**：cloud-init 階段會升級 kernel，新 kernel 要 reboot 才生效。tk8s 在新 kernel 上跑比較穩定（特別是 br_netfilter / overlay 等模組）。

---

## 快速開始

### 步驟一：確認設定

```bash
cat env.conf
```

### 步驟二：建立 VM

```bash
bash pve_tkcdc_manager.sh create
```

腳本依序執行：

1. **環境檢查**：`qm`、`pvesm`、SSH 至各節點、Storage 存在
2. **衝突預檢**：掃描 VMID（已存在則 skip）+ IP（被別人占用才報錯）
3. **下載 Cloud Image**：Ubuntu 24.04，支援續傳（`wget -c`）
4. **顯示部署計畫**：列出每台 VM 的 STATUS（new / exists）
5. **逐台建立**：建立、匯入磁碟、附加 cloud-init、產生 user-data YAML

### 步驟三：啟動 VM

```bash
bash pve_tkcdc_manager.sh start
```

> 已 running 的會自動跳過。

### 步驟四：追蹤進度

```bash
bash pve_tkcdc_manager.sh status
```

cloud-init 約 **8~15 分鐘**（含自動 reboot 一次）。狀態欄位：

| 狀態 | 顏色 | 說明 |
|------|------|------|
| `Booting...` | — | VM running 但 SSH port 22 未開放 |
| `Waiting...` | — | cloud-init 仍在執行（status: running） |
| `Ready` | 🟢 綠 | cloud-init 完成（status: done） |
| `Error` | 🔴 紅 | cloud-init 報錯（status: error） |
| `No cloud-init` | 🟡 黃 | 連到 VM 但 `cloud-init status` 命令本身失敗 |
| `Agent N/A` | 🟡 黃 | guest agent 跟 SSH 都拿不到回應（VM 還在早期 boot 或網路有問題） |
| `Unknown` | 🟡 黃 | 收到回應但格式不認得 |

### 步驟五：連線 VM

#### A. xRDP（圖形桌面）

- 位址：VM IP（如 `192.168.61.31`）
- 連接埠：`3389`
- 帳號 / 密碼：`env.conf` 中的 `VM_USER` / `VM_PASSWORD`

#### B. PVE Console（Serial）

PVE Web UI → 選擇 VM → **Console**，會看到全螢幕 dialog 顯示 VM 即時資訊（hostname、CPU、記憶體、IP、DNS、Kubernetes 狀態）。

> **PVE Console 是 kiosk 模式**，無法進入 bash shell。需要 shell 請用 SSH 或 xRDP 內的 xfce4-terminal。

#### C. SSH

```bash
ssh bigred@192.168.61.31
```

---

## 指令說明

```bash
bash pve_tkcdc_manager.sh <指令> [參數]
```

| 指令 | 說明 |
|------|------|
| `create` | 下載 Image、建立並設定所有新 VM（已存在會自動 skip） |
| `start` | 啟動所有 VM（已 running 跳過） |
| `stop` | 關閉所有 VM（已 stopped 跳過） |
| `delete` | 停止並永久刪除所有 VM 與磁碟 |
| `status` | 顯示所有 VM 目前狀態與 cloud-init 進度 |
| `snapshot [NAME]` | 逐台 snapshot 所有 VM（沒帶 NAME 時自動產生 timestamp） |
| `select-storage` | 互動式 Storage 選擇器（自動更新 `env.conf`） |

> `delete` 指令需輸入 `yes` 才會執行。

### Snapshot 範例

```bash
# 自動命名（範例：snap-20260507-143025）
bash pve_tkcdc_manager.sh snapshot

# 自訂名稱（用於版本標記）
bash pve_tkcdc_manager.sh snapshot before-upgrade
bash pve_tkcdc_manager.sh snapshot baseline-2026
```

Snapshot 名稱必須符合 PVE 格式：`^[A-Za-z][A-Za-z0-9_-]+$`（字母開頭、長度 ≥ 2、僅含英數/底線/連字號）。逐台處理，會顯示 `[idx/total]` 進度，最後彙整成功/失敗數量。

---

## VM 部署邏輯

### Round Robin 節點分散

VM 依序輪流分配至各節點：

| VM | VMID | Hostname | IP | Node |
|----|------|----------|----|------|
| 1 | 900 | tkcdc-01 | 192.168.61.31 | pve1 |
| 2 | 901 | tkcdc-02 | 192.168.61.32 | pve2 |
| 3 | 902 | tkcdc-03 | 192.168.61.33 | pve3 |
| 4 | 903 | tkcdc-04 | 192.168.61.34 | pve1 |
| 5 | 904 | tkcdc-05 | 192.168.61.35 | pve2 |

### 增量部署機制

`create` 指令會掃描每個 VMID：
- **VMID 已存在於某節點** → 標記為 `exists`，**跳過建立**
- **VMID 不存在 + IP 沒被佔用** → 標記為 `new`，建立
- **VMID 不存在 + IP 已被佔用** → 報錯（IP 衝突），終止

例：`VMID_END` 從 904 改成 909 後重跑：

```
  VMID     HOSTNAME           IP                 NODE           STATUS
  ────────────────────────────────────────────────────────────────────────────
  900      tkcdc-01           192.168.61.31      pve1           exists
  901      tkcdc-02           192.168.61.32      pve2           exists
  ...
  905      tkcdc-06           192.168.61.36      pve3           new
  906      tkcdc-07           192.168.61.37      pve1           new
  ...

[INFO] 5 VM(s) already exist (will skip); creating 5 new VM(s)
```

### 冪等的 start / stop

對 VM 執行 `qm start` 時若已 running 會錯誤；改為先用 `vm_power_state()` helper 抓當前狀態：
- `start`：已 `running` → 跳過（不誤報失敗）
- `stop`：已 `stopped` → 跳過

---

## Cloud-Init 初始化流程

VM 部署分**兩階段**：

```
第一次 boot
  cloud-init 完成所有 setup（write_files / apt / runcmd）
        │
        ▼
  自動 reboot（讓 kernel 升級生效）
        │
        ▼
第二次 boot
  serial-getty 自動登入 → dialog 顯示
  ENABLE_TK8S=true 時自動執行 kto tk8s
```

### 1. APT mirror 與穩定性設定

- `apt:` 配置：使用 **NCHC 國網中心鏡像**（`http://free.nchc.org.tw/ubuntu/`），比 archive.ubuntu.com 穩定
- `/etc/apt/apt.conf.d/99force-ipv4`：
  - `ForceIPv4 "true"` — VM 無 IPv6 路由時避免 timeout 浪費
  - `Retries "10"` — 預設 3 次太少
  - `http::Timeout "120"` — 拉長下載超時

### 2. 系統基礎設定

- hostname、`/etc/hosts`
- 時區 `Asia/Taipei`
- 建立 `VM_USER`（sudo 免密碼）
- SSH 密碼登入啟用（覆寫 `60-cloudimg-settings.conf`）

> **DNS 不寫 `/etc/resolv.conf`**：Ubuntu 24.04 用 systemd-resolved（symlink 到 stub），由 PVE 的 `qm set --nameserver` 透過 netplan 設定，systemd-resolved 自動讀取。

### 3. Kernel 模組與參數

開機載入：`br_netfilter`、`overlay`、`tcp_bbr`
套用 `/etc/sysctl.d/99-tkcdc.conf`（詳見 [Kernel 參數優化](#kernel-參數優化)）

### 4. 套件安裝

| 類別 | 套件 |
|------|------|
| 桌面 | `xfce4`、`xfce4-goodies`、`xfce4-terminal` |
| 中文輸入 | `ibus`、`ibus-chewing`、`fonts-noto-cjk` |
| Container | `podman`、`dbus-user-session`、`slirp4netns`、`uidmap` |
| PVE 整合 | `qemu-guest-agent` |
| 開發工具 | `golang-go`、`jq`、`dialog` |
| 資料庫 client | `mariadb-client-core`（`mysql` / `mariadb` CLI，無 server） |
| 常用 | `curl`、`wget`、`unzip`、`net-tools` |

### 5. xRDP 安裝與設定

- 執行 c-nergy `xrdp-installer-*.sh`
- **安裝後驗證**：若 xrdp.service 不存在，用 `apt-get install -y --fix-missing` 重試 3 次
- 套用效能調校：`crypt_level=low`、`max_bpp=24`、TCP buffer 32KB → 4MB

### 6. IBus + 注音輸入法 + 右 Shift 切換

- 寫入 `~/.xprofile`（最早載入）：
  ```bash
  export GTK_IM_MODULE=ibus
  export QT_IM_MODULE=ibus
  export XMODIFIERS=@im=ibus
  ```
- `im-config -n ibus`
- 設定 IBus：preload `xkb:us::eng`、`chewing`；切換熱鍵 `Shift_R`
- 加 XFCE autostart：首次登入確認 `triggers` hotkey 並 `ibus restart`，執行完自刪

### 7. PVE Console Autologin + Dialog

- `/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf`：agetty 自動登入 `VM_USER`
- `/etc/profile.d/zz-sinfo.sh`：登入後檢查 tty 是 `/dev/ttyS*` 才執行 dialog loop（其他 tty 跳過）

### 8. Firefox（Mozilla PPA deb 版）

Ubuntu 24.04 預設 Firefox 是 Snap 版，**Snap sandbox 在 xRDP session 內無法運作**。改用 Mozilla PPA：
```bash
add-apt-repository -y ppa:mozillateam/ppa || true
apt-get install -y firefox || true
```
`|| true` 避免 PPA 連不到時 cloud-init 整個 Error。

### 9. Podman rootless

- `loginctl enable-linger`
- `/etc/subuid` + `/etc/subgid` 設定 `100000:65536`
- 啟用 user-level `podman.socket`

### 10. K8s 工具鏈 + 開發工具

`/tmp/setup-tools.sh` 安裝：

| 工具 | 安裝位置 | 來源 |
|------|----------|------|
| CNI plugins | `~/cni/` | GitHub API 取最新版 |
| kubectl | `/usr/local/bin/kubectl` | dl.k8s.io stable |
| cilium CLI | `/usr/local/bin/cilium` | GitHub release |
| **dive** | `/usr/bin/dive` | GitHub release deb |
| **auger** | `~/go/bin/auger` | `go install github.com/etcd-io/auger@latest` |
| taroko 套件 | `~/tk/` | `tk2026v1.0.zip` |

腳本結尾驗證每項是否到位，缺漏的會在 cloud-init log 留 WARNING。

### 11. Shell 環境（`/etc/profile.d/tkcdc.sh`）

| 設定 | 內容 |
|------|------|
| 環境變數 | `$IP`、`$GW`、`$GWIF`、`$NETID`（每次登入重新偵測） |
| PATH | `~/tk/bin`、`~/kind/bin`、**`~/go/bin`**（go install 的 binary 自動可用） |
| kubectl alias | `k`、`kg`、`ka`、`kd`、`kc`、`ks` |
| 常用 alias | `docker` → `sudo podman`、`ping -c 4` 預設、`dir`、`poweroff/reboot` 等 |
| kubectl completion | bash tab 補全自動載入 |
| PS1 | 顯示目前 kubeconfig cluster 名稱 |

---

## VM 環境說明

### 桌面

| 項目 | 內容 |
|------|------|
| 桌面 | Xfce4（compositor 關） |
| 遠端桌面 | xRDP port 3389 |
| 輸入法 | IBus + chewing（注音） |
| 中英切換 | **右 Shift** |
| 瀏覽器 | Firefox（Mozilla PPA deb） |
| 字型 | Noto CJK |

### Container

| 項目 | 內容 |
|------|------|
| 執行環境 | Podman rootless |
| Socket | `podman.socket`（user service） |
| UID 對映 | `100000:65536` |
| linger | 啟用（登出後 user service 仍運作） |

### 開發工具

| 工具 | 路徑 | 說明 |
|------|------|------|
| kubectl | `/usr/local/bin/kubectl` | Kubernetes CLI |
| cilium CLI | `/usr/local/bin/cilium` | Cilium 安裝/狀態 |
| CNI plugins | `~/cni/` | bridge、loopback、host-local 等 |
| **dive** | `/usr/bin/dive` | Container image 解構 TUI |
| **auger** | `~/go/bin/auger` | etcd 直接讀寫除錯 |
| Go | `/usr/bin/go` | 1.22.x（Ubuntu 24.04 內建） |
| taroko | `~/tk/` | `kto`、`ksc` 等指令 |

```bash
# 範例
dive nginx:latest          # 互動式查看 nginx image 各層
auger --help               # etcd 除錯（搭配 kubectl get raw 用）
go install github.com/x/y@latest   # binary 自動進 PATH
```

---

## PVE Console Dialog

PVE Web UI 開 VM Console 會看到全螢幕 dialog：

```
┌─ Cloud Native Trainer ────────────────────────────────────────────────┐
│                                                                        │
│  [System]                                                              │
│  Hostname : tkcdc-01                                                   │
│  Memory : 3.8Gi                                                        │
│  CPU : Intel(R) Xeon... (core: 2)                                      │
│  Disk : 49G                                                            │
│  Kubernetes: enabled                                                   │
│                                                                        │
│  [Network]                                                             │
│  IP : 192.168.61.31                                                    │
│  Gateway : 192.168.61.1                                                │
│  DNS : 8.8.8.8                                                         │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 設計

- Serial-getty autologin 為 `VM_USER`，登入後 `/etc/profile.d/zz-sinfo.sh` 自動觸發
- TTY 條件：`/dev/ttyS*` 且非 SSH（避免 xfce4-terminal 跳出）
- 用 `dialog --infobox` + 2 秒 loop 重畫，PVE Console 切換/重連都能持續顯示
- 每次重畫會重新抓資訊，**Kubernetes 狀態會即時更新**（tk8s 裝完後自動顯示）
- 是 **kiosk 模式**，無法進入 bash；要 shell 請用 SSH 或 xRDP

### dialog-ready 機制（已移除）

舊版本曾在 cloud-init 跑完後立即重啟 serial-getty 觸發 dialog，但因為 cloud-init 還會輸出 log 到 console 蓋掉 dialog。改成 `power_state: reboot` 後此問題消失（reboot 後是乾淨環境），dialog-ready service 已不存在。

---

## Kernel 參數優化

設定檔：`/etc/sysctl.d/99-tkcdc.conf`、`/etc/modules-load.d/tkcdc.conf`

### TCP（xRDP 互動式流量）

| 參數 | 值 | 說明 |
|------|-----|------|
| `net.ipv4.tcp_congestion_control` | `bbr` | LAN/VM 環境延遲遠低於 cubic |
| `net.core.default_qdisc` | `fq` | 搭配 BBR 的 per-flow 排程 |
| `net.core.{r,w}mem_max` | `16777216` | TCP 緩衝 208KB → 16MB |
| `net.ipv4.tcp_{r,w}mem` | `4096 131072 16777216` | 三段緩衝 |
| `net.ipv4.tcp_tw_reuse` | `1` | 重用 TIME_WAIT（RDP 短連線多） |
| `net.ipv4.tcp_fin_timeout` | `15` | FIN_WAIT2 60s → 15s |
| `net.core.somaxconn` | `65535` | Accept queue |
| `net.core.netdev_max_backlog` | `5000` | 接收 queue |

### Container / k8s 必要

| 參數 | 值 | 說明 |
|------|-----|------|
| `net.ipv4.ip_forward` | `1` | container netns 間封包轉發（**必要**） |
| `net.bridge.bridge-nf-call-iptables` | `1` | k8s kube-proxy / CNI 必要（搭配 `br_netfilter`） |
| `fs.inotify.max_user_watches` | `524288` | 預設 8192 不夠 |
| `fs.inotify.max_user_instances` | `8192` | inotify instance 上限 |

### 記憶體

| 參數 | 值 | 說明 |
|------|-----|------|
| `vm.swappiness` | `10` | k8s 建議低值 |
| `vm.overcommit_memory` | `1` | container 預約量通常大於使用量 |
| `vm.max_map_count` | `262144` | Elasticsearch 等 operator 需要 |
| `vm.dirty_ratio` / `vm.dirty_background_ratio` | `20` / `5` | 平緩 I/O 突波 |

### 系統限制

| 參數 | 值 | 說明 |
|------|-----|------|
| `fs.file-max` | `1048576` | FD 上限 |
| `kernel.pid_max` | `4194304` | container 工作負載 PID 量大 |
| `kernel.panic` / `kernel.panic_on_oops` | `10` / `1` | panic/oops 後 10s 自動重開 |

---

## 常見問題排查

### Cloud-Init 進度

```bash
# VM 內查即時 log
sudo tail -f /var/log/cloud-init-output.log

# 最終狀態（多行）
cloud-init status --long

# 各階段執行時間
cloud-init analyze show
```

### 自動 reboot 沒發生

檢查 cloud-init final 階段是否有錯：

```bash
sudo grep -A2 "power_state" /var/log/cloud-init.log
sudo grep -i "rebooting\|shutdown" /var/log/cloud-init.log
```

如果 cloud-init 中途錯（例如 runcmd 某步驟 failed），power_state 不會觸發。看 status 是否 `error`。

### 右 Shift 切換不了中英文

```bash
# 確認 IBus 熱鍵設定
gsettings get org.freedesktop.ibus.general.hotkey triggers
# 應顯示：['Shift_R']

# 確認 ~/.xprofile 存在
cat ~/.xprofile
# 應有：
# export GTK_IM_MODULE=ibus
# export QT_IM_MODULE=ibus
# export XMODIFIERS=@im=ibus

# 重啟 IBus
ibus restart
```

> 改完設定要**登出 xRDP 重連**，`~/.xprofile` 在 session 啟動時最早載入，必須重新進 session 才生效。

### PVE Console 沒看到 dialog

```bash
# 確認 zz-sinfo.sh 存在
ls -la /etc/profile.d/zz-sinfo.sh

# 確認 dialog 套件
which dialog

# 確認 autologin override
cat /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf

# 確認 serial-getty 服務正在跑（含 autologin）
systemctl status serial-getty@ttyS0.service
ps aux | grep agetty | grep ttyS0
```

PVE Console 切換離開後再切回來看不到？**重新整理瀏覽器分頁**，xterm.js 連線會重建（dialog 在 2 秒內重畫）。

### xRDP 連線問題

```bash
sudo systemctl status xrdp
sudo journalctl -u xrdp -n 50
ss -tlnp | grep 3389
```

如果 xrdp 沒裝起來（cloud-init 期間 apt 失敗）：

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing xrdp xorgxrdp
sudo systemctl enable --now xrdp
```

### Firefox 無法開啟

cloud-init 期間連不到 Mozilla PPA 是常見的：

```bash
# 確認 apt PPA 設定
ls /etc/apt/sources.list.d/ | grep mozillateam

# 手動補裝
sudo DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:mozillateam/ppa
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y firefox
```

### Podman rootless

```bash
podman info | grep -A5 rootless
grep "$USER" /etc/subuid /etc/subgid
loginctl show-user "$USER" | grep Linger

# 重新初始化（會清除所有 container/image）
podman system reset
```

### qemu-guest-agent

```bash
sudo systemctl status qemu-guest-agent

# 若未啟動
sudo udevadm trigger --subsystem-match=virtio-ports
sudo systemctl start qemu-guest-agent
```

### status 一直 `Agent N/A`

代表 PVE 端兩條探測管道都沒回應：

```bash
# 從 PVE node 分別測試
qm guest exec <VMID> --timeout 10 -- cloud-init status
sshpass -p $VM_PASSWORD ssh -o StrictHostKeyChecking=no $VM_USER@<VM_IP> 'cloud-init status'
qm guest cmd <VMID> ping
```

可能原因：
- VM 還在 cloud-init 早期（agent + ssh 都還沒起）
- qemu-guest-agent 沒裝/沒跑
- SSH 密碼登入沒開
- `sshpass` 沒裝在 PVE node 上

### tk8s 沒裝起來

```bash
# 在 VM 內手動執行
kto tk8s
```

### auger 找不到指令

```bash
which auger
echo $PATH | grep go/bin

# tkcdc.sh 已加 ~/go/bin 到 PATH，但要 logout 再登入才生效
# 暫時手動加：
export PATH=$PATH:~/go/bin
```

### 多節點 SSH 金鑰

```bash
ssh -o BatchMode=yes root@<節點IP> "echo OK"
ssh-copy-id root@<節點IP>
```

---

## 注意事項

- **首次部署完會自動 reboot 一次**：`status` 顯示 Ready 後 30 秒內 VM 會 reboot；連線會中斷，正常現象
- `create` 中途失敗的 VM 不會自動 rollback，需 `delete` 後重試
- **`delete` 永久刪除 VM 磁碟**，操作前確認資料已備份
- `package_upgrade: true` 是 cloud-init 最耗時的步驟（含 kernel 升級）
- `VM_PASSWORD` 以**明文**存放於 cloud-init YAML（`/var/lib/vz/snippets/`），建議部署完修改密碼
- xRDP 設 `crypt_level=low` 適合**內網環境**，外部網路請調高加密等級
- **PVE Console 是 kiosk dialog**：要互動 shell 必須走 SSH 或 xRDP terminal
- 對 cloud-init 重跑：`sudo cloud-init clean --logs && sudo reboot`（會重新執行所有設定）

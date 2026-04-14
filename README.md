# Proxmox tkcdc Manager

在 Proxmox VE 叢集上，自動化批次部署 Ubuntu 24.04 VM 的管理工具。  
每台 VM 開機後透過 cloud-init 自動完成完整環境建置，包含 xRDP 遠端桌面、繁體中文輸入、Firefox 瀏覽器、Podman rootless container 環境，以及針對 xRDP 與 container 工作負載優化的 kernel 參數。

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
- [Kernel 參數優化](#kernel-參數優化)
- [常見問題排查](#常見問題排查)

---

## 功能特色

- **批次建立**：一鍵建立多台 VM，依 `env.conf` 設定自動分配 VMID、hostname、IP
- **多節點分散**：以 Round Robin 方式將 VM 平均分散至叢集各節點
- **衝突預檢**：建立前自動偵測 VMID 與 IP 是否已被佔用
- **全自動初始化**：cloud-init 首次開機完成所有軟體安裝與設定，無需人工介入
- **xRDP 遠端桌面**：整合 xfce4 桌面環境，支援 Windows RDP 客戶端直接連線
- **繁體中文輸入**：自動設定 IBus + 注音輸入法，開機即可在 Firefox 輸入中文
- **Podman rootless container**：不需 root 權限即可執行 container，適合在 container 內建置 k8s 環境
- **效能優化**：xRDP 低延遲調校 + kernel 參數針對 xRDP 與 container 工作負載調整
- **VM 狀態追蹤**：`status` 指令即時顯示每台 VM 的 cloud-init 安裝進度

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
  # 在執行節點上產生金鑰（若尚未建立）
  ssh-keygen -t ed25519
  # 複製公鑰至其他節點
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
| `python3` | Cloud-init YAML 生成 |
| `wget` | Ubuntu Cloud Image 下載 |
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
# PVE 節點名稱清單（須與 PVE 實際 hostname 相符）
NODE_LIST=('pve1' 'pve2' 'pve3')

# 腳本執行所在的本機節點
export EXECUTE_NODE="pve1"

# 各節點的 SSH 連線 IP（Key 必須與 NODE_LIST 相同）
# 留空則直接使用節點名稱（需 DNS 或 /etc/hosts 設定）
NODE_IP_MAP=(['pve1']='172.20.7.60' ['pve2']='172.20.7.61' ['pve3']='172.20.7.62')
```

### VM 數量與命名

```bash
# VMID 範圍（台數 = VMID_END - VMID_START + 1）
export VMID_START=900
export VMID_END=904          # 此範例建立 5 台 VM

# Hostname 前綴（tkcdc → tkcdc-01, tkcdc-02, ...）
export VM_NAME_PREFIX="tkcdc"
```

### 網路設定

```bash
export VM_NET_PREFIX="192.168.61"   # IP 前三碼
export VM_IP_START=31               # 起始末碼，依序遞增
export NETMASK="24"
export GATEWAY="192.168.61.1"
export NAMESERVER="8.8.8.8"
export BRIDGE="vmbr0"               # PVE 虛擬網橋
```

> 上述範例會分配 IP：`192.168.61.31`、`192.168.61.32`、…、`192.168.61.35`

### VM 硬體規格

```bash
export CPU_SOCKET="1"
export CPU_CORE="2"
export CPU_TYPE="host"     # 直接暴露 host CPU 特性，效能最佳
export MEM="4096"          # 記憶體 (MB)
export DISK="50"           # 磁碟大小 (GB)
```

### Storage 設定

```bash
export STORAGE="local-lvm"   # VM 磁碟存放位置
```

> 常見 Storage 類型：`local-lvm`（LVM Thin）、`local`（目錄）、`ceph`、NFS 掛載名稱

### VM 使用者設定

```bash
export VM_USER="bigred"
export VM_PASSWORD="bigred"
```

> 此帳號會在 VM 內建立，具備 sudo 免密碼權限，並作為 xRDP 登入帳號。

---

## 快速開始

### 步驟一：確認設定

```bash
cat env.conf    # 確認節點、IP、VMID 設定無誤
```

### 步驟二：建立所有 VM

```bash
bash pve_tkcdc_manager.sh create
```

腳本依序執行：

1. **環境檢查**：`qm` 指令存在、SSH 連線至各節點、Storage 存在
2. **衝突預檢**：掃描所有 VMID 與 IP 是否已被佔用
3. **下載 Cloud Image**：取得 Ubuntu 24.04 (`noble-server-cloudimg-amd64.img`)，已存在則跳過
4. **顯示部署計畫**：列出所有 VM 的 VMID、hostname、IP、節點，等待確認
5. **逐台建立 VM**：建立、匯入磁碟、掛載 cloud-init、產生 user-data YAML
6. **完成**：提示執行 `start`

### 步驟三：啟動 VM

```bash
bash pve_tkcdc_manager.sh start
```

### 步驟四：追蹤安裝進度

```bash
bash pve_tkcdc_manager.sh status
```

首次開機 cloud-init 需要約 **5～15 分鐘**（視網路速度），狀態欄位會依序顯示：

| 狀態 | 說明 |
|------|------|
| `Booting...` | VM 開機中，SSH 尚未就緒 |
| `Installing packages...` | 正在安裝套件（xfce4、podman 等） |
| `Installing xrdp...` | 套件完成，正在安裝 xRDP |
| `Finalizing setup...` | xRDP 安裝完成，執行最後設定 |
| `Ready` | cloud-init 全部完成，可連線 |
| `Error` | cloud-init 發生錯誤，見 VM 內 log |

### 步驟五：連線遠端桌面

cloud-init 狀態顯示 `Ready` 後，以 RDP 客戶端連線：

- **位址**：VM IP（如 `192.168.61.31`）
- **連接埠**：`3389`（預設）
- **帳號**：`env.conf` 中的 `VM_USER`
- **密碼**：`env.conf` 中的 `VM_PASSWORD`

---

## 指令說明

```bash
bash pve_tkcdc_manager.sh <指令>
```

| 指令 | 說明 |
|------|------|
| `create` | 下載 Image、建立並設定所有 VM |
| `start` | 啟動所有 VM |
| `stop` | 關閉所有 VM |
| `delete` | 停止並永久刪除所有 VM 與磁碟 |
| `status` | 顯示所有 VM 目前狀態與 cloud-init 進度 |
| `select-storage` | 互動式 Storage 選擇器（自動更新 `env.conf`） |

> `delete` 指令需輸入 `yes` 才會執行，會一併清除 VM 磁碟與 cloud-init YAML 檔案。

---

## VM 部署邏輯

### Round Robin 節點分散

VM 依序輪流分配至各節點，確保負載平均。以 3 節點、5 台 VM 為例：

| VM | VMID | Hostname | IP | Node |
|----|------|----------|----|------|
| 1 | 900 | tkcdc-01 | 192.168.61.31 | pve1 |
| 2 | 901 | tkcdc-02 | 192.168.61.32 | pve2 |
| 3 | 902 | tkcdc-03 | 192.168.61.33 | pve3 |
| 4 | 903 | tkcdc-04 | 192.168.61.34 | pve1 |
| 5 | 904 | tkcdc-05 | 192.168.61.35 | pve2 |

### 衝突預檢機制

`create` 執行前會針對每台預計建立的 VM 進行以下檢查：

- **VMID 衝突**：對目標節點執行 `qm status <VMID>`，若已存在則告警
- **IP 衝突**：對目標 IP 執行 `ping`，若有回應則告警

任何衝突都會終止建立流程，並提示調整 `VMID_START` 或 `VM_IP_START`。

---

## Cloud-Init 初始化流程

VM 首次開機後，cloud-init 自動依序執行以下工作：

### 1. 系統基礎設定

- 設定 hostname 與 `/etc/hosts`
- 時區設定為 `Asia/Taipei`
- 建立使用者（`VM_USER`），設定 sudo 免密碼
- 開啟 SSH 密碼登入
- 設定 DNS Nameserver

### 2. Kernel 模組與參數

開機後立即載入：

```
br_netfilter   # k8s bridge iptables 規則必要模組
overlay        # container overlayfs 儲存驅動
tcp_bbr        # BBR 壅塞控制演算法
```

套用 `/etc/sysctl.d/99-tkcdc.conf`（詳見 [Kernel 參數優化](#kernel-參數優化)）

### 3. 關閉防火牆

```bash
systemctl disable --now ufw
```

開發/測試環境不需要防火牆，避免干擾 container 網路。

### 4. 套件安裝

透過 `apt` 安裝以下套件：

| 套件 | 用途 |
|------|------|
| `xfce4` / `xfce4-goodies` / `xfce4-terminal` | 桌面環境 |
| `ibus` / `ibus-chewing` | 中文輸入框架 + 注音輸入法 |
| `fonts-noto-cjk` | 中日韓字型 |
| `podman` | Rootless container 執行環境 |
| `dbus-user-session` / `slirp4netns` / `uidmap` | Podman rootless 相依套件 |
| `qemu-guest-agent` | PVE 虛擬機代理程式 |
| `curl` / `wget` / `unzip` / `net-tools` | 常用工具 |

### 5. xRDP 安裝與設定

- 執行 c-nergy `xrdp-installer-*.sh` 腳本（以使用者身份呼叫 sudo）
- 套用效能調校：
  - `crypt_level=low`：LAN 環境不需要強加密，減少 CPU 負擔
  - `max_bpp=24`：24-bit 色深，畫質與頻寬的平衡點
  - `tcp_send_buffer_bytes=4194304`：TCP 傳送緩衝從 32 KB 提升至 4 MB
  - `tcp_recv_buffer_bytes=4194304`：TCP 接收緩衝從 32 KB 提升至 4 MB

### 6. xfce4 桌面效能設定

停用 xfwm4 Compositor（合成器），這是 xRDP 卡頓的最主要原因：

```xml
<property name="use_compositing" type="bool" value="false"/>
<property name="vblank_mode" type="string" value="off"/>
```

並設定 `DESKTOP_SESSION=xfce` 確保 xRDP 啟動正確的桌面工作階段。

### 7. 繁體中文輸入設定

- 執行 `im-config -n ibus` 建立 `~/.xinputrc`，讓 Xsession.d 的 `70im-config_launch` 在登入時自動初始化 IBus
- 設定 IBus 預載引擎：注音（chewing）+ 英文（xkb:us::eng）

登入 xRDP 後即可使用 **Super** 或 **Ctrl+Space** 切換輸入法，在 Firefox 直接輸入繁體中文。

### 8. Firefox 安裝

Ubuntu 24.04 預設 Firefox 為 Snap 版本，**Snap sandbox 在 xRDP session 內無法正常運作**。  
改由 Mozilla 官方 PPA 安裝 deb 版本：

```bash
add-apt-repository -y ppa:mozillateam/ppa
apt-get install -y firefox
```

並設定 apt preferences 確保後續更新仍使用 PPA 版本，不會被替換回 Snap。

### 9. Podman Rootless Container 設定

- `loginctl enable-linger`：使用者登出後，其 systemd user service 仍持續運行
- 設定 `/etc/subuid` 和 `/etc/subgid`：提供 rootless container 所需的 UID/GID 對映範圍（100000:65536）
- 初始化 Podman storage
- 啟用 `podman.socket`（user service）：供需要 container API 的工具使用

### 10. qemu-guest-agent 啟動

```bash
udevadm trigger --subsystem-match=virtio-ports
```

> qemu-guest-agent 的 udev 事件在開機時就已觸發，但當時套件尚未安裝；安裝完成後需手動重觸發，服務才能正確啟動。

---

## VM 環境說明

### 桌面環境

| 項目 | 內容 |
|------|------|
| 桌面 | Xfce4 |
| 遠端桌面協定 | xRDP（port 3389） |
| 輸入法 | IBus + ibus-chewing（注音） |
| 瀏覽器 | Firefox（Mozilla PPA deb 版） |
| 字型 | Noto CJK（繁體中文顯示） |

### Container 環境

| 項目 | 內容 |
|------|------|
| Container 執行環境 | Podman（rootless 模式） |
| Container socket | `podman.socket`（user service） |
| UID 對映 | `100000:65536`（subuid/subgid） |
| 登出保持 | loginctl linger 啟用 |

Podman rootless container 使用範例：

```bash
# 確認 container 環境
podman info | grep -E "rootless|cgroupVersion"

# 執行測試 container
podman run --rm hello-world

# 以 container 執行 k8s（使用 kind 或 k3s-in-container）
podman run -d --name k3s \
  --privileged \
  -p 6443:6443 \
  rancher/k3s server
```

---

## Kernel 參數優化

設定檔位置：`/etc/sysctl.d/99-tkcdc.conf`  
模組設定位置：`/etc/modules-load.d/tkcdc.conf`

### TCP 效能（針對 xRDP 互動式流量）

| 參數 | 設定值 | 說明 |
|------|--------|------|
| `net.ipv4.tcp_congestion_control` | `bbr` | BBR 演算法在 LAN/VM 環境下延遲遠低於 cubic |
| `net.core.default_qdisc` | `fq` | 搭配 BBR 的 per-flow 排程器 |
| `net.core.rmem_max` | `16777216` | TCP 接收緩衝上限：208 KB → 16 MB |
| `net.core.wmem_max` | `16777216` | TCP 傳送緩衝上限：208 KB → 16 MB |
| `net.ipv4.tcp_rmem` | `4096 131072 16777216` | TCP 接收緩衝三段設定 |
| `net.ipv4.tcp_wmem` | `4096 131072 16777216` | TCP 傳送緩衝三段設定 |
| `net.ipv4.tcp_tw_reuse` | `1` | 重用 TIME_WAIT socket（RDP 會開大量短連線） |
| `net.ipv4.tcp_fin_timeout` | `15` | FIN_WAIT2 逾時從 60 秒縮短至 15 秒 |
| `net.core.somaxconn` | `65535` | 連線 Accept 佇列上限 |
| `net.core.netdev_max_backlog` | `5000` | 網路裝置接收佇列 |

### Container / Kubernetes 必要設定

| 參數 | 設定值 | 說明 |
|------|--------|------|
| `net.ipv4.ip_forward` | `1` | Container 網路命名空間之間的封包轉發（**必要**） |
| `net.ipv6.conf.all.forwarding` | `1` | IPv6 轉發 |
| `net.bridge.bridge-nf-call-iptables` | `1` | k8s kube-proxy / CNI 需要 bridge 流量過 iptables（**必要**，需 `br_netfilter` 模組） |
| `net.bridge.bridge-nf-call-ip6tables` | `1` | 同上（IPv6） |
| `fs.inotify.max_user_watches` | `524288` | Ubuntu 預設 8192，跑幾個 pod 就耗盡 |
| `fs.inotify.max_user_instances` | `8192` | inotify instance 上限 |

### 記憶體

| 參數 | 設定值 | 說明 |
|------|--------|------|
| `vm.swappiness` | `10` | 降低 swap 使用頻率（k8s 建議值；0 最佳，10 在低記憶體時可避免 OOM） |
| `vm.overcommit_memory` | `1` | 允許記憶體 overcommit（container 預約量通常大於實際使用量） |
| `vm.max_map_count` | `262144` | 預設 65536 不足；部分 k8s operator（如 Elasticsearch）有此需求 |
| `vm.dirty_ratio` | `20` | 允許更多 dirty page 後再寫回，避免 container I/O 時的爆發性寫入 |
| `vm.dirty_background_ratio` | `5` | 背景寫回閾值，提早啟動寫回降低突波 |

### 系統限制

| 參數 | 設定值 | 說明 |
|------|--------|------|
| `fs.file-max` | `1048576` | 系統最大開啟檔案數 |
| `kernel.pid_max` | `4194304` | container 工作負載下 PID 需求大，預設 32768 可能不足 |
| `kernel.panic` | `10` | Kernel panic 後 10 秒自動重開機 |
| `kernel.panic_on_oops` | `1` | 遇到 oops 觸發 panic（配合上述自動重開） |

---

## 常見問題排查

### Cloud-Init 安裝進度

```bash
# 在 VM 內查看即時 log
sudo tail -f /var/log/cloud-init-output.log

# 查看 cloud-init 最終狀態
cloud-init status --long

# 查看各階段執行時間
cloud-init analyze show
```

### xRDP 連線問題

```bash
# 確認 xRDP 服務狀態
sudo systemctl status xrdp

# 查看 xRDP log
sudo journalctl -u xrdp -n 50

# 確認 port 3389 正在監聽
ss -tlnp | grep 3389
```

### 繁體中文輸入無法使用

```bash
# 確認 im-config 已設定 ibus
cat ~/.xinputrc
# 應顯示：run_im ibus

# 若 ~/.xinputrc 不存在，手動設定
im-config -n ibus

# 確認 IBus 引擎設定
gsettings get org.freedesktop.ibus.general preload-engines
# 應顯示：['xkb:us::eng', 'chewing']
```

> 設定完成後，需**重新連線** xRDP session（登出再登入）讓設定生效。

### Podman Rootless Container 問題

```bash
# 確認 rootless 環境是否正常
podman info | grep -A5 rootless

# 確認 subuid/subgid 設定
grep "$USER" /etc/subuid /etc/subgid

# 確認 linger 啟用
loginctl show-user "$USER" | grep Linger

# 手動初始化 storage（若遇到 storage 錯誤）
podman system migrate
podman system reset   # 注意：會清除所有 container 與 image
```

### qemu-guest-agent 未啟動

```bash
# 在 VM 內確認服務狀態
sudo systemctl status qemu-guest-agent

# 若未啟動，手動觸發
sudo udevadm trigger --subsystem-match=virtio-ports
sudo systemctl start qemu-guest-agent
```

### status 指令持續顯示 Waiting...

原因通常有兩種：

1. **qemu-guest-agent 未啟動**：參考上方處理方式，或安裝 `sshpass` 讓 status 改用 SSH 備援
2. **cloud-init 仍在執行**：安裝過程中 guest agent 有時無法即時回應，稍待片刻再執行 status

```bash
# 安裝 sshpass 啟用 SSH 備援機制
apt-get install -y sshpass
```

### 多節點 SSH 金鑰問題

```bash
# 測試從執行節點 SSH 至其他節點
ssh -o BatchMode=yes root@<節點IP> "echo OK"

# 若失敗，重新複製金鑰
ssh-copy-id root@<節點IP>
```

---

## 注意事項

- `create` 指令執行時若中途失敗，已建立的 VM 不會自動回滾，需手動執行 `delete` 清除後重試
- `delete` 指令會**永久刪除** VM 磁碟，操作前請確認資料已備份
- `package_upgrade: true` 設定會在首次開機時執行完整系統更新，這是 cloud-init 花費時間最長的步驟之一
- VM 的 `VM_USER` 密碼以明文方式存放於 cloud-init YAML（`/var/lib/vz/snippets/`），建議在 VM 建立完成後修改密碼
- xRDP 設定為 `crypt_level=low` 適合受信任的內部網路環境，若 VM 暴露於外部網路請調整加密等級

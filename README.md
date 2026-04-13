# Proxmox_tkcdc_manager

自動化在 Proxmox VE 叢集上批次部署 Ubuntu 24.04 VM，支援多節點 Round Robin 分散、cloud-init 初始化、xRDP 遠端桌面與 Podman rootless 容器環境。

---

## 專案結構

```
Proxmox_tkcdc_manager/
├── pve_tkcdc_manager.sh   # 主要管理腳本
├── env.conf               # 環境設定檔（VM 規格、IP、節點、Storage）
├── user-data.tpl          # Cloud-init user-data 模板
└── README.md
```

---

## 快速開始

### 1. 下載專案

```bash
git clone https://github.com/yourname/Proxmox_tkcdc_manager.git
cd Proxmox_tkcdc_manager
```

### 2. 編輯設定檔

```bash
nano env.conf
```

**主要設定項目說明：**

| 參數 | 說明 | 範例 |
|---|---|---|
| `NODE_LIST` | PVE 節點 hostname 清單 | `('pve1' 'pve2' 'pve3')` |
| `EXECUTE_NODE` | 執行腳本的本機節點 | `pve1` |
| `VMID_START` / `VMID_END` | VMID 範圍（台數 = END-START+1） | `900` / `904` → 5 台 |
| `VM_NAME_PREFIX` | VM hostname 前綴 | `tkcdc` → tkcdc-01, tkcdc-02... |
| `VM_NET_PREFIX` | IP 前三碼 | `192.168.61` |
| `VM_IP_START` | 起始 IP 末碼 | `31` → .31, .32, .33... |
| `STORAGE` | PVE Storage 名稱 | `local-lvm` |
| `VM_USER` | 預設最高權限使用者 | `bigred` |
| `VM_PASSWORD` | 使用者密碼 | `bigred` |

### 3. 建立所有 VM

```bash
bash pve_tkcdc_manager.sh create
```

腳本執行流程：
1. 環境檢查（SSH 連線、Storage 存在）
2. 下載 Ubuntu 24.04 Cloud Image（已存在則跳過）
3. 顯示 VM 部署計畫並確認
4. 逐台建立 VM（Round Robin 分散節點）
5. 產生 cloud-init user-data 並掛載

### 4. 啟動所有 VM

```bash
bash pve_tkcdc_manager.sh start
```

### 5. 查看狀態

```bash
bash pve_tkcdc_manager.sh status
```

### 6. 停止所有 VM

```bash
bash pve_tkcdc_manager.sh stop
```

### 7. 刪除所有 VM

```bash
bash pve_tkcdc_manager.sh delete
```

> ⚠️ 刪除操作需輸入 `yes` 確認，會清除 VM 磁碟與 cloud-init YAML。

### 8. 切換 Storage（互動式）

```bash
bash pve_tkcdc_manager.sh select-storage
```

列出當前節點所有可用 Storage，輸入名稱後自動更新 `env.conf`。

---

## VM 分散邏輯（Round Robin）

若有 3 台節點，建立 5 台 VM，分配如下：

| VM | VMID | Node |
|---|---|---|
| tkcdc-01 | 900 | pve1 |
| tkcdc-02 | 901 | pve2 |
| tkcdc-03 | 902 | pve3 |
| tkcdc-04 | 903 | pve1 |
| tkcdc-05 | 904 | pve2 |

---

## Cloud-Init 初始化內容

VM 第一次開機時，cloud-init 自動執行：

1. **設定 hostname** 與 hostname/hosts
2. **建立使用者**（預設 `bigred`）並設定 sudo 免密碼
3. **更新套件** 並安裝 xfce4、podman 等
4. **xRDP 安裝**（使用 c-nergy xrdp-installer，選擇 xfce 桌面環境）
   - 設定 `crypt_level=low`、`max_bpp=24` 降低加密負擔
5. **Podman rootless 設定**
   - 啟用 loginctl linger
   - 設定 `/etc/subuid` / `/etc/subgid`
   - 初始化 podman storage
   - 啟用 podman.socket (user service)

> 首次開機初始化約需 **5~10 分鐘**（視網路速度而定）。

---

## 前置需求

- Proxmox VE 7.x / 8.x
- 執行節點需能以 SSH key 無密碼登入其他 PVE 節點
- `local` storage 需啟用 **Snippets** 內容類型
  - PVE Web UI → Datacenter → Storage → local → Edit → 勾選 Snippets

---

## 常見問題

### cloud-init 沒有套用？
```bash
# 在 VM 內檢查
cloud-init status
sudo cloud-init analyze show

# 強制重跑（測試用）
sudo cloud-init clean && sudo reboot
```

### xRDP 無法連線？
```bash
sudo systemctl status xrdp
sudo journalctl -u xrdp -n 50
```

### Podman rootless 測試
```bash
podman run --rm hello-world
podman info | grep -A5 rootless
```

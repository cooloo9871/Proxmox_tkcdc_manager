#!/usr/bin/env bash
# ============================================================
# Proxmox_tkcdc_manager - Main Management Script
# Usage: bash pve_tkcdc_manager.sh <create|start|stop|delete>
#        bash pve_tkcdc_manager.sh select-storage
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/env.conf"
USER_DATA_TPL="${SCRIPT_DIR}/user-data.tpl"
LOG_FILE="/tmp/pve_tkcdc_manager.log"
EXEC_LOG="/tmp/pve_execute_command.log"

# ── Colour helpers ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}=====${NC} $* ${GREEN}=====${NC}" | tee -a "$LOG_FILE"; }
info()   { echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
stage()  { echo -e "\n${BOLD}[Stage: $*]${NC}" | tee -a "$LOG_FILE"; }

# ── Node IP map (populated by load_config via env.conf) ──────
declare -A NODE_IP_MAP

# ── VM location cache: VMID → actual node (filled by load_vm_locations) ─
# 顯式初始化 =()：bash + set -u 對沒 assign 過的 array 取 ${#arr[@]} 會 unbound error
declare -A _VM_NODE_CACHE=()

# ── Existing VM detection (filled by check_conflicts during create) ─
# vmid → node where it already exists; 用來在 incremental create 時跳過
declare -A _VM_EXISTS=()

# ── Resolve node SSH target: IP if in NODE_IP_MAP, else name ─
node_addr() { echo "${NODE_IP_MAP[${1}]:-${1}}"; }

# ── Query PVE cluster for real-time VM→node mapping ─────────
load_vm_locations() {
    local json
    json=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || return 0
    while IFS=$'\t' read -r vmid node; do
        [[ -n "$vmid" && -n "$node" ]] && _VM_NODE_CACHE["$vmid"]="$node"
    done < <(python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    vmid = str(vm.get('vmid',''))
    node = vm.get('node','')
    if vmid and node:
        print(vmid + '\t' + node)
" <<< "$json" 2>/dev/null)
}

# ── Get current power state of a VM on the given node ───────
# 回傳 "running" / "stopped" / "" (查不到)。給 cmd_start/cmd_stop 用來
# 在執行 qm start/stop 前先判斷，避免對已經是目標狀態的 VM 重複操作。
vm_power_state() {
    local vmid="$1"
    local node="$2"
    if [[ "$node" == "$EXECUTE_NODE" ]]; then
        qm status "$vmid" 2>/dev/null | awk '{print $2}'
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
            "root@$(node_addr "$node")" \
            "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null
    fi
}

# ── Find the node currently hosting a VM ─────────────────────
# Uses cluster cache first; falls back to probing each node via SSH.
find_vm_node() {
    local vmid="$1"
    if [[ -v _VM_NODE_CACHE["$vmid"] ]]; then
        echo "${_VM_NODE_CACHE[$vmid]}"
        return 0
    fi
    local n
    for n in "${NODE_LIST[@]}"; do
        if [[ "$n" == "$EXECUTE_NODE" ]]; then
            if qm status "$vmid" &>/dev/null; then echo "$n"; return 0; fi
        else
            if ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
                "root@$(node_addr "$n")" "qm status ${vmid}" &>/dev/null; then
                echo "$n"; return 0
            fi
        fi
    done
    return 1
}

# ── Load configuration ───────────────────────────────────────
load_config() {
    [[ -f "$CONFIG_FILE" ]] || error "Config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Derived values
    VM_COUNT=$(( VMID_END - VMID_START + 1 ))
    if [[ $VM_COUNT -le 0 ]]; then error "VMID_END must be >= VMID_START"; fi

    # bash 陣列無法 export，env.conf 須直接宣告 NODE_LIST=(...) 不加 export
    NODE_COUNT=${#NODE_LIST[@]}
    if [[ $NODE_COUNT -eq 0 ]]; then error "NODE_LIST is empty. In env.conf use: NODE_LIST=('n1' 'n2') without export"; fi
}

# ── Run command on a remote PVE node via SSH ─────────────────
# If target == EXECUTE_NODE (local), run directly.
run_on_node() {
    local node="$1"; shift
    local cmd="$*"
    echo "[$(date '+%H:%M:%S')] [$node] $cmd" >> "$EXEC_LOG"
    if [[ "$node" == "$EXECUTE_NODE" ]]; then
        eval "$cmd" >> "$EXEC_LOG" 2>&1
    else
        ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@$(node_addr "$node")" "$cmd" >> "$EXEC_LOG" 2>&1
    fi
}

# ── Build VM list: each entry = "VMID:HOSTNAME:IP:NODE" ──────
build_vm_list() {
    VM_LIST=()
    local idx=0
    local node_idx suffix node hostname last_octet ip
    for (( id=VMID_START; id<=VMID_END; id++ )); do
        node_idx=$(( idx % NODE_COUNT ))
        node="${NODE_LIST[$node_idx]}"
        suffix=$(printf "%02d" $(( idx + 1 )))
        hostname="${VM_NAME_PREFIX}-${suffix}"
        last_octet=$(( VM_IP_START + idx ))
        ip="${VM_NET_PREFIX}.${last_octet}"
        VM_LIST+=("${id}:${hostname}:${ip}:${node}")
        idx=$(( idx + 1 ))   # 避免 (( idx++ )) 在 idx=0 時因回傳值 0 被 set -e 終止
    done
}

# ── Pretty-print the planned VM list ─────────────────────────
# 用 context 參數明確區分：
#   "create" → 不存在的標 "new"  （cmd_create 會建立）
#   "delete" → 不存在的標 "missing"（cmd_delete 會跳過）
# 已存在的一律顯示 "exists"。NODE 欄位：實際節點與規劃不符顯示 actual(*)。
print_vm_plan() {
    local context="${1:-create}"
    echo -e "\n${BOLD}  VM Deployment Plan (${VM_COUNT} VMs across ${NODE_COUNT} nodes)${NC}"
    echo -e "  ${CYAN}$(printf '%-8s %-18s %-18s %-14s %-10s' VMID HOSTNAME IP NODE STATUS)${NC}"
    echo "  $(printf '%0.s─' {1..76})"
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local display_node="$node"
        local status

        if [[ -v _VM_EXISTS["$vmid"] ]]; then
            # create 流程：check_conflicts 已偵測到此 VM 存在
            local on="${_VM_EXISTS[$vmid]}"
            [[ "$on" != "$node" ]] && display_node="${on}(*)" || display_node="$on"
            status="exists"
        elif [[ -v _VM_NODE_CACHE["$vmid"] ]]; then
            # delete/start/stop 流程：load_vm_locations 找到此 VM
            local cached="${_VM_NODE_CACHE[$vmid]}"
            [[ "$cached" != "$node" ]] && display_node="${cached}(*)" || display_node="$cached"
            status="exists"
        elif [[ "$context" == "delete" ]]; then
            status="missing"
        else
            status="new"
        fi

        echo "  $(printf '%-8s %-18s %-18s %-14s %-10s' "$vmid" "$hostname" "$ip" "$display_node" "$status")"
    done
    echo ""
}

# ── Check environment before create ──────────────────────────
check_env() {
    stage "Check Environment"

    # Check qm command
    command -v qm &>/dev/null || error "'qm' command not found. Run this on a PVE node."

    # Check SSH connectivity to all nodes (skip EXECUTE_NODE)
    for node in "${NODE_LIST[@]}"; do
        if [[ "$node" == "$EXECUTE_NODE" ]]; then continue; fi
        ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            "root@$(node_addr "$node")" "true" 2>/dev/null || \
            warn "SSH to node '${node}' failed. VMs assigned to it may fail."
    done

    # Check snippet dir
    mkdir -p "/var/lib/vz/snippets"

    # Validate storage exists on EXECUTE_NODE
    pvesm status | awk '{print $1}' | grep -qx "$STORAGE" || \
        warn "Storage '${STORAGE}' not found on ${EXECUTE_NODE}. Check env.conf."

    log "Check Environment Success"
}

# ── Pre-flight: detect existing VMs (skip in create) and IP conflicts (real ones only) ──
# 已存在的 VMID 不算錯誤——標記到 _VM_EXISTS 讓 cmd_create 跳過。
# 只有「IP 被用、但對應的 VMID 不是我們已記錄的」才算真衝突。
check_conflicts() {
    stage "Conflict Check (existing VMs & IP)"

    _VM_EXISTS=()
    local conflicts=0

    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"

        # ── 偵測 VMID 是否已存在（任一節點）──
        local found_on=""
        for check_node in "${NODE_LIST[@]}"; do
            if [[ "$check_node" == "$EXECUTE_NODE" ]]; then
                qm status "$vmid" &>/dev/null && { found_on="$check_node"; break; }
            else
                ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
                    "root@$(node_addr "$check_node")" \
                    "qm status ${vmid}" &>/dev/null && { found_on="$check_node"; break; }
            fi
        done

        if [[ -n "$found_on" ]]; then
            # VMID 已存在：標記為 skip，繼續下一個（不檢查 IP，自己 IP 必然有回應）
            _VM_EXISTS["$vmid"]="$found_on"
            continue
        fi

        # ── IP 衝突檢查：只對「不存在的 VM」進行 ──
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            warn "IP ${ip} (${hostname}) is already in use on the network"
            conflicts=$(( conflicts + 1 ))
        fi
    done

    if [[ $conflicts -gt 0 ]]; then
        error "Found ${conflicts} IP conflict(s). Resolve them or adjust VM_IP_START in env.conf."
    fi

    local existing=${#_VM_EXISTS[@]}
    local to_create=$(( VM_COUNT - existing ))
    if [[ $existing -gt 0 ]]; then
        log "Pre-flight OK: ${existing} VM(s) already exist (will skip), ${to_create} new to create"
    else
        log "Pre-flight OK: all ${VM_COUNT} VMIDs and IPs are free"
    fi
}

# ── Download Ubuntu cloud image (once) ───────────────────────
download_image() {
    stage "Download Ubuntu Cloud Image"
    mkdir -p "$IMAGE_DIR"
    local img_path="${IMAGE_DIR}/${IMAGE_NAME}"

    # 用 wget -c 支援續傳：如果上次下載中斷，這次接著傳；
    # 用檔案大小驗證避免損壞 image 被當成完整檔（Ubuntu cloud image 通常 > 500MB）。
    local min_size=$((100 * 1024 * 1024))   # 100 MB sanity check
    if [[ -f "$img_path" ]] && [[ $(stat -c%s "$img_path" 2>/dev/null || echo 0) -ge $min_size ]]; then
        info "Image already exists: $img_path (skipping download)"
    else
        if [[ -f "$img_path" ]]; then
            warn "Existing image looks incomplete (< 100MB), resuming/redownloading..."
        fi
        info "Downloading $IMAGE_URL ..."
        wget -c -q --show-progress "$IMAGE_URL" -O "$img_path" || \
            error "Failed to download image"
        log "Image downloaded: $img_path"
    fi

    # Copy image to remote nodes
    for node in "${NODE_LIST[@]}"; do
        if [[ "$node" == "$EXECUTE_NODE" ]]; then continue; fi
        info "Copying image to node: $node"
        ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
            "root@$(node_addr "$node")" "mkdir -p ${IMAGE_DIR}" 2>/dev/null || \
            { warn "SSH to $node failed, skipping image copy"; continue; }
        scp -q -o StrictHostKeyChecking=no "$img_path" "root@$(node_addr "$node"):${img_path}" || \
            warn "Failed to copy image to $node"
    done
}

# ── Generate cloud-init user-data YAML for one VM ────────────
generate_user_data() {
    local vmid="$1"
    local hostname="$2"
    local yaml_path="/var/lib/vz/snippets/tkcdc-${vmid}-user.yaml"
    local xrdp_scripts=( "${SCRIPT_DIR}"/xrdp-installer-*.sh )
    [[ -f "${xrdp_scripts[0]}" ]] || error "No xrdp-installer-*.sh found in ${SCRIPT_DIR}"
    [[ ${#xrdp_scripts[@]} -gt 1 ]] && warn "Multiple xrdp installers found, using: ${xrdp_scripts[0]}"
    local xrdp_script="${xrdp_scripts[0]}"

    [[ -f "$USER_DATA_TPL" ]] || error "Template not found: $USER_DATA_TPL"

    # Use Python for all substitution + xrdp injection in one pass.
    # Python str.replace() handles any special characters in values (|, /, &, etc.)
    # that would break sed delimiter-based substitution.
    local py_script
    py_script=$(mktemp /tmp/inject_xrdp_XXXXXX.py)
    trap "rm -f '${py_script}'" RETURN
    cat > "$py_script" << 'PYEOF'
import sys, base64

tpl_file, yaml_file, script_file, vm_hostname, vm_user, vm_password, enable_tk8s = sys.argv[1:8]

# Read template and do variable substitution (handles any special chars)
with open(tpl_file, 'r') as f:
    content = f.read()

for key, val in {
    '__VM_HOSTNAME__':  vm_hostname,
    '__VM_USER__':      vm_user,
    '__VM_PASSWORD__':  vm_password,
    '__ENABLE_TK8S__':  enable_tk8s,
}.items():
    content = content.replace(key, val)

# Inject xrdp installer as base64-encoded write_files entry.
# cloud-init will decode and write it to /tmp/xrdp-installer.sh
with open(script_file, 'rb') as f:
    script_b64 = base64.b64encode(f.read()).decode()

entry = (
    "  - path: /tmp/xrdp-installer.sh\n"
    "    permissions: '0755'\n"
    "    owner: root:root\n"
    "    encoding: b64\n"
    "    content: %s\n"
) % script_b64

# Insert the new write_files entry just before the package_update section
marker = '\n# ------------------------------------------------------------\n# Package installation'
pos = content.find(marker)
if pos < 0:
    marker = '\npackage_update:'
    pos = content.find(marker)

if pos >= 0:
    content = content[:pos] + '\n' + entry + content[pos:]

with open(yaml_file, 'w') as f:
    f.write(content)
PYEOF
    python3 "$py_script" "$USER_DATA_TPL" "$yaml_path" "$xrdp_script" \
        "$hostname" "$VM_USER" "$VM_PASSWORD" "${ENABLE_TK8S:-false}"

    echo "$yaml_path"
}

# ── Create a single VM ────────────────────────────────────────
create_vm() {
    local vmid="$1"
    local hostname="$2"
    local ip="$3"
    local node="$4"
    local img_path="${IMAGE_DIR}/${IMAGE_NAME}"

    info "Creating VM ${vmid} (${hostname}) on node [${node}] @ ${VM_NET_PREFIX}.x → ${ip}"

    # 1. Create base VM
    if ! run_on_node "$node" \
        "qm create ${vmid} \
            --name '${hostname}' \
            --memory ${MEM} \
            --sockets ${CPU_SOCKET} \
            --cores ${CPU_CORE} \
            --cpu ${CPU_TYPE} \
            --net0 virtio,bridge=${BRIDGE} \
            --ostype l26 \
            --agent enabled=1"; then
        local _dup=false
        if [[ "$node" == "$EXECUTE_NODE" ]]; then
            qm status "$vmid" &>/dev/null && _dup=true || true
        else
            ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
                "root@$(node_addr "$node")" "qm status ${vmid}" &>/dev/null && _dup=true || true
        fi
        if $_dup; then
            error "VMID ${vmid} already exists on node [${node}]. Delete it first or adjust VMID range in env.conf."
        else
            error "Failed to create VM ${vmid} on node [${node}]. See ${EXEC_LOG} for details."
        fi
    fi

    # 2. Import disk and capture actual volume name (varies by storage type)
    run_on_node "$node" \
        "qm importdisk ${vmid} '${img_path}' ${STORAGE}"

    local disk_volume
    if [[ "$node" == "$EXECUTE_NODE" ]]; then
        disk_volume=$(qm config "${vmid}" | awk -F': ' '/^unused0:/{print $2}')
    else
        disk_volume=$(ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@$(node_addr "$node")" \
            "qm config ${vmid} | awk -F': ' '/^unused0:/{print \$2}'")
    fi
    [[ -n "$disk_volume" ]] || error "Could not determine imported disk volume for VM ${vmid}"

    # 3. Attach disk with virtio-scsi using actual volume name
    run_on_node "$node" \
        "qm set ${vmid} \
            --scsihw virtio-scsi-pci \
            --scsi0 ${disk_volume},discard=on"

    # 4. Resize disk
    run_on_node "$node" \
        "qm resize ${vmid} scsi0 ${DISK}G"

    # 5. Attach cloud-init drive
    run_on_node "$node" \
        "qm set ${vmid} --ide2 ${STORAGE}:cloudinit"

    # 6. Set boot order
    run_on_node "$node" \
        "qm set ${vmid} --boot c --bootdisk scsi0"

    # 7. Set display & serial (for cloud-image compatibility)
    run_on_node "$node" \
        "qm set ${vmid} --serial0 socket --vga serial0"

    # 8. Apply cloud-init network config via PVE built-in
    local ciip="${ip}/${NETMASK}"
    run_on_node "$node" \
        "qm set ${vmid} \
            --ipconfig0 ip=${ciip},gw=${GATEWAY} \
            --nameserver ${NAMESERVER}"

    # 9. Generate and attach custom user-data
    local yaml_path
    yaml_path=$(generate_user_data "$vmid" "$hostname")
    local yaml_name
    yaml_name=$(basename "$yaml_path")

    # Copy yaml to remote node if needed
    if [[ "$node" != "$EXECUTE_NODE" ]]; then
        ssh -n -o StrictHostKeyChecking=no "root@$(node_addr "$node")" "mkdir -p /var/lib/vz/snippets"
        scp -q -o StrictHostKeyChecking=no "$yaml_path" "root@$(node_addr "$node"):/var/lib/vz/snippets/$(basename "$yaml_path")" || \
            warn "Failed to copy user-data to $node"
    fi

    run_on_node "$node" \
        "qm set ${vmid} --cicustom 'user=local:snippets/${yaml_name}'"

    # 10. Regenerate cloud-init image
    run_on_node "$node" "qm cloudinit update ${vmid} || true"

    log "create vm ${vmid} (${hostname}) on ${node} success"
}

# ── CREATE VMs (incremental: skip existing, only create new) ──────────
# 支援增量建立：擴大 VMID_END 後重跑 create，已存在的 VMID 自動跳過，
# 只建立差集中的新 VM。
cmd_create() {
    check_env
    check_conflicts        # 偵測現有 VM 並標記到 _VM_EXISTS（不報錯）

    stage "Create VMs"
    print_vm_plan create

    local existing=${#_VM_EXISTS[@]}
    local to_create=$(( VM_COUNT - existing ))

    if [[ $to_create -le 0 ]]; then
        log "All ${VM_COUNT} VMs in the planned range already exist — nothing to create"
        info "To recreate, delete the relevant VMs first."
        exit 0
    fi

    download_image

    if [[ $existing -gt 0 ]]; then
        info "${existing} VM(s) already exist (will skip); creating ${to_create} new VM(s)"
    fi
    read -r -p "Proceed to create ${to_create} new VM(s)? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }

    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        if [[ -v _VM_EXISTS["$vmid"] ]]; then
            info "Skipping VM ${vmid} (${hostname}) — already exists on [${_VM_EXISTS[$vmid]}]"
            continue
        fi
        create_vm "$vmid" "$hostname" "$ip" "$node"
    done

    log "Created ${to_create} new VM(s); ${existing} existing skipped"
    info "Run: bash pve_tkcdc_manager.sh start"
}

# ── START all VMs ─────────────────────────────────────────────
# 已 running 的跳過，避免 qm start 對已開機 VM 報錯而誤判為失敗。
cmd_start() {
    stage "Start VMs"
    load_vm_locations
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local actual_node
        if ! actual_node=$(find_vm_node "$vmid"); then
            warn "VM ${vmid} (${hostname}) not found on any node, skipping"
            continue
        fi
        [[ "$actual_node" != "$node" ]] && info "VM ${vmid} has migrated: ${node} → ${actual_node}"

        local vm_state
        vm_state=$(vm_power_state "$vmid" "$actual_node")
        if [[ "$vm_state" == "running" ]]; then
            info "VM ${vmid} (${hostname}) is already running on [${actual_node}], skipping"
            continue
        fi

        info "Starting VM ${vmid} (${hostname}) on [${actual_node}]"
        if run_on_node "$actual_node" "qm start ${vmid}"; then
            log "start vm ${vmid} success"
        else
            warn "Failed to start vm ${vmid}"
        fi
    done
}

# ── STOP all VMs ──────────────────────────────────────────────
# 已 stopped 的跳過，理由同 cmd_start。
cmd_stop() {
    stage "Stop VMs"
    load_vm_locations
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local actual_node
        if ! actual_node=$(find_vm_node "$vmid"); then
            warn "VM ${vmid} (${hostname}) not found on any node, skipping"
            continue
        fi
        [[ "$actual_node" != "$node" ]] && info "VM ${vmid} has migrated: ${node} → ${actual_node}"

        local vm_state
        vm_state=$(vm_power_state "$vmid" "$actual_node")
        if [[ "$vm_state" == "stopped" ]]; then
            info "VM ${vmid} (${hostname}) is already stopped on [${actual_node}], skipping"
            continue
        fi

        info "Stopping VM ${vmid} (${hostname}) on [${actual_node}]"
        if run_on_node "$actual_node" "qm stop ${vmid}"; then
            log "stop vm ${vmid} completed"
        else
            warn "Failed to stop vm ${vmid}"
        fi
    done
}

# ── DELETE all VMs ────────────────────────────────────────────
cmd_delete() {
    stage "Delete VMs"

    load_vm_locations
    print_vm_plan delete
    echo -e "${RED}WARNING: This will permanently delete all ${VM_COUNT} VMs and their disks!${NC}"
    read -r -p "Type 'yes' to confirm deletion: " confirm
    [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local actual_node
        if ! actual_node=$(find_vm_node "$vmid"); then
            warn "VM ${vmid} (${hostname}) not found on any node, skipping delete"
            continue
        fi
        [[ "$actual_node" != "$node" ]] &&             info "VM ${vmid} has migrated: ${node} → ${actual_node}"
        info "Deleting VM ${vmid} (${hostname}) on [${actual_node}]"
        run_on_node "$actual_node" "qm stop ${vmid} 2>/dev/null || true"
        if run_on_node "$actual_node" "qm destroy ${vmid} --purge"; then
            log "delete vm ${vmid} completed"
        else
            warn "Failed to delete vm ${vmid}"
        fi

        # Remove cloud-init yaml from the node actually hosting the VM
        local yaml_path="/var/lib/vz/snippets/tkcdc-${vmid}-user.yaml"
        if [[ "$actual_node" == "$EXECUTE_NODE" ]]; then
            [[ -f "$yaml_path" ]] && rm -f "$yaml_path" && info "Removed $yaml_path" || true
        else
            ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes \
                "root@$(node_addr "$actual_node")" "rm -f ${yaml_path} 2>/dev/null || true"
        fi
    done

    log "Delete completed"
    rm -f "$LOG_FILE" "$EXEC_LOG"
}

# ── SELECT STORAGE (interactive helper) ───────────────────────
cmd_select_storage() {
    stage "Select Storage"
    info "Available storages on ${EXECUTE_NODE}:"
    echo ""
    pvesm status
    echo ""
    read -r -p "Enter storage name to use (current: ${STORAGE}): " new_storage
    if [[ -n "$new_storage" ]]; then
        sed -i "s|^export STORAGE=.*|export STORAGE=\"${new_storage}\"|" "$CONFIG_FILE"
        info "Storage updated to '${new_storage}' in env.conf"
    else
        info "No change made."
    fi
}

# ── STATUS: show current VM state and cloud-init progress ───────
cmd_status() {
    # Script run inside each VM via qemu guest agent or SSH.
    # 改用 grep 而非 cut：cloud-init 不同版本輸出格式不一（多行、多空格），
    # 用正則找 "status: <state>" 行更穩。NOCLI 表示 cloud-init 命令本身失敗。
    local _check_script='
out=$(cloud-init status 2>/dev/null)
if [ -z "$out" ]; then
    echo "NOCLI"
elif echo "$out" | grep -qE "^status:[[:space:]]*done"; then
    echo "DONE"
elif echo "$out" | grep -qE "^status:[[:space:]]*error"; then
    echo "ERROR"
else
    echo "RUNNING"
fi'
    local script_b64
    script_b64=$(printf '%s' "$_check_script" | base64 -w0)

    stage "VM Status"
    # NODE 欄寬度 14：容納表頭 "NODE(*=moved)" (13 字元) 不溢位，避免後面欄位錯位
    printf "  ${CYAN}%-8s %-18s %-18s %-14s %-10s %s${NC}\n" \
        "VMID" "HOSTNAME" "IP" "NODE(*=moved)" "VM" "CLOUD-INIT"
    echo "  $(printf '%0.s─' {1..92})"

    load_vm_locations
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local actual_node
        actual_node=$(find_vm_node "$vmid") || actual_node=""
        local display_node="$actual_node"
        [[ -n "$actual_node" && "$actual_node" != "$node" ]] &&             display_node="${actual_node}(*)"

        # ── VM power state ──────────────────────────────────────
        local vm_state
        if [[ -z "$actual_node" ]]; then
            vm_state="not found"
        else
            vm_state=$(vm_power_state "$vmid" "$actual_node")
            [[ -z "$vm_state" ]] && vm_state="unknown"
        fi

        # ── Cloud-init progress (guest agent → SSH fallback) ────
        local ci_label="—"
        if [[ "$vm_state" == "running" ]]; then
            local ga_raw="" ga_out=""

            # Try 1: qm guest exec (requires qemu-guest-agent running inside VM)
            if [[ "$actual_node" == "$EXECUTE_NODE" ]]; then
                ga_raw=$(qm guest exec "$vmid" --timeout 10 -- \
                    bash -c "echo ${script_b64} | base64 -d | bash" 2>/dev/null || true)
            else
                ga_raw=$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 \
                    "root@$(node_addr "$actual_node")" \
                    "qm guest exec ${vmid} --timeout 10 -- bash -c 'echo ${script_b64} | base64 -d | bash'" \
                    2>/dev/null || true)
            fi

            # Parse JSON output from qm guest exec
            ga_out=$(printf '%s' "$ga_raw" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('out-data','').strip())
except:
    pass
" 2>/dev/null || true)

            # Try 2: SSH fallback (sshpass) if guest agent not responding
            if [[ -z "$ga_out" ]] && command -v sshpass &>/dev/null; then
                # Check SSH port first; if closed the VM is still booting
                if ! timeout 3 bash -c "echo >/dev/tcp/${ip}/22" 2>/dev/null; then
                    ci_label="Booting..."
                else
                    ga_out=$(sshpass -p "${VM_PASSWORD}" \
                        ssh -n \
                        -o StrictHostKeyChecking=no \
                        -o ConnectTimeout=5 \
                        -o IdentitiesOnly=yes \
                        -o PubkeyAuthentication=no \
                        -o PreferredAuthentications=password,keyboard-interactive \
                        -o NumberOfPasswordPrompts=1 \
                        "${VM_USER}@${ip}" \
                        "$(printf '%s' "$_check_script")" 2>/dev/null || true)
                fi
            fi

            if [[ -z "$ci_label" || "$ci_label" == "—" ]]; then
                case "$ga_out" in
                    DONE)    ci_label="Ready" ;;
                    ERROR)   ci_label="Error" ;;
                    RUNNING) ci_label="Waiting..." ;;
                    NOCLI)   ci_label="No cloud-init" ;;
                    "")      ci_label="Agent N/A" ;;
                    *)       ci_label="Unknown" ;;
                esac
            fi
        fi

        # ── Colorize ────────────────────────────────────────────
        local color="$NC"
        case "$ci_label" in
            Ready)                                color="$GREEN"  ;;
            Error)                                color="$RED"    ;;
            "Agent N/A"|"No cloud-init"|Unknown)  color="$YELLOW" ;;
        esac

        printf "  %-8s %-18s %-18s %-14s %-10s " \
            "$vmid" "$hostname" "$ip" "$display_node" "$vm_state"
        echo -e "${color}${ci_label}${NC}"
    done
    echo ""
}

# ── Usage ──────────────────────────────────────────────────────
usage() {
    echo -e "
${BOLD}Proxmox tkcdc Manager${NC}

Usage: bash $(basename "$0") <command>

Commands:
  ${GREEN}create${NC}          Download image, create & configure all VMs
  ${GREEN}start${NC}           Start all VMs
  ${GREEN}stop${NC}            Stop all VMs
  ${GREEN}delete${NC}          Stop & permanently delete all VMs
  ${GREEN}status${NC}          Show running status of all VMs
  ${GREEN}select-storage${NC}  Interactive storage selector (updates env.conf)

Edit ${CYAN}env.conf${NC} to change VM count, specs, IPs, nodes, and storage.
"
}

# ── Entrypoint ────────────────────────────────────────────────
main() {
    # Truncate logs only for state-changing commands, not for status/select-storage
    case "${1:-}" in
        create|start|stop|delete) : > "$LOG_FILE"; : > "$EXEC_LOG" ;;
    esac

    load_config
    build_vm_list

    case "${1:-}" in
        create)         cmd_create ;;
        start)          cmd_start ;;
        stop)           cmd_stop ;;
        delete)         cmd_delete ;;
        status)         cmd_status ;;
        select-storage) cmd_select_storage ;;
        *)              usage; exit 1 ;;
    esac
}

main "$@"

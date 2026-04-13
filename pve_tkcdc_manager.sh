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
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@${node}" "$cmd" >> "$EXEC_LOG" 2>&1
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
print_vm_plan() {
    echo -e "\n${BOLD}  VM Deployment Plan (${VM_COUNT} VMs across ${NODE_COUNT} nodes)${NC}"
    echo -e "  ${CYAN}$(printf '%-8s %-18s %-18s %-10s' VMID HOSTNAME IP NODE)${NC}"
    echo "  $(printf '%0.s─' {1..56})"
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        echo "  $(printf '%-8s %-18s %-18s %-10s' "$vmid" "$hostname" "$ip" "$node")"
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
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            "root@${node}" "true" 2>/dev/null || \
            warn "SSH to node '${node}' failed. VMs assigned to it may fail."
    done

    # Check snippet dir
    mkdir -p "$SNIPPET_DIR"

    # Validate storage exists on EXECUTE_NODE
    pvesm status | awk '{print $1}' | grep -qx "$STORAGE" || \
        warn "Storage '${STORAGE}' not found on ${EXECUTE_NODE}. Check env.conf."

    log "Check Environment Success"
}

# ── Download Ubuntu cloud image (once) ───────────────────────
download_image() {
    stage "Download Ubuntu Cloud Image"
    mkdir -p "$IMAGE_DIR"
    local img_path="${IMAGE_DIR}/${IMAGE_NAME}"

    if [[ -f "$img_path" ]]; then
        info "Image already exists: $img_path (skipping download)"
    else
        info "Downloading $IMAGE_URL ..."
        wget -q --show-progress "$IMAGE_URL" -O "$img_path" || \
            error "Failed to download image"
        log "Image downloaded: $img_path"
    fi

    # Copy image to remote nodes
    for node in "${NODE_LIST[@]}"; do
        if [[ "$node" == "$EXECUTE_NODE" ]]; then continue; fi
        info "Copying image to node: $node"
        ssh "root@${node}" "mkdir -p ${IMAGE_DIR}" 2>/dev/null || \
            { warn "SSH to $node failed, skipping image copy"; continue; }
        scp -q "$img_path" "root@${node}:${img_path}" || \
            warn "Failed to copy image to $node"
    done
}

# ── Generate cloud-init user-data YAML for one VM ────────────
generate_user_data() {
    local vmid="$1"
    local hostname="$2"
    local yaml_path="${SNIPPET_DIR}/tkcdc-${vmid}-user.yaml"

    [[ -f "$USER_DATA_TPL" ]] || error "Template not found: $USER_DATA_TPL"

    sed \
        -e "s|__VM_HOSTNAME__|${hostname}|g" \
        -e "s|__VM_USER__|${VM_USER}|g" \
        -e "s|__VM_PASSWORD__|${VM_PASSWORD}|g" \
        -e "s|__NAMESERVER__|${NAMESERVER}|g" \
        -e "s|__XRDP_INSTALLER_URL__|${XRDP_INSTALLER_URL}|g" \
        -e "s|__XRDP_VER__|${XRDP_INSTALLER_VERSION}|g" \
        "$USER_DATA_TPL" > "$yaml_path"

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
    run_on_node "$node" \
        "qm create ${vmid} \
            --name '${hostname}' \
            --memory ${MEM} \
            --sockets ${CPU_SOCKET} \
            --cores ${CPU_CORE} \
            --cpu ${CPU_TYPE} \
            --net0 virtio,bridge=${BRIDGE} \
            --ostype l26 \
            --agent enabled=1"

    # 2. Import disk
    run_on_node "$node" \
        "qm importdisk ${vmid} '${img_path}' ${STORAGE} --format qcow2"

    # 3. Attach disk with virtio-scsi
    run_on_node "$node" \
        "qm set ${vmid} \
            --scsihw virtio-scsi-pci \
            --scsi0 ${STORAGE}:vm-${vmid}-disk-0"

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
        ssh "root@${node}" "mkdir -p ${SNIPPET_DIR}"
        scp -q "$yaml_path" "root@${node}:${yaml_path}" || \
            warn "Failed to copy user-data to $node"
    fi

    run_on_node "$node" \
        "qm set ${vmid} --cicustom 'user=${SNIPPET_STORAGE}:snippets/${yaml_name}'"

    # 10. Apply SSH key if set
    if [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]]; then
        run_on_node "$node" \
            "qm set ${vmid} --sshkeys '${SSH_KEY}'"
    fi

    # 11. Regenerate cloud-init image
    run_on_node "$node" "qm cloudinit update ${vmid}"

    log "create vm ${vmid} (${hostname}) on ${node} success"
}

# ── CREATE all VMs ─────────────────────────────────────────────
cmd_create() {
    check_env
    download_image

    stage "Create VMs"
    print_vm_plan

    read -r -p "Proceed to create ${VM_COUNT} VM(s)? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }

    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        create_vm "$vmid" "$hostname" "$ip" "$node"
    done

    log "All ${VM_COUNT} VMs created successfully"
    info "Run: bash pve_tkcdc_manager.sh start"
}

# ── START all VMs ─────────────────────────────────────────────
cmd_start() {
    stage "Start VMs"
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        info "Starting VM ${vmid} (${hostname}) on ${node}"
        run_on_node "$node" "qm start ${vmid}" && \
            log "start vm ${vmid} success" || \
            warn "Failed to start vm ${vmid}"
    done
}

# ── STOP all VMs ──────────────────────────────────────────────
cmd_stop() {
    stage "Stop VMs"
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        info "Stopping VM ${vmid} (${hostname}) on ${node}"
        run_on_node "$node" "qm stop ${vmid}" && \
            log "stop vm ${vmid} completed" || \
            warn "Failed to stop vm ${vmid}"
    done
}

# ── DELETE all VMs ────────────────────────────────────────────
cmd_delete() {
    stage "Delete VMs"

    print_vm_plan
    echo -e "${RED}WARNING: This will permanently delete all ${VM_COUNT} VMs and their disks!${NC}"
    read -r -p "Type 'yes' to confirm deletion: " confirm
    [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }

    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        info "Deleting VM ${vmid} (${hostname}) on ${node}"
        # Stop first (ignore error if already stopped)
        run_on_node "$node" "qm stop ${vmid} 2>/dev/null || true"
        run_on_node "$node" "qm destroy ${vmid} --purge 2>/dev/null" && \
            log "delete vm ${vmid} completed" || \
            warn "Failed to delete vm ${vmid}"

        # Remove cloud-init yaml
        local yaml_path="${SNIPPET_DIR}/tkcdc-${vmid}-user.yaml"
        if [[ -f "$yaml_path" ]]; then rm -f "$yaml_path"; info "Removed $yaml_path"; fi
        if [[ "$node" != "$EXECUTE_NODE" ]]; then
            ssh "root@${node}" "rm -f ${yaml_path} 2>/dev/null || true"
        fi
    done

    # Clean up logs
    rm -f "$LOG_FILE" "$EXEC_LOG"
    log "Delete completed"
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

# ── STATUS: show current VM state ─────────────────────────────
cmd_status() {
    stage "VM Status"
    echo -e "  ${CYAN}$(printf '%-8s %-18s %-18s %-10s %-10s' VMID HOSTNAME IP NODE STATUS)${NC}"
    echo "  $(printf '%0.s─' {1..66})"
    for entry in "${VM_LIST[@]}"; do
        IFS=':' read -r vmid hostname ip node <<< "$entry"
        local status
        status=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "root@${node}" \
            "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "unknown")
        printf "  %-8s %-18s %-18s %-10s %-10s\n" \
            "$vmid" "$hostname" "$ip" "$node" "$status"
    done
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
    : > "$LOG_FILE"
    : > "$EXEC_LOG"

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

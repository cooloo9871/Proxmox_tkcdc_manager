#cloud-config
# ============================================================
# Proxmox_tkcdc_manager - Cloud-Init User Data Template
# This file is generated per-VM by pve_tkcdc_manager.sh
# Variables __VM_HOSTNAME__, __VM_USER__, __VM_PASSWORD__,
# __ENABLE_TK8S__ are replaced at runtime by generate_user_data().
# The xrdp installer script is injected as a base64-encoded
# write_files entry by generate_user_data() at build time.
# ============================================================

hostname: __VM_HOSTNAME__
manage_etc_hosts: true
timezone: Asia/Taipei

# ------------------------------------------------------------
# Default user setup
# ------------------------------------------------------------
system_info:
  default_user:
    name: __VM_USER__
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: __VM_PASSWORD__
    homedir: /home/__VM_USER__
    shell: /bin/bash

ssh_pwauth: true

# ------------------------------------------------------------
# APT mirror: 改用台灣 NCHC 國網中心鏡像
# 比 archive.ubuntu.com 穩定很多（台灣對外連 Canonical 偶爾超慢甚至斷線，
# 是先前 xrdp 安裝失敗、套件下載 timeout 的主因）。
# 此設定會在 package_update / package_upgrade / packages 之前套用。
# 替代選擇：free.nchc.org.tw、mirror.twds.com.tw、ftp.yzu.edu.tw
# ------------------------------------------------------------
apt:
  primary:
    - arches: [default]
      uri: http://free.nchc.org.tw/ubuntu/
  security:
    - arches: [default]
      uri: http://free.nchc.org.tw/ubuntu/

# ------------------------------------------------------------
# DNS
# ------------------------------------------------------------
write_files:
  # apt 強化下載穩定性：
  # - ForceIPv4：VM 無 IPv6 路由時，避免 apt 浪費時間嘗試 IPv6 address。
  # - Retries：archive.ubuntu.com 偶爾很慢/不穩，預設 3 次容易失敗導致整個 install 中斷。
  # - http::Timeout：拉長單次連線 timeout，避免下載速度慢時被誤判為斷線。
  - path: /etc/apt/apt.conf.d/99force-ipv4
    permissions: '0644'
    owner: root:root
    content: |
      Acquire::ForceIPv4 "true";
      Acquire::Retries "10";
      Acquire::http::Timeout "120";
      Acquire::https::Timeout "120";

  # Kernel modules: br_netfilter (required for k8s bridge iptables rules),
  # overlay (container overlayfs storage), tcp_bbr (BBR congestion control)
  - path: /etc/modules-load.d/tkcdc.conf
    permissions: '0644'
    owner: root:root
    content: |
      br_netfilter
      overlay
      tcp_bbr

  # Kernel parameter tuning for xrdp + Podman/k8s workloads
  - path: /etc/sysctl.d/99-tkcdc.conf
    permissions: '0644'
    owner: root:root
    content: |
      # ── TCP performance (xrdp interactive display traffic) ──────────────
      # BBR greatly reduces latency vs cubic on LAN/VM traffic
      net.ipv4.tcp_congestion_control = bbr
      # fq scheduler pairs with BBR for per-flow pacing
      net.core.default_qdisc = fq
      # Socket buffer 208 KB → 16 MB (smoother RDP repaints)
      net.core.rmem_max = 16777216
      net.core.wmem_max = 16777216
      net.ipv4.tcp_rmem = 4096 131072 16777216
      net.ipv4.tcp_wmem = 4096 131072 16777216
      # Reuse TIME_WAIT sockets — RDP opens many short-lived TCP connections
      net.ipv4.tcp_tw_reuse = 1
      # Shorten FIN_WAIT2 from 60 s to 15 s
      net.ipv4.tcp_fin_timeout = 15
      # Larger accept backlog
      net.core.somaxconn = 65535
      net.core.netdev_max_backlog = 5000

      # ── Container / Kubernetes requirements ─────────────────────────────
      # Packet forwarding between container network namespaces
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1
      # k8s kube-proxy / CNI plugins need bridge traffic to pass through iptables
      # (requires br_netfilter module loaded above)
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1

      # ── inotify limits ───────────────────────────────────────────────────
      # Ubuntu default 8192 watches fills up fast; each pod needs several
      fs.inotify.max_user_watches   = 524288
      fs.inotify.max_user_instances = 8192

      # ── Memory ──────────────────────────────────────────────────────────
      # k8s recommends low swappiness (0 is ideal; 10 avoids OOM on low RAM)
      vm.swappiness = 10
      # Allow memory overcommit — containers reserve more than they use
      vm.overcommit_memory = 1
      # Required by Elasticsearch, some k8s operators (default 65536 too low)
      vm.max_map_count = 262144
      # Write-back tuning: flush dirty pages sooner to avoid burst I/O spikes
      vm.dirty_ratio = 20
      vm.dirty_background_ratio = 5

      # ── File descriptors ─────────────────────────────────────────────────
      fs.file-max = 1048576

      # ── Kernel ──────────────────────────────────────────────────────────
      # Auto-reboot 10 s after kernel panic
      kernel.panic = 10
      kernel.panic_on_oops = 1
      # Allow more PIDs for container workloads
      kernel.pid_max = 4194304

  # /etc/resolv.conf 不在 write_files 寫入：Ubuntu 24.04 是 systemd-resolved
  # 管理的 symlink (→ /run/systemd/resolve/stub-resolv.conf)，蓋成一般檔案會
  # 繞過 systemd-resolved 並破壞 split DNS。DNS 已由 PVE 的 qm set --nameserver
  # 透過 netplan 設定，systemd-resolved 會自動讀取。

  # SSH: 覆寫 Ubuntu Cloud Image 預設的 60-cloudimg-settings.conf
  # 該檔預設 PasswordAuthentication no，必須覆寫否則無法密碼登入
  - path: /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    permissions: '0644'
    owner: root:root
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      UsePAM yes

  # xrdp post-config: performance tuning
  - path: /tmp/fix-xrdp-ini.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      # Low encryption - no need for strong crypto on LAN
      sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini
      # 24-bit colour is a good balance of quality vs bandwidth
      sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
      # Increase TCP send/recv buffers from 32 KB to 4 MB for smoother display
      sed -i 's/^#tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' /etc/xrdp/xrdp.ini
      sed -i 's/^#tcp_recv_buffer_bytes=.*/tcp_recv_buffer_bytes=4194304/' /etc/xrdp/xrdp.ini
      systemctl restart xrdp

  # Firefox: Mozilla PPA apt preferences (avoids snap, ensures deb version)
  # Ubuntu 24.04 ships Firefox as snap by default; snap breaks in xrdp sessions.
  # This pin ensures apt picks the deb from Mozilla PPA instead.
  - path: /etc/apt/preferences.d/mozilla-firefox
    permissions: '0644'
    owner: root:root
    content: |
      Package: firefox*
      Pin: release o=LP-PPA-mozillateam
      Pin-Priority: 501

  # IBus + Chewing (注音) input method setup
  - path: /tmp/setup-ibus.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      USERNAME="__VM_USER__"
      # ~/.xprofile 必須在 runcmd 建立：write_files 執行時 user 還不存在，
      # chown 會失敗並讓整個 write_files 模組報錯。
      # xrdp session 啟動時最早載入 ~/.xprofile，確保 IBus env var 在所有
      # 應用程式啟動前生效，是 Shift_R 切換能運作的關鍵前提。
      cat > "/home/${USERNAME}/.xprofile" << 'XPEOF'
      export GTK_IM_MODULE=ibus
      export QT_IM_MODULE=ibus
      export XMODIFIERS=@im=ibus
      XPEOF
      chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.xprofile"
      # Configure im-config to use IBus — creates ~/.xinputrc with "run_im ibus".
      # 70im-config_launch reads ~/.xinputrc and wraps STARTUP with im-launch,
      # which sets GTK_IM_MODULE / XMODIFIERS / QT_IM_MODULE before xfce4 starts.
      su - "$USERNAME" -c "im-config -n ibus"
      # Pre-configure IBus to load chewing (注音) engine at login.
      # Write the gsettings commands to a temp file to avoid multi-layer quoting issues.
      cat > /tmp/ibus-cfg.sh << 'CFGEOF'
      #!/bin/bash
      gsettings set org.freedesktop.ibus.general preload-engines "['xkb:us::eng', 'chewing']"
      gsettings set org.freedesktop.ibus.general engines-order "['xkb:us::eng', 'chewing']"
      gsettings set org.freedesktop.ibus.general.hotkey triggers "['Shift_R']"
      CFGEOF
      chmod 755 /tmp/ibus-cfg.sh
      # dbus-run-session provides a session bus without needing a display
      su - "$USERNAME" -c "dbus-run-session -- bash /tmp/ibus-cfg.sh" || true
      rm -f /tmp/ibus-cfg.sh
      # XFCE autostart (one-shot): 首次登入時確保 IBus Shift_R hotkey 已寫入 dconf
      # 並重啟 IBus，讓設定立即生效。執行完後自刪，之後登入不再執行。
      HOME_DIR="/home/${USERNAME}"
      AUTOSTART_DIR="${HOME_DIR}/.config/autostart"
      SETUP_SCRIPT="${HOME_DIR}/.ibus-shift-setup.sh"
      mkdir -p "$AUTOSTART_DIR"
      cat > "$SETUP_SCRIPT" << 'SHEOF'
      #!/bin/bash
      sleep 5
      gsettings set org.freedesktop.ibus.general.hotkey triggers "['Shift_R']"
      ibus restart
      rm -f "$HOME/.ibus-shift-setup.sh" "$HOME/.config/autostart/ibus-shift-setup.desktop"
      SHEOF
      chmod 755 "$SETUP_SCRIPT"
      chown "${USERNAME}:${USERNAME}" "$SETUP_SCRIPT"
      cat > "${AUTOSTART_DIR}/ibus-shift-setup.desktop" << DESKTOPEOF
      [Desktop Entry]
      Type=Application
      Name=IBus Shift_R Hotkey Setup
      Exec=${SETUP_SCRIPT}
      Hidden=false
      NoDisplay=false
      X-GNOME-Autostart-enabled=true
      DESKTOPEOF
      # 整個 .config 樹 chown 給 user：mkdir -p 以 root 身份建立的子目錄會繼承 root owner，
      # 跟 setup-xfce4-perf.sh 已 chown 過的 .config 不一致。一次性把整棵樹歸還給 user。
      chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/.config"

  # Xfce4 performance: disable compositor (biggest xrdp lag source)
  - path: /tmp/setup-xfce4-perf.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      USERNAME="__VM_USER__"
      XFCE_DIR="/home/${USERNAME}/.config/xfce4/xfconf/xfce-perchannel-xml"
      mkdir -p "${XFCE_DIR}"
      # Write xfwm4 config: disable compositor and vblank
      # Compositor causes full-screen repaints on every window event - very slow over RDP
      printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<channel name="xfwm4" version="1.0">' \
        '  <property name="general" type="empty">' \
        '    <property name="use_compositing" type="bool" value="false"/>' \
        '    <property name="vblank_mode" type="string" value="off"/>' \
        '  </property>' \
        '</channel>' > "${XFCE_DIR}/xfwm4.xml"
      chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

  # k8s toolchain + taroko package installer
  - path: /tmp/setup-tools.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      USERNAME="__VM_USER__"
      HOME_DIR="/home/${USERNAME}"

      # ── CNI plugins ─────────────────────────────────────────────
      echo "[setup-tools] Installing CNI plugins..."
      rm -rf "${HOME_DIR}/cni"
      mkdir -p "${HOME_DIR}/cni"
      CNI_URL=$(curl -sL https://api.github.com/repos/containernetworking/plugins/releases/latest | \
          jq -r '.assets[].browser_download_url' | grep 'linux-amd64.*.tgz$')
      curl -sL "$CNI_URL" -o /tmp/cni-plugins.tgz
      tar xf /tmp/cni-plugins.tgz -C "${HOME_DIR}/cni"
      rm -f /tmp/cni-plugins.tgz
      chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/cni"

      # ── kubectl ──────────────────────────────────────────────────
      echo "[setup-tools] Installing kubectl..."
      K8S_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
      curl -sL "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl" -o /tmp/kubectl
      chmod +x /tmp/kubectl
      mv /tmp/kubectl /usr/local/bin/kubectl

      # ── cilium CLI ───────────────────────────────────────────────
      echo "[setup-tools] Installing cilium CLI..."
      curl -sL https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz \
          -o /tmp/cilium.tar.gz
      tar xzf /tmp/cilium.tar.gz -C /usr/local/bin cilium
      rm -f /tmp/cilium.tar.gz

      # ── dive (container image explorer) ─────────────────────────
      echo "[setup-tools] Installing dive..."
      DIVE_VERSION=$(curl -sL "https://api.github.com/repos/wagoodman/dive/releases/latest" \
          | grep '"tag_name":' \
          | sed -E 's/.*"v([^"]+)".*/\1/')
      if [ -n "$DIVE_VERSION" ]; then
          curl -fsL "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_amd64.deb" \
              -o /tmp/dive.deb \
              && DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/dive.deb
          rm -f /tmp/dive.deb
      else
          echo "[setup-tools] WARNING: failed to fetch dive version, skipping"
      fi

      # ── auger (etcd debug tool, Go-based) ───────────────────────
      # 要用 su - 跑：go install 會放到 $HOME/go/bin（這裡是 /home/${USERNAME}/go/bin）。
      # PATH 已在 tkcdc.sh 加入 $HOME/go/bin，使用者登入後直接 auger 就能用。
      echo "[setup-tools] Installing auger..."
      su - "$USERNAME" -c 'go install github.com/etcd-io/auger@latest' \
          && echo "[setup-tools] auger installed." \
          || echo "[setup-tools] auger install failed."

      # ── taroko package ───────────────────────────────────────────
      echo "[setup-tools] Downloading taroko package..."
      rm -rf "${HOME_DIR}/tk"
      curl -sL http://www.oc99.org/zip/tk2026v1.0.zip -o /tmp/tk2026v1.0.zip
      unzip -q /tmp/tk2026v1.0.zip -d "${HOME_DIR}"
      rm -f /tmp/tk2026v1.0.zip
      chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/tk"

      # ── .kube config ─────────────────────────────────────────────
      mkdir -p "${HOME_DIR}/.kube"
      touch "${HOME_DIR}/.kube/config"
      chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/.kube"

      # ── taroko k8s auto-setup ────────────────────────────────────
      # tk8s 不在 cloud-init 跑：cloud-init 升級了 kernel，要 reboot 後新 kernel
      # 才生效。tk8s 由 tk8s-post-boot.service 在 reboot 後乾淨環境裝（更穩定）。

      # 結尾驗證（沒 set -e 是故意的：希望單一下載失敗不要整個中斷，
      # 但要在 cloud-init log 留警告，事後可從 log 查哪些缺掉再手動補）
      echo "[setup-tools] Validating installations..."
      [ -x /usr/local/bin/kubectl ]      || echo "[setup-tools] WARNING: kubectl missing"
      [ -x /usr/local/bin/cilium ]       || echo "[setup-tools] WARNING: cilium missing"
      command -v dive &>/dev/null        || echo "[setup-tools] WARNING: dive missing"
      [ -x "${HOME_DIR}/go/bin/auger" ]  || echo "[setup-tools] WARNING: auger missing"
      [ -d "${HOME_DIR}/cni" ] && [ -n "$(ls -A ${HOME_DIR}/cni 2>/dev/null)" ] \
          || echo "[setup-tools] WARNING: CNI plugins missing"
      [ -d "${HOME_DIR}/tk" ] || echo "[setup-tools] WARNING: taroko package missing"
      echo "[setup-tools] Done."

  # /etc/profile.d/tkcdc.sh — shell environment for all login sessions
  - path: /etc/profile.d/tkcdc.sh
    permissions: '0644'
    owner: root:root
    content: |
      gw=$(route -n | grep -e "^0.0.0.0 ")
      export GWIF=${gw##* }
      ips=$(ifconfig $GWIF | grep 'inet ')
      export IP=$(echo $ips | cut -d' ' -f2 | cut -d':' -f2)
      export NETID=${IP%.*}
      export GW=$(route -n | grep -e '^0.0.0.0' | tr -s \ - | cut -d ' ' -f2)
      # Only prepend custom paths not already in PATH.
      # $HOME/bin is intentionally excluded — ~/.profile already adds it unconditionally，
      # so including it here would cause duplication in xRDP sessions.
      # $HOME/go/bin: go install 安裝的 binary（如 auger）會放這裡。
      case ":$PATH:" in
        *":$HOME/tk/bin:"*) ;;
        *) export PATH="$HOME/tk/bin:$HOME/kind/bin:$HOME/go/bin:$PATH" ;;
      esac

      if [ ! -d $HOME/.kube ]; then
         mkdir $HOME/.kube
         touch $HOME/.kube/config
      fi

      export PROXY=""
      if [ "$PROXY" != "" ]; then
         export http_proxy="http://$PROXY:3128"
         export https_proxy="http://$PROXY:3128"
         export no_proxy="localhost,127.0.0.1,10.0.0.0/8"

         echo 'Acquire::http::Proxy "http://$PROXY:3128";' | sudo tee /etc/apt/apt.conf
         echo 'Acquire::https::Proxy "http://$PROXY:3128";' | sudo tee -a /etc/apt/apt.conf
      fi

      if [ -z "$_TKCDC_SOURCED" ]; then
        export _TKCDC_SOURCED=1
        echo "Welcome to Ubuntu 24.04 : $IP"
        echo ""
      fi

      export NOW="--force --grace-period 0"
      export KUBE_EDITOR="nano"
      export TZ=Asia/Taipei
      export PS1='[$(grep "  cluster" ~/.kube/config|cut -d ":" -f 2 |tr -d " ")]\u@\h:\w$ '
      alias ksc='source tk/bin/ksc'
      alias ping='ping -c 4 '
      alias pingdup='sudo arping -D -I eth0 -c 2 '
      alias dir='ls -alh '
      alias poweroff='sudo poweroff; sleep 5'
      alias reboot='sudo reboot; sleep 5'
      alias kg='kubectl get'
      alias k='kubectl'
      alias ka='kubectl apply'
      alias kd='kubectl delete'
      alias kc='kubectl create'
      alias ks='kubectl get pods -n kube-system'
      alias docker='sudo podman'
      alias pc='sudo podman system prune -a -f; sudo podman volume rm -a -f'
      alias vms='sudo /usr/bin/vmware-toolbox-cmd disk shrink /'
      [ -r /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion
      command -v kubectl &>/dev/null && source <(kubectl completion bash) || true

  # /etc/profile.d/zz-sinfo.sh — 在 PVE Console (serial /dev/ttyS*) 登入時用 dialog
  # 顯示 VM 資訊（Hostname / Memory / CPU / Disk / IP / Gateway / DNS）。
  # zz- 前綴確保在 tkcdc.sh 之後執行（PATH 等已就緒）。
  # 條件：tty 是 /dev/ttyS* 且非 SSH session，避免在 xfce4-terminal / SSH 也跳出 dialog。
  - path: /etc/profile.d/zz-sinfo.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      if [[ "$(tty 2>/dev/null)" == /dev/ttyS* ]] && [ -z "$SSH_TTY" ]; then
          # cloud-init boot 期間大量 log 輸出到 ttyS0，會把終端狀態搞亂導致
          # dialog (ncurses) 無法正確 render。先 reset 清掉 cloud-init 殘留再畫 dialog。
          reset

          # /tmp/sinfo 生成函數：每次 loop 重新呼叫，反映最新狀態
          # （特別是 Kubernetes：tk8s-post-boot.service 後完成，要重抓才會顯示）
          gen_sinfo() {
              local gw ips IP GW m cname cnumber ds NS f
              gw=$(route -n | grep -e "^0.0.0.0 ")
              local GWIF=${gw##* }
              ips=$(ifconfig $GWIF | grep 'inet ')
              IP=$(echo $ips | cut -d' ' -f2 | cut -d':' -f2)
              GW=$(route -n | grep -e '^0.0.0.0' | tr -s \ - | cut -d ' ' -f2)

              {
                  echo "[System]"
                  echo "Hostname : $(hostname)"
                  m=$(free -mh | grep Mem: | tr -s ' ' | cut -d' ' -f2)
                  echo "Memory : ${m}"
                  # xargs 去掉 cut 後 leading space（/proc/cpuinfo 用 ": " 分隔）
                  cname=$(grep 'model name' /proc/cpuinfo | head -n 1 | cut -d ':' -f2 | xargs)
                  cnumber=$(grep -c 'model name' /proc/cpuinfo)
                  echo "CPU : $cname (core: $cnumber)"
                  # 用 root filesystem 不 hardcode /dev/sda：相容 virtio-blk、NVMe、LVM
                  ds=$(df -h / | awk 'NR==2 {print $2}')
                  echo "Disk : $ds"
                  # timeout 2 防止 kubectl 在 API server 還沒起來時卡住整個 dialog
                  if timeout 2 kubectl get no &>/dev/null; then
                      echo "Kubernetes: enabled"
                  fi
                  echo ""
                  echo "[Network]"
                  echo "IP : $IP"
                  echo "Gateway : $GW"
                  # nameserver 從 netplan 抓，fallback resolvectl（/etc/resolv.conf 是 stub）
                  NS=""
                  for f in /etc/netplan/*.yaml; do
                      [ -f "$f" ] || continue
                      NS=$(grep -A5 'nameservers:' "$f" 2>/dev/null \
                           | grep -E '^[[:space:]]+-[[:space:]]+[0-9]' | head -1 | awk '{print $2}')
                      [ -n "$NS" ] && break
                  done
                  [ -z "$NS" ] && NS=$(resolvectl dns 2>/dev/null \
                                       | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                  echo "DNS : $NS"
              } > /tmp/sinfo
          }

          # 明確算出置中座標（dialog 在 PVE xterm.js 下預設置中有時失準）
          DH=20; DW=78
          read TR TC < <(stty size 2>/dev/null || echo "25 80")
          BY=$(( (TR - DH) / 2 )); [ "$BY" -lt 0 ] && BY=0
          BX=$(( (TC - DW) / 2 )); [ "$BX" -lt 0 ] && BX=0

          # 每次 iteration 重新生成 /tmp/sinfo + 重畫 dialog：
          # - tk8s-post-boot.service 完成後 Kubernetes 狀態會自動反映
          # - PVE Console 切換/重連時 xterm.js 會重建終端緩衝，新的 dialog process
          #   ncurses initscr 重新做完整繪製，最多 2 秒重新出現
          # 注意：此模式下 PVE Console 變 kiosk，無法進 bash；要 shell 請用 SSH 或 xRDP。
          while true; do
              gen_sinfo
              dialog --begin $BY $BX --title " Cloud Native Trainer " --infobox "$(cat /tmp/sinfo)" $DH $DW
              sleep 2
          done
      fi

  # serial-getty 自動登入：PVE Console (Serial terminal 0) 開啟後直接登入 __VM_USER__，
  # 不用手動輸入帳密，登入後 zz-sinfo.sh 自動跑 dialog 顯示 VM 資訊。
  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin __VM_USER__ --keep-baud 115200,38400,9600 %I $TERM

  # tk8s post-boot installer: cloud-init 結束後 reboot，第二次 boot 時跑這個。
  # ENABLE_TK8S 在 generate_user_data() 時被 substitute 進腳本，重啟後一樣有效。
  - path: /usr/local/bin/tk8s-install.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      ENABLE_TK8S="__ENABLE_TK8S__"
      USERNAME="__VM_USER__"
      if [ "$ENABLE_TK8S" != "true" ]; then
          echo "[tk8s-install] ENABLE_TK8S=$ENABLE_TK8S, skip."
          exit 0
      fi
      echo "[tk8s-install] Running kto tk8s as $USERNAME..."
      # su - 已是 login shell，會 source /etc/profile + ~/.profile（PATH 含 ~/tk/bin），
      # 不需要再套一層 bash --login -c。
      su - "$USERNAME" -c 'kto tk8s' \
          && echo "[tk8s-install] kto tk8s completed." \
          || echo "[tk8s-install] kto tk8s failed — check ~/tk logs."

  # tk8s-post-boot.service: 第二次 boot（cloud-init reboot 後）才執行 tk8s 安裝。
  # ConditionPathExists 確保只跑一次；After=network-online 保證 kto tk8s 拉 image 時網路 OK。
  - path: /etc/systemd/system/tk8s-post-boot.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Install taroko k8s after first reboot
      # 只 After network-online；不 After multi-user.target（會跟 WantedBy 衝突）。
      # WantedBy=multi-user.target 已隱含這 service 是 multi-user 啟動流程的一部分。
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/var/lib/.tk8s-installed

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      TimeoutStartSec=0
      ExecStart=/usr/local/bin/tk8s-install.sh
      ExecStartPost=/bin/touch /var/lib/.tk8s-installed
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target

  # Podman rootless setup script (runs as VM_USER)
  - path: /tmp/setup-podman-rootless.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      USERNAME="__VM_USER__"
      # Enable lingering so user services survive logout
      loginctl enable-linger "$USERNAME"
      # Ensure subuid/subgid entries exist
      grep -q "^${USERNAME}:" /etc/subuid || \
        echo "${USERNAME}:100000:65536" >> /etc/subuid
      grep -q "^${USERNAME}:" /etc/subgid || \
        echo "${USERNAME}:100000:65536" >> /etc/subgid
      # Initialize podman storage for the user
      su - "$USERNAME" -c "podman system migrate || true"
      su - "$USERNAME" -c "podman info > /dev/null 2>&1 || true"
      # Enable podman socket for the user
      su - "$USERNAME" -c "systemctl --user enable --now podman.socket || true"

# ------------------------------------------------------------
# Package installation
# ------------------------------------------------------------
package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - unzip
  - net-tools
  - podman
  - dbus-user-session
  - slirp4netns
  - uidmap
  - qemu-guest-agent
  - xfce4
  - xfce4-goodies
  - xfce4-terminal
  - ibus
  - ibus-chewing
  - fonts-noto-cjk
  - jq
  - dialog
  - golang-go
  - mariadb-client-core

# ------------------------------------------------------------
# Run commands at first boot
# Order: install xrdp → configure → setup podman rootless
# ------------------------------------------------------------
runcmd:
  # ── 載入 kernel modules（br_netfilter / overlay / tcp_bbr）──────────
  - modprobe br_netfilter
  - modprobe overlay
  - modprobe tcp_bbr
  # ── 套用 sysctl 設定 ─────────────────────────────────────────────────
  - sysctl --system
  # ── 永久關閉 UFW 防火牆 ──────────────────────────────────
  - systemctl disable --now ufw
  # ── SSH 重啟套用密碼登入設定 ────────────────────────────
  - systemctl restart ssh
  # ── 載入 systemd 新單元（autologin override + tk8s-post-boot service）──
  # serial-getty 不在 cloud-init 內 restart：等下面 power_state 觸發 reboot 後，
  # 重新 boot 時 serial-getty 會自動帶 autologin override 起來，dialog 在乾淨環境出現。
  # tk8s-post-boot.service 第二次 boot 才執行（kto tk8s 在 reboot 後跑更穩定）。
  - systemctl daemon-reload
  # 只在 ENABLE_TK8S=true 時 enable：避免 false 情況下每次 boot 都啟動 service 跑空腳本
  - |
    if [ "__ENABLE_TK8S__" = "true" ]; then
        systemctl enable tk8s-post-boot.service
        echo "[runcmd] tk8s-post-boot.service enabled (will run on reboot)"
    else
        echo "[runcmd] ENABLE_TK8S=false, skip tk8s-post-boot.service"
    fi
  # ── xrdp via local installer (injected by generate_user_data) ──
  # Script must run as a normal user (it calls sudo internally)
  - su - __VM_USER__ -c "bash /tmp/xrdp-installer.sh"
  # Verify xrdp actually installed (xrdp-installer 不檢查 apt 失敗，會誤報成功)。
  # 如果 xrdp.service 不存在就用 --fix-missing 補裝，必要時重試多次。
  - |
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^xrdp\.service'; then
      echo "[xrdp-fix] xrdp install failed during xrdp-installer, retrying..."
      for i in 1 2 3; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing xrdp xorgxrdp && break
        echo "[xrdp-fix] attempt $i failed, sleeping 10s..."
        sleep 10
      done
      systemctl enable --now xrdp || true
    fi
  # Set xfce4 as xrdp desktop session via ~/.profile so startwm.sh's pre_start()
  # picks it up and calls get_xdg_session_startupcmd before Xsession.d runs.
  # This lets 70im-config_launch properly wrap STARTUP with im-launch (IBus init).
  - echo 'export DESKTOP_SESSION=xfce' >> /home/__VM_USER__/.profile
  # Remove .xsessionrc so it doesn't block the Xsession.d pipeline at step 40
  - rm -f /home/__VM_USER__/.xsessionrc
  # xfce4-terminal opens a non-login shell (reads ~/.bashrc, not /etc/profile.d/).
  # Source tkcdc.sh from ~/.bashrc so env/aliases are available in every terminal.
  - echo '[ -f /etc/profile.d/tkcdc.sh ] && source /etc/profile.d/tkcdc.sh' >> /home/__VM_USER__/.bashrc
  # Apply xrdp performance config (low-crypto, TCP buffers)
  - bash /tmp/fix-xrdp-ini.sh
  # Disable Xfce4 compositor before first login
  - bash /tmp/setup-xfce4-perf.sh
  # Pre-configure IBus chewing (注音) input method
  - bash /tmp/setup-ibus.sh
  # ── Firefox deb (via Mozilla PPA, avoids snap sandbox issues in xrdp) ──
  # DEBIAN_FRONTEND=noninteractive: 防止 apt 在無 TTY 環境跳出 kernel upgrade 互動對話框
  # || true: PPA / install 失敗時 cloud-init 不標為 Error，Firefox 可事後手動裝
  - DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:mozillateam/ppa || true
  - DEBIAN_FRONTEND=noninteractive apt-get install -y firefox || true
  # ── podman rootless ─────────────────────────────────────────
  - bash /tmp/setup-podman-rootless.sh
  # ── k8s tools (CNI / kubectl / cilium) + taroko package ────
  - bash /tmp/setup-tools.sh
  # ── Start qemu-guest-agent (installed via packages above, but udev event ──
  # already fired before install, so re-trigger to activate the service)
  - udevadm trigger --subsystem-match=virtio-ports
  # ── 拿掉 SSH 登入時的 "*** System restart required ***" 提示 ───────
  # package_upgrade 升級 kernel 後 /var/run/reboot-required 會被建立，
  # /etc/update-motd.d/98-reboot-required 在每次 SSH 登入會檢查並印出該提示。
  # chmod -x 而非 rm：避免 update-notifier-common 重裝/升級時重新建立。
  - chmod -x /etc/update-motd.d/98-reboot-required || true
  # ── Cleanup ─────────────────────────────────────────────────
  - rm -f /tmp/xrdp-installer.sh /tmp/fix-xrdp-ini.sh /tmp/setup-xfce4-perf.sh /tmp/setup-ibus.sh /tmp/setup-podman-rootless.sh /tmp/setup-tools.sh

final_message: |
  tkcdc VM __VM_HOSTNAME__ first-boot setup done. Rebooting to apply kernel updates
  and finalize tk8s install (if enabled). Reconnect after reboot.
  User: __VM_USER__ | xRDP: enabled | Podman rootless: enabled

# ------------------------------------------------------------
# 第一次 boot 結束後自動 reboot：
#  - 讓 package_upgrade 升級的 kernel 生效
#  - 消除 SSH 登入時 "*** System restart required ***" 提示
#  - 第二次 boot serial-getty 帶 autologin 在乾淨環境跑 dialog（不被 cloud-init log 干擾）
#  - tk8s-post-boot.service 在乾淨環境執行 kto tk8s（如有 enable）
# timeout: 30 秒緩衝讓 cloud-init 完成寫 log；condition: True 強制執行
# ------------------------------------------------------------
power_state:
  mode: reboot
  message: First-boot setup done, rebooting...
  timeout: 30
  condition: True

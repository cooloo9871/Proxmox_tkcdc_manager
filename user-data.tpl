#cloud-config
# ============================================================
# Proxmox_tkcdc_manager - Cloud-Init User Data Template
# This file is generated per-VM by pve_tkcdc_manager.sh
# Variables __VM_HOSTNAME__, __VM_USER__, __VM_PASSWORD__,
# __NAMESERVER__ are replaced at runtime.
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
# DNS
# ------------------------------------------------------------
write_files:
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

  - path: /etc/resolv.conf
    permissions: '0644'
    owner: root:root
    content: |
      nameserver __NAMESERVER__

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
      CFGEOF
      chmod 755 /tmp/ibus-cfg.sh
      # dbus-run-session provides a session bus without needing a display
      su - "$USERNAME" -c "dbus-run-session -- bash /tmp/ibus-cfg.sh" || true
      rm -f /tmp/ibus-cfg.sh

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
      export PATH="$HOME/bin:$HOME/tk/bin:$HOME/kind/bin:$PATH"

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

      echo "Welcome to Ubuntu 24.04 : $IP"
      echo ""

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
      source /usr/share/bash-completion/bash_completion
      source <(kubectl completion bash)

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
  # ── xrdp via local installer (injected by generate_user_data) ──
  # Script must run as a normal user (it calls sudo internally)
  - su - __VM_USER__ -c "bash /tmp/xrdp-installer.sh"
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
  - add-apt-repository -y ppa:mozillateam/ppa
  - apt-get install -y firefox
  # ── podman rootless ─────────────────────────────────────────
  - bash /tmp/setup-podman-rootless.sh
  # ── k8s tools (CNI / kubectl / cilium) + taroko package ────
  - bash /tmp/setup-tools.sh
  # ── Start qemu-guest-agent (installed via packages above, but udev event ──
  # already fired before install, so re-trigger to activate the service)
  - udevadm trigger --subsystem-match=virtio-ports
  # ── Cleanup ─────────────────────────────────────────────────
  - rm -f /tmp/xrdp-installer.sh /tmp/fix-xrdp-ini.sh /tmp/setup-xfce4-perf.sh /tmp/setup-ibus.sh /tmp/setup-podman-rootless.sh /tmp/setup-tools.sh

final_message: |
  tkcdc VM __VM_HOSTNAME__ is ready.
  User: __VM_USER__ | xRDP: enabled | Podman rootless: enabled

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

  # xrdp post-config: set crypt_level=low and max_bpp=24
  - path: /tmp/fix-xrdp-ini.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini
      sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
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

# ------------------------------------------------------------
# Run commands at first boot
# Order: install xrdp → configure → setup podman rootless
# ------------------------------------------------------------
runcmd:
  # ── SSH 重啟套用密碼登入設定 ────────────────────────────
  - systemctl restart ssh
  # ── xrdp via local installer (injected by generate_user_data) ──
  # Script must run as a normal user (it calls sudo internally)
  - su - __VM_USER__ -c "bash /tmp/xrdp-installer.sh"
  # Ensure xfce4 is the xrdp session (c-nergy may not detect desktop in cloud-init)
  - echo "startxfce4" > /home/__VM_USER__/.xsessionrc
  - chown __VM_USER__:__VM_USER__ /home/__VM_USER__/.xsessionrc
  # Apply low-encryption config
  - bash /tmp/fix-xrdp-ini.sh
  # ── Firefox deb (via Mozilla PPA, avoids snap sandbox issues in xrdp) ──
  - add-apt-repository -y ppa:mozillateam/ppa
  - apt-get install -y firefox
  # ── podman rootless ─────────────────────────────────────────
  - bash /tmp/setup-podman-rootless.sh
  # ── Start qemu-guest-agent (installed via packages above, but udev event ──
  # already fired before install, so re-trigger to activate the service)
  - udevadm trigger --subsystem-match=virtio-ports
  # ── Cleanup ─────────────────────────────────────────────────
  - rm -f /tmp/xrdp-installer.sh /tmp/fix-xrdp-ini.sh /tmp/setup-podman-rootless.sh

final_message: |
  tkcdc VM __VM_HOSTNAME__ is ready.
  User: __VM_USER__ | xRDP: enabled | Podman rootless: enabled

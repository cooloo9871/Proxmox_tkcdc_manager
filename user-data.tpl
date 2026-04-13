#cloud-config
# ============================================================
# Proxmox_tkcdc_manager - Cloud-Init User Data Template
# This file is generated per-VM by pve_tkcdc_manager.sh
# Variables __VM_HOSTNAME__, __VM_USER__, __VM_PASSWORD__,
# __NAMESERVER__, __XRDP_VER__ are replaced at runtime.
# The xrdp installer script is injected as a base64-encoded
# write_files entry by generate_user_data() at build time.
# ============================================================

hostname: __VM_HOSTNAME__
manage_etc_hosts: true

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
  - xfce4
  - xfce4-goodies

# ------------------------------------------------------------
# Run commands at first boot
# Order: install xrdp → configure → setup podman rootless
# ------------------------------------------------------------
runcmd:
  # ── SSH 重啟套用密碼登入設定 ────────────────────────────
  - systemctl restart ssh
  # ── xrdp via local installer (injected by generate_user_data) ──
  # Run installer in non-interactive mode: option 3 = xfce
  - echo "3" | bash "/tmp/xrdp-installer-__XRDP_VER__.sh" || true
  # Apply low-encryption config
  - bash /tmp/fix-xrdp-ini.sh
  # ── podman rootless ─────────────────────────────────────────
  - bash /tmp/setup-podman-rootless.sh
  # ── Cleanup ─────────────────────────────────────────────────
  - rm -f "/tmp/xrdp-installer-__XRDP_VER__.sh" /tmp/fix-xrdp-ini.sh /tmp/setup-podman-rootless.sh

final_message: |
  tkcdc VM __VM_HOSTNAME__ is ready.
  User: __VM_USER__ | xRDP: enabled | Podman rootless: enabled

#!/usr/bin/env bash

#######
# Init

# wget -O "$HOME/bootstrap.sh" "https://raw.githubusercontent.com/d1-1b/d13/refs/heads/main/bootstrap.sh?nocache=$(date +%s)"

script_name="$(basename "$0")"

############
# Functions

write_c () {
    local tmp
    tmp="$(mktemp)"
    printf "%s\n" "$1" | sed 's/^[[:space:]]\+//' > "$tmp"
    if [ -f "$2" ] && cmp -s "$tmp" "$2"; then
        rm -f "$tmp"
        return 1   # unchanged
    fi
    mv "$tmp" "$2"
    return 0       # changed
}

sed_c () {
    local file="$1"
    shift
    local tmp
    tmp="$(mktemp)"
    cp -p "$file" "$tmp"
    sed -i "$@" "$tmp"
    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1   # unchanged
    fi
    mv "$tmp" "$file"
    return 0       # changed
}

cat_c () {
    local file="$1"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1   # unchanged
    fi
    mv "$tmp" "$file"
    return 0       # changed
}

#######
# MAIN

if [ "$script_name" = "bootstrap.sh" ]; then

    #############
    # ROOT PHASE

    if [ "$EUID" -ne 0 ]; then
        exec pkexec bash "$0" "$@"
    fi

    user_name="$(id -un "$PKEXEC_UID")"

    #######
    # Sudo

    usermod -aG sudo $user_name

    ######
    # DNS

    if [ -d /etc/NetworkManager ]; then
        if write_c "[main]
                    rc-manager=unmanaged" /etc/NetworkManager/conf.d/98-rc-manager.conf; then
            systemctl reload NetworkManager.service
        fi
    fi

    systemctl reload NetworkManager.service

    write_c "nameserver 9.9.9.9" /etc/resolv.conf

    #########
    # Update

    apt update
    apt upgrade -y

    ###################
    # Systemd-resolved

    apt install -y systemd-resolved
    systemctl enable systemd-resolved --now

    if sed_c /etc/systemd/resolved.conf \
          -e 's/^\s*#\?\s*DNS=.*/DNS=9.9.9.9/' \
          -e 's/^\s*#\?\s*MulticastDNS=.*/MulticastDNS=no/' \
          -e 's/^\s*#\?\s*LLMNR=.*/LLMNR=no/' \
          -e 's/^\s*#\?\s*DNSStubListener=.*/DNSStubListener=no/'; then

        systemctl restart systemd-resolved
    fi

    if [ ! -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi

    #########
    # Sysctl

    SYSCTL_CHANGED=0
    write_c "net.ipv4.conf.all.accept_redirects = 0
             net.ipv4.conf.all.log_martians = 1
             net.ipv4.conf.all.rp_filter = 2
             net.ipv4.conf.all.secure_redirects = 0
             net.ipv4.conf.all.send_redirects = 0
             net.ipv4.conf.all.shared_media = 0
             net.ipv4.conf.default.accept_redirects = 0
             net.ipv4.conf.default.log_martians = 1
             net.ipv4.conf.default.secure_redirects = 0
             net.ipv4.conf.default.send_redirects = 0
             net.ipv4.conf.default.shared_media = 0
             net.ipv4.ip_local_port_range = 32768 65535
             net.ipv4.tcp_max_syn_backlog = 4096
             net.ipv4.tcp_rfc1337 = 1
             net.sctp.sctp_enable = 0" /etc/sysctl.d/99-network-hardening.conf && SYSCTL_CHANGED=1

    write_c "kernel.kexec_load_disabled = 1
             kernel.kptr_restrict = 2
             kernel.sysrq = 0
             kernel.unprivileged_userns_clone = 0
             net.core.bpf_jit_harden = 2" /etc/sysctl.d/99-system-hardening.conf && SYSCTL_CHANGED=1

    #######
    # IPv6

    write_c "net.ipv6.conf.all.disable_ipv6 = 1
             net.ipv6.conf.default.disable_ipv6 = 1" /etc/sysctl.d/99-disable-ipv6.conf && SYSCTL_CHANGED=1

    ##########
    # Watches

    write_c "fs.inotify.max_user_watches=482808" /etc/sysctl.d/99-inotify.conf && SYSCTL_CHANGED=1

    if [ "$SYSCTL_CHANGED" -eq 1 ]; then
        sysctl --system
    fi

    #######
    # Boot

    sed -i \
      -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' \
      -e '/^GRUB_TIMEOUT_STYLE=/d' \
      -e '/^GRUB_TIMEOUT=0/a GRUB_TIMEOUT_STYLE=menu' \
      -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=6"/' \
      -e 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="ipv6.disable=1"/' \
      /etc/default/grub
    update-grub

    #######
    # Motd

    rm -f /etc/update-motd.d/* 2>/dev/null || true
    truncate -s 0 /etc/motd

    #########
    # Locale

    NEED_LOCALE_GEN=0
    locale -a | grep -qi '^en_US\.utf8$' || NEED_LOCALE_GEN=1
    locale -a | grep -qi '^sv_SE\.utf8$' || NEED_LOCALE_GEN=1

    if [ "$NEED_LOCALE_GEN" -eq 1 ]; then
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8 LC_ALL= LC_TIME=sv_SE.UTF-8
        localectl set-x11-keymap se
    fi

    ##########
    # Install

    apt install -y \
      nala git rsync \
      xrdp xfce4 xfce4-terminal xfce4-genmon-plugin \
      fish fonts-noto-color-emoji \
      fzf fd-find eza bat chafa hexyl \
      ncdu btop iftop mtr-tiny \
      screenfetch cmatrix cbonsai tty-clock cowsay

    fc-cache

    [ "$(readlink -f /usr/local/bin/fd 2>/dev/null)" = "/usr/bin/fdfind" ] || ln -sf /usr/bin/fdfind /usr/local/bin/fd
    [ "$(readlink -f /usr/local/bin/bat 2>/dev/null)" = "/usr/bin/batcat" ] || ln -sf /usr/bin/batcat /usr/local/bin/bat

    # Oh-my-posh
    if [ ! -x /usr/local/bin/oh-my-posh ]; then
        wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-arm64 \
             -O /usr/local/bin/oh-my-posh
        chmod +x /usr/local/bin/oh-my-posh
    fi

    # Lolcat-cc
    if [ ! -x /usr/local/bin/lolcat ]; then
        wget -q https://github.com/n-ham/lolcat-cc/releases/download/v1.0.1/lolcat-cc \
         -O /usr/local/bin/lolcat
        chmod +x /usr/local/bin/lolcat
    fi

    # Sublime
    if [ ! -f /usr/share/keyrings/sublimehq-archive.gpg ]; then
        wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
             | gpg --dearmor > /usr/share/keyrings/sublimehq-archive.gpg
    fi

    if write_c "deb [signed-by=/usr/share/keyrings/sublimehq-archive.gpg] https://download.sublimetext.com/ apt/stable/" \
            /etc/apt/sources.list.d/sublime-text.list; then
        apt update
        apt install -y sublime-text
    fi

    ###########
    # Nftables

        systemctl enable nftables --now

    if cat_c /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    # --- PRE-ROUTING ---
    # --- DNAT / redirect ---
    chain prerouting {
        type nat hook prerouting priority dstnat;
    }

    # --- Services ---
    set services {
        type ifname . inet_proto . inet_service;
        flags constant;
        elements = {
            "eth0" . tcp . 22,
            "eth0" . tcp . 3389,
        }
    }

    # --- INPUT ---
    chain input {
        type filter hook input priority filter;
        policy drop;

        # Loopback
        iif "lo" accept

        # ICMP
        ip protocol icmp accept

        # Connection tracking
        ct state established,related accept
        ct state invalid drop

        # Services
        iifname . ip protocol . th dport @services accept
    }

    # --- OUTPUT ---
    chain output {
        type filter hook output priority filter;
        policy accept;
    }

    # --- FORWARD ---
    chain forward {
        type filter hook forward priority filter;
        policy drop;
    }

    # --- POST-ROUTING ---
    # --- SNAT / masquerade ---
    chain postrouting {
        type nat hook postrouting priority srcnat;
    }
}
EOF
    then
        systemctl reload nftables
    fi

    ######
    # Ssh

    if sed_c /etc/ssh/sshd_config \
          -e 's/^#\?ListenAddress 0\.0\.0\.0.*/ListenAddress 0.0.0.0/' \
          -e 's/^#\?AddressFamily.*/AddressFamily inet/'; then

        systemctl restart sshd
    fi

    #######
    # Xrdp

    if ! systemctl is-active --quiet xrdp; then
        systemctl enable xrdp --now

        xrdp_changed=0
        sesman_changed=0

        if sed_c /etc/xrdp/xrdp.ini \
            -e '0,/^port=3389$/s//port=vsock:\/\/-1:3389/' \
            -e 's/^security_layer=.*/security_layer=rdp/' \
            -e 's/^crypt_level=.*/crypt_level=none/'
        then
            xrdp_changed=1
        fi

        if sed_c /etc/xrdp/sesman.ini \
            's/^FuseMountName=.*/FuseMountName=shared-drives/'
        then
            sesman_changed=1
        fi

        if [ "$xrdp_changed" -eq 1 ]; then
            systemctl restart xrdp
        fi

        if [ "$sesman_changed" -eq 1 ]; then
            systemctl restart xrdp-sesman
        fi
    fi

    echo hv_sock > /etc/modules-load.d/hv_sock.conf

    ###########
    # Ethernet

    if [ -d /etc/NetworkManager ]; then
        if write_c "[keyfile]
                    unmanaged-devices=interface-name:eth0" /etc/NetworkManager/conf.d/99-unmanaged-eth0.conf; then
            systemctl reload NetworkManager
        fi
    fi

    if write_c "[Match]
                Name=eth0

                [DHCP]
                UseDNS=yes
                UseGateway=yes
                UseRoutes=yes

                [Network]
                LinkLocalAddressing=no
                IPv6AcceptRA=no
                DHCP=ipv4" /etc/systemd/network/00-eth0.network; then

        systemctl enable systemd-networkd --now
        systemctl reload systemd-networkd
    fi

    if [ -d /etc/NetworkManager ]; then

        systemctl disable NetworkManager --now

        apt purge -y network-manager network-manager-gnome
        apt purge -y netplan.io cloud-init

        rm -rf /etc/NetworkManager
        rm -rf /etc/netplan
        rm -rf /etc/cloud
    fi

    ######
    # End

    mv "$0" "/home/$user_name/configure.sh"
    read -p "Press Enter to poweroff: " _
    systemctl poweroff

else

    #############
    # USER PHASE

    if [ "$EUID" -eq 0 ]; then
        echo "Do not run user phase as root."
        exit 1
    fi

    # Clear panel defaults
    rm -rf ~/.config/xfce4/panel

    ########
    # Fonts

    mkdir -p ~/.local/share/fonts
    wget -O Hack.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip
    unzip -oq Hack.zip 'HackNerdFont-Regular.ttf' -d ~/.local/share/fonts
    unzip -oq Hack.zip 'HackNerdFontMono-Regular.ttf' -d ~/.local/share/fonts
    rm Hack.zip
    fc-cache -f

    #########
    # Themes

    mkdir -p ~/.themes
    wget -O Sweet.tar.xz https://github.com/EliverLara/Sweet/releases/download/v6.0/Sweet-mars-v40.tar.xz
    tar -xf Sweet.tar.xz -C ~/.themes
    rm Sweet.tar.xz

    ########
    # Icons

    mkdir -p ~/.icons
    wget -O candy.zip https://github.com/EliverLara/candy-icons/archive/refs/heads/master.zip
    unzip -oq candy.zip -d ~/.icons
    mv ~/.icons/candy-icons-master ~/.icons/candy-icons
    rm candy.zip

    gtk-update-icon-cache -f ~/.icons/candy-icons

    #########
    # Github

    fish -c '
      # Init
      set -Ux DF_NAME "d1-1b"
      set -Ux DF_MAIL "255606277+d1-1b@users.noreply.github.com"
      set -Ux DF_ORIGIN "https://d1-1b@github.com/d1-1b/dotfiles.git"
      set -Ux DF_REPO ~/.local/share/d13

      # Set username
      git config --global user.name "$DF_NAME"

      # Set E-mail
      git config --global user.email "$DF_MAIL"

      # Enable credential storage
      git config --global credential.helper store

      # Clone repo
      git clone "$DF_ORIGIN" "$DF_REPO"

      if not git -C "$DF_REPO" rev-parse HEAD >/dev/null 2>&1
          echo "Clone failed — aborting bootstrap."
          exit 1
      end

      # Load dotfiles
      source "$DF_REPO/.setup/dotfiles.fish"

      # Initial sync
      sync_from_repo
    '

    #######
    # Fish

    if [ "$SHELL" != "/usr/bin/fish" ]; then
        chsh -s /usr/bin/fish "$USER"
    fi

    read -p "Press Enter to logout: " _
    xfce4-session-logout -l
fi

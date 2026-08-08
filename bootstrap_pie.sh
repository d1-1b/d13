#!/usr/bin/env bash

#######
# Init

# wget -O "$HOME/bootstrap_pie.sh" "https://raw.githubusercontent.com/d1-1b/d13/refs/heads/main/bootstrap_pie.sh?nocache=$(date +%s)"

script_name="$(basename "$0")"

############
# Functions

write_c () {
    printf "%s\n" "$1" | sed 's/^[[:space:]]\+//' > "$2"
}

if [ "$script_name" = "bootstrap_pie.sh" ]; then

    #############
    # ROOT PHASE

    if [ "$EUID" -ne 0 ]; then
        exec sudo bash "$0" "$@"
    fi

    user_name="$(id -un "$SUDO_UID")"

    #######
    # Sudo

    usermod -aG sudo $user_name

    ######
    # DNS

    write_c "[main]
             rc-manager=unmanaged" /etc/NetworkManager/conf.d/98-rc-manager.conf

    systemctl reload NetworkManager.service

    write_c "nameserver 9.9.9.9" /etc/resolv.conf

    #########
    # Update

    apt update
    apt upgrade -y

    ###################
    # Systemd-resolved

    apt install -y systemd-resolved

    sed -i 's/^\s*#\?\s*DNS=.*/DNS=9.9.9.9/' /etc/systemd/resolved.conf
    sed -i 's/^\s*#\?\s*MulticastDNS=.*/MulticastDNS=no/' /etc/systemd/resolved.conf
    sed -i 's/^\s*#\?\s*LLMNR=.*/LLMNR=no/' /etc/systemd/resolved.conf
    sed -i 's/^\s*#\?\s*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf

    systemctl enable systemd-resolved --now

    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

    systemctl restart systemd-resolved

    #########
    # Sysctl

cat > /etc/sysctl.d/99-network-hardening.conf << 'EOF'
net.ipv4.conf.all.accept_redirects = 0
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
net.sctp.sctp_enable = 0
EOF

cat > /etc/sysctl.d/99-system-hardening.conf << 'EOF'
kernel.kexec_load_disabled = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.unprivileged_userns_clone = 0
net.core.bpf_jit_harden = 2
EOF

    #######
    # IPv6

    write_c "net.ipv6.conf.all.disable_ipv6 = 1
             net.ipv6.conf.default.disable_ipv6 = 1" /etc/sysctl.d/99-disable-ipv6.conf

    ##########
    # Watches

    write_c "fs.inotify.max_user_watches=482808" /etc/sysctl.d/99-inotify.conf

    sysctl --system

    #######
    # Boot

    sed -i \
      -e 's/quiet splash //' \
      -e '/loglevel=6/!s/$/ loglevel=6 ipv6.disable=1/' \
      /boot/firmware/cmdline.txt

    #######
    # Motd

    rm /etc/update-motd.d/*
    truncate -s 0 /etc/motd

    #########
    # Locale

    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen

    update-locale LANG=en_US.UTF-8 LC_ALL= LC_TIME=sv_SE.UTF-8

    localectl set-x11-keymap se

    ##########
    # Install

    apt install -y \
      nala git rsync \
      xrdp xfce4 xfce4-terminal xfce4-genmon-plugin \
      fish fonts-noto-color-emoji \
      fzf fd-find eza bat chafa hexyl \
      ncdu btop iftop mtr-tiny \
      screenfetch cmatrix cbonsai tty-clock cowsay

    fc-cache -f

    ln -sf /usr/bin/fdfind /usr/local/bin/fd
    ln -sf /usr/bin/batcat /usr/local/bin/bat

    # Oh-my-posh
    wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-arm64 \
         -O /usr/local/bin/oh-my-posh
    chmod +x /usr/local/bin/oh-my-posh

    # lolcat-cc
    wget -q https://github.com/lolcatpp/lolcatpp/releases/download/v2.6.0/lolcat++_2.6.0.trixie_arm64.deb \
         -O /dev/shm/lolcatpp.deb
    apt install -y /dev/shm/lolcatpp.deb
    rm /dev/shm/lolcatpp.deb

    # Sublime
    wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
         | gpg --dearmor > /usr/share/keyrings/sublimehq-archive.gpg

    write_c "deb [signed-by=/usr/share/keyrings/sublimehq-archive.gpg] https://download.sublimetext.com/ apt/stable/" \
            /etc/apt/sources.list.d/sublime-text.list

    apt update
    apt install -y sublime-text

    ###########
    # Nftables

cat > /etc/nftables.conf << 'EOF'
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

    systemctl enable nftables --now
    systemctl reload nftables

    ######
    # Ssh

    sed -i \
      -e 's/^#\?ListenAddress 0\.0\.0\.0.*/ListenAddress 0.0.0.0/' \
      -e 's/^#\?AddressFamily.*/AddressFamily inet/' \
      /etc/ssh/sshd_config

    systemctl restart sshd

    #######
    # Xrdp

    systemctl enable xrdp --now

    sed -i 's/^security_layer=.*/security_layer=rdp/' /etc/xrdp/xrdp.ini
    sed -i 's/^crypt_level=.*/crypt_level=none/' /etc/xrdp/xrdp.ini

    sed -i 's/^FuseMountName=.*/FuseMountName=shared-drives/' /etc/xrdp/sesman.ini

    systemctl restart xrdp xrdp-sesman

    ########
    # Wi-Fi

    iw dev wlan0 set power_save off

    systemctl stop NetworkManager

    write_c "0" "/var/lib/systemd/rfkill/platform-1001100000.mmc:wlan"

    write_c "[main]
    NetworkingEnabled=true
    WirelessEnabled=true
    WWANEnabled=true" /var/lib/NetworkManager/NetworkManager.state

    write_c "[keyfile]
             unmanaged-devices=interface-name:wlan0" /etc/NetworkManager/conf.d/97-unmanaged-wlan0.conf

    systemctl start NetworkManager

    rfkill unblock wifi

    apt install -y iwd
    systemctl enable --now iwd

    write_c "[Match]
             Name=wlan0

             [DHCP]
             UseDNS=yes
             UseGateway=yes
             UseRoutes=yes

             [Network]
             LinkLocalAddressing=no
             IPv6AcceptRA=no
             DHCP=ipv4" /etc/systemd/network/10-wlan0.network

    systemctl enable systemd-networkd --now

    iwctl station wlan0 scan
    sleep 3
    iwctl station wlan0 get-networks
    iwctl station wlan0 connect bCl-5G1

    ###########
    # Ethernet

    write_c "[keyfile]
             unmanaged-devices=interface-name:eth0" /etc/NetworkManager/conf.d/99-unmanaged-eth0.conf

    systemctl reload NetworkManager

    write_c "[Match]
             Name=eth0

             [DHCP]
             UseDNS=yes
             UseGateway=yes
             UseRoutes=yes

             [Network]
             LinkLocalAddressing=no
             IPv6AcceptRA=no
             DHCP=ipv4" /etc/systemd/network/00-eth0.network

    systemctl enable systemd-networkd --now
    systemctl reload systemd-networkd

    systemctl disable NetworkManager --now

    apt purge -y network-manager network-manager-gnome
    apt purge -y netplan.io cloud-init

    rm -rf /etc/NetworkManager
    rm -rf /etc/netplan
    rm -rf /etc/cloud

    ######
    # End

    mv "$0" "/home/$user_name/configure_pie.sh"

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
fi

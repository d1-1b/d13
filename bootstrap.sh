#!/usr/bin/env bash

#######
# Init

# wget -O "$HOME/bootstrap.sh" "https://raw.githubusercontent.com/d1-1b/d13/refs/heads/main/bootstrap.sh?nocache=$(date +%s)"

script_name="$(basename "$0")"

############
# Functions

write_c () {
    printf "%s\n" "$1" | sed 's/^[[:space:]]\+//' > "$2"
}

if [ "$script_name" = "bootstrap.sh" ]; then

    #############
    # Root phase

    if [ "$EUID" -ne 0 ]; then
        exec pkexec bash "$0" "$@"
    fi

    user_name="$(id -un "$PKEXEC_UID")"

    #######
    # Sudo

    usermod -aG sudo $user_name

    #########
    # Update

    apt update
    apt upgrade -y

    ##########
    # Network

    apt install -y systemd-resolved

    systemctl enable systemd-networkd --now
    systemctl enable systemd-resolved --now

    systemctl disable NetworkManager --now

    write_c "[Match]
             Name=eth0

             [DHCP]
             UseDNS=yes

             [Network]
             LinkLocalAddressing=no
             IPv6AcceptRA=no
             DHCP=ipv4" /etc/systemd/network/00-eth0.network

    systemctl restart systemd-networkd

cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    # --- Services ---
    set br0_services {
        type ifname . inet_proto . inet_service;
        flags constant;
        elements = {
            "eth0" . tcp . 22,
        }
    }

    # --- INPUT ---
    chain input {
        type filter hook input priority filter;
        policy drop;

        # Loopback
        iif "lo" accept

        # ICMP echo-request ratelimit
        icmp type echo-request limit rate over 10/second burst 20 packets counter drop

        # ICMP
        ip protocol icmp accept

        # Connection tracking
        ct state established,related accept
        ct state invalid drop

        # Services
        (iifname . ip protocol . th dport) @br0_services accept
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
}

table ip nat {

    # --- PRE-ROUTING ---
    chain prerouting {
        type nat hook prerouting priority dstnat;
    }

    # --- POST-ROUTING ---
    chain postrouting {
        type nat hook postrouting priority srcnat;

        # Masquerade (dynamic SNAT)
        #oifname "eth_" masquerade
    }
}
EOF

    systemctl reload nftables

    sed -i 's/^\s*#\?\s*MulticastDNS=.*/MulticastDNS=no/' /etc/systemd/resolved.conf
    sed -i 's/^\s*#\?\s*LLMNR=.*/LLMNR=no/' /etc/systemd/resolved.conf

    systemctl restart systemd-resolved

    write_c "net.ipv6.conf.all.disable_ipv6 = 1
             net.ipv6.conf.default.disable_ipv6 = 1" /etc/sysctl.d/99-disable-ipv6.conf

    ##########
    # Watches

    write_c "fs.inotify.max_user_watches=482808" /etc/sysctl.d/99-inotify.conf

    sysctl --system

    ########
    # Stuff

    apt install -y \
      nala ncdu xclip \
      fish fzf fd-find eza bat chafa hexyl \
      btop iftop mtr-tiny fonts-noto-color-emoji \
      tty-clock screenfetch cmatrix cbonsai \
      git rsync \
      xrdp viewnior \

    fc-cache -f

    ln -sf /usr/bin/fdfind /usr/local/bin/fd
    ln -sf /usr/bin/batcat /usr/local/bin/bat

    # oh-my-posh
    wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-amd64 \
         -O /usr/local/bin/oh-my-posh
    chmod +x /usr/local/bin/oh-my-posh

    # sublime
    wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
      | gpg --dearmor > /usr/share/keyrings/sublimehq-archive.gpg

    write_c "deb [signed-by=/usr/share/keyrings/sublimehq-archive.gpg] https://download.sublimetext.com/ apt/stable/" \
            /etc/apt/sources.list.d/sublime-text.list

    apt update
    apt install -y sublime-text

    #######
    # Xrdp

    systemctl enable xrdp --now

    echo hv_sock > /etc/modules-load.d/hv_sock.conf

    sed -i '0,/^port=3389$/s//port=vsock:\/\/-1:3389/' /etc/xrdp/xrdp.ini
    sed -i 's/^security_layer=.*/security_layer=rdp/' /etc/xrdp/xrdp.ini
    sed -i 's/^crypt_level=.*/crypt_level=none/' /etc/xrdp/xrdp.ini

    sed -i 's/^FuseMountName=.*/FuseMountName=shared-drives/' /etc/xrdp/sesman.ini

    systemctl restart xrdp xrdp-sesman

    ######
    # Ssh

    truncate -s 0 /etc/motd

    sed -i \
      -e 's/^#\?ListenAddress 0\.0\.0\.0.*/ListenAddress 0.0.0.0/' \
      -e 's/^#\?AddressFamily.*/AddressFamily inet/' \
      /etc/ssh/sshd_config

    systemctl restart sshd

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

    mv "$0" "/home/$user_name/configure.sh"

    read -p "Press Enter to poweroff: " _
    systemctl poweroff

else

    #############
    # User phase

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

      # Load dotfiles
      source "$DF_REPO/.setup/dotfiles.fish"

      # Initial sync
      pull
    '

    #######
    # Fish

    if [ "$SHELL" != "/usr/bin/fish" ]; then
        chsh -s /usr/bin/fish "$USER"
    fi

    read -p "Press Enter to logout: " _
    xfce4-session-logout -l
fi

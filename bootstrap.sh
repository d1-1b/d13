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
             UseGateway=yes
             UseRoutes=yes

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
    set services {
        type ifname . inet_proto . inet_service;
        flags constant;
        elements = {
            "eth0" . tcp . 22,
        }
    }

    # --- PRE-ROUTING ---
    # --- DNAT / redirect ---
    chain prerouting {
        type nat hook prerouting priority dstnat;
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
        iifname . ip protocol . th dport @br0_services accept
    }

    # --- FORWARD ---
    chain forward {
        type filter hook forward priority filter;
        policy drop;
    }

    # --- OUTPUT ---
    chain output {
        type filter hook output priority filter;
        policy accept;
    }

    # --- POST-ROUTING ---
    # --- SNAT / masquerade ---
    chain postrouting {
        type nat hook postrouting priority srcnat;
    }
}
EOF

    systemctl reload nftables

    sed -i 's/^\s*#\?\s*MulticastDNS=.*/MulticastDNS=no/' /etc/systemd/resolved.conf
    sed -i 's/^\s*#\?\s*LLMNR=.*/LLMNR=no/' /etc/systemd/resolved.conf

    systemctl restart systemd-resolved

    write_c "net.ipv6.conf.all.disable_ipv6 = 1
             net.ipv6.conf.default.disable_ipv6 = 1" /etc/sysctl.d/99-disable-ipv6.conf

    #########
    # Sysctl

cat > /etc/sysctl.d/99-network-hardening.conf << 'EOF'
# https://github.com/jeffbencteux/sysctlchk/blob/main/refs/all.conf

# Filter by reverse-path (source validation)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# No ICMP redirection messages
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# No ICMP response to broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Refuse source-routing packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Refuse ICMP redirect messages
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.shared_media = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.default.shared_media = 0

# Consider as invalid packets coming from external machines with source IP in 127.0.0.0/8 network
net.ipv4.conf.all.accept_local = 0

# Do not route packets with source or destination addresses in 127.0.0.0/8 network
net.ipv4.conf.all.route_localnet = 0

# Log packets with abnormal IP addresses
net.ipv4.conf.all.log_martians = 1

# RFC 1337: protection against TCP time-wait assassination
net.ipv4.tcp_rfc1337 = 1

# Ignore RFC1122 non-compliant answers
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Broader range for ephemeral ports
net.ipv4.ip_local_port_range = 32768 65535

# Use SYN cookies
net.ipv4.tcp_syncookies = 1

# Increase size of received SYN segments (protection against SYN flooding)
net.ipv4.tcp_max_syn_backlog = 4096

# Disable IPv6 router solicitations
net.ipv6.conf.all.router_solicitations = 0
net.ipv6.conf.default.router_solicitations = 0

# Do not accept IPv6 router preferences given by router advertisements
net.ipv6.conf.all.accept_ra_rtr_pref = 0
net.ipv6.conf.default.accept_ra_rtr_pref = 0

# Do not accept auto prefix given by router advertisements
net.ipv6.conf.all.accept_ra_pinfo = 0
net.ipv6.conf.default.accept_ra_pinfo = 0

# Do not auto-learn via router advertisements
net.ipv6.conf.all.accept_ra_defrtr = 0
net.ipv6.conf.default.accept_ra_defrtr = 0

# No auto-configuration of IPv6 addresses via router advertisements
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0

# Do not accept ICMPv6 redirects
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not accept IPv6 source routing packets
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Reduce the number of IPv6 addresses per interface
net.ipv6.conf.all.max_addresses = 1
net.ipv6.conf.default.max_addresses = 1
EOF

cat > /etc/sysctl.d/99-system-hardening.conf << 'EOF'
# https://github.com/jeffbencteux/sysctlchk/blob/main/refs/all.conf

# Disallow kernel profiling by users without CAP_SYS_ADMIN
kernel.perf_event_paranoid = 2

# Disable sysrq (see here https://www.kernel.org/doc/Documentation/admin-guide/sysrq.rst)
kernel.sysrq = 0

# ASLR
kernel.randomize_va_space = 2

# Restrict kernel buffer read access
kernel.dmesg_restrict = 1

# Restrict access to kernel pointers in the proc filesystem
kernel.kptr_restrict = 2

# Explicitely set the kernel PID namespace size (setting it to PID_MAX_LIMIT: 2^22)
kernel.pid_max = 4194304

# Restrict BPF programs to privileged users
kernel.unprivileged_bpf_disabled = 1

# Set JIT BPF hardening, mitigates some JIT spraying attacks
net.core.bpf_jit_harden = 2

# Disable kexec. Avoid to replace and reload the kernel without going through the bootloader
kernel.kexec_load_disabled = 1

# Strict rules on writing sysctl files
kernel.sysctl_writes_strict = 1

# Disable coredumps of SUID binaries
fs.suid_dumpable = 0

# Avoid certain TOCTOU attacks on files
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Avoid unitentionnal writes to attacker-controlled FIFOs and files value could also be 2
fs.protected_fifos = 1
fs.protected_regular = 1
EOF

    ##########
    # Watches

    write_c "fs.inotify.max_user_watches=482808" /etc/sysctl.d/99-inotify.conf

    sysctl --system

    ########
    # Stuff

    apt install -y \
      nala git rsync \
      xrdp ncdu viewnior \
      fish fzf fd-find eza bat chafa hexyl \
      btop iftop mtr-tiny fonts-noto-color-emoji \
      screenfetch cmatrix cbonsai tty-clock \

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

      if not git -C "$DF_REPO" rev-parse HEAD >/dev/null 2>&1
          echo "❌ Clone failed — aborting bootstrap."
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

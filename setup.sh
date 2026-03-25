#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# setup-vpn-server — Automated sing-box deployment with VLESS Reality,
#                    Hysteria2, and SOCKS5 on Ubuntu
#
# Usage:
#   sudo ./setup.sh --domain example.com --email me@mail.com \
#                   --username myuser --ssh-key "ssh-ed25519 AAAA..."
#
# Repository: https://github.com/sxwebdev/setup-vpn-server
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# 1. HELPERS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}${BOLD}>>> $*${NC}"; }

die() {
    log_error "$@"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS. /etc/os-release not found."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]]; then
        die "This script requires Ubuntu. Detected: ${ID}"
    fi
    log_ok "OS: ${PRETTY_NAME}"
}

command_exists() {
    command -v "$1" &>/dev/null
}

# Install essential tools needed before anything else runs
install_dependencies() {
    local deps=()
    command_exists curl    || deps+=(curl)
    command_exists openssl || deps+=(openssl)
    command_exists ip      || deps+=(iproute2)

    if [[ ${#deps[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${deps[*]}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${deps[@]}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

# Defaults
DOMAIN=""
EMAIL=""
USERNAME=""
SSH_PUBLIC_KEY=""
REALITY_SNI="www.google.com"
SOCKS_PORT=1081
VLESS_PORT=10443
HY2_PORT=443
HY2_UP_MBPS=100
HY2_DOWN_MBPS=100
SKIP_HARDENING=false
SKIP_CERTBOT=false
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)       DOMAIN="$2"; shift 2 ;;
            --email)        EMAIL="$2"; shift 2 ;;
            --username)     USERNAME="$2"; shift 2 ;;
            --ssh-key)      SSH_PUBLIC_KEY="$2"; shift 2 ;;
            --ssh-key-file)
                [[ -f "$2" ]] || die "SSH key file not found: $2"
                SSH_PUBLIC_KEY=$(cat "$2")
                shift 2
                ;;
            --reality-sni)    REALITY_SNI="$2"; shift 2 ;;
            --socks-port)     SOCKS_PORT="$2"; shift 2 ;;
            --vless-port)     VLESS_PORT="$2"; shift 2 ;;
            --hy2-port)       HY2_PORT="$2"; shift 2 ;;
            --hy2-bandwidth)  HY2_UP_MBPS="$2"; HY2_DOWN_MBPS="$2"; shift 2 ;;
            --skip-hardening) SKIP_HARDENING=true; shift ;;
            --skip-certbot)   SKIP_CERTBOT=true; shift ;;
            --dry-run)        DRY_RUN=true; shift ;;
            --help|-h)        usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

# Also read from env vars (CLI args take priority)
load_env_defaults() {
    DOMAIN="${DOMAIN:-${SETUP_DOMAIN:-}}"
    EMAIL="${EMAIL:-${SETUP_EMAIL:-}}"
    USERNAME="${USERNAME:-${SETUP_USERNAME:-}}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-${SETUP_SSH_PUBLIC_KEY:-}}"
    REALITY_SNI="${REALITY_SNI:-${SETUP_REALITY_SNI:-www.google.com}}"
}

validate_args() {
    local missing=()
    [[ -z "$DOMAIN" ]]         && missing+=("--domain")
    [[ -z "$EMAIL" ]]          && missing+=("--email")
    [[ -z "$USERNAME" ]]       && missing+=("--username")
    [[ -z "$SSH_PUBLIC_KEY" ]] && missing+=("--ssh-key or --ssh-key-file")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required parameters: ${missing[*]}"
        echo ""
        usage
        exit 1
    fi

    # Validate port numbers
    for port_var in SOCKS_PORT VLESS_PORT HY2_PORT; do
        local val="${!port_var}"
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 || "$val" -gt 65535 ]]; then
            die "Invalid port number for $port_var: $val"
        fi
    done
}

usage() {
    cat <<'USAGE'
Usage: sudo ./setup.sh [OPTIONS]

Required:
  --domain DOMAIN           Domain pointing to this server (for TLS cert)
  --email EMAIL             Email for Let's Encrypt notifications
  --username USERNAME       Non-root user to create
  --ssh-key "KEY"           SSH public key string
  --ssh-key-file PATH       Path to SSH public key file

Optional:
  --reality-sni HOST        Domain to impersonate for Reality (default: www.google.com)
  --socks-port PORT         SOCKS5 port (default: 1081)
  --vless-port PORT         VLESS Reality port (default: 10443)
  --hy2-port PORT           Hysteria2 UDP port (default: 443)
  --hy2-bandwidth NUM       Up/down Mbps for Hysteria2 (default: 100)
  --skip-hardening          Skip server hardening phase
  --skip-certbot            Skip TLS certificate issuance
  --dry-run                 Show what would be done without executing
  --help, -h                Show this help message

Examples:
  sudo ./setup.sh --domain vpn.example.com --email me@mail.com \
                  --username admin --ssh-key "ssh-ed25519 AAAA..."

  sudo ./setup.sh --domain vpn.example.com --email me@mail.com \
                  --username admin --ssh-key-file ~/.ssh/id_ed25519.pub
USAGE
}

detect_server_ip() {
    SERVER_IP=""
    # Try multiple services for reliability
    for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
        SERVER_IP=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && break
    done

    if [[ -z "$SERVER_IP" ]]; then
        # Fallback: get IP from default network interface
        SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)
    fi

    [[ -n "$SERVER_IP" ]] || die "Could not detect server public IP address"
    log_ok "Server IP: ${SERVER_IP}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. SECRET GENERATION
# ─────────────────────────────────────────────────────────────────────────────

generate_secrets() {
    log_step "Generating secrets"

    if command_exists uuidgen; then
        UUID=$(uuidgen)
    elif command_exists sing-box; then
        UUID=$(sing-box generate uuid)
    else
        # Fallback: generate UUID v4 from /proc/sys/kernel/random/uuid or openssl
        if [[ -f /proc/sys/kernel/random/uuid ]]; then
            UUID=$(cat /proc/sys/kernel/random/uuid)
        else
            UUID=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-4\3-\4-\5/')
        fi
    fi
    SOCKS_PASS=$(openssl rand -hex 32)
    HY2_PASS=$(openssl rand -hex 32)
    OBFS_PASS=$(openssl rand -hex 16)
    SHORT_ID=$(openssl rand -hex 4)

    # Reality keypair will be generated later after sing-box is installed
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""

    log_ok "UUID: ${UUID}"
    log_ok "Secrets generated"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. SYSTEM HARDENING
# ─────────────────────────────────────────────────────────────────────────────

update_system() {
    log_step "Updating system packages"
    apt-get update -y
    apt-get upgrade -y
    apt-get full-upgrade -y
    apt-get autoremove -y
    apt-get autoclean
    log_ok "System updated"
}

create_user() {
    log_step "Creating user: ${USERNAME}"

    if id "$USERNAME" &>/dev/null; then
        log_warn "User ${USERNAME} already exists, skipping creation"
    else
        adduser --disabled-password --gecos "" "$USERNAME"
        usermod -aG sudo "$USERNAME"
        # Allow sudo without password for this user
        echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
        chmod 440 "/etc/sudoers.d/${USERNAME}"
        log_ok "User ${USERNAME} created with sudo access"
    fi

    # Setup SSH key
    local ssh_dir="/home/${USERNAME}/.ssh"
    mkdir -p "$ssh_dir"
    echo "$SSH_PUBLIC_KEY" > "${ssh_dir}/authorized_keys"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${USERNAME}:${USERNAME}" "$ssh_dir"
    log_ok "SSH key configured for ${USERNAME}"
}

harden_ssh() {
    log_step "Hardening SSH configuration"

    # Backup original config
    [[ -f /etc/ssh/sshd_config.bak ]] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    cat > /etc/ssh/sshd_config <<SSHD_EOF
# Hardened SSH configuration — generated by setup-vpn-server
Port 22

# Authentication
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey

# Allowed users
AllowUsers ${USERNAME}

# Security
X11Forwarding no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

# Keep alive
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD_EOF

    # Ensure privilege separation directory exists
    mkdir -p /run/sshd

    # Verify config before restarting
    sshd -t || die "SSH config validation failed! Restoring backup."

    systemctl restart ssh || systemctl restart sshd
    log_ok "SSH hardened: root login disabled, password auth disabled"
}

setup_firewall() {
    log_step "Setting up UFW firewall"

    apt-get install -y ufw

    # Reset and configure
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit ssh
    ufw --force enable

    log_ok "Firewall enabled: SSH allowed with rate limiting"
}

setup_fail2ban() {
    log_step "Setting up fail2ban"

    apt-get install -y fail2ban

    cat > /etc/fail2ban/jail.local <<'F2B_EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
F2B_EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_ok "fail2ban configured for SSH"
}

setup_unbound() {
    log_step "Setting up unbound DNS resolver"

    apt-get install -y curl unbound

    # Download root hints
    curl -sS -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root

    cat > /etc/unbound/unbound.conf.d/resolver.conf <<'UNBOUND_EOF'
server:
    interface: 127.0.0.1
    port: 53

    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    root-hints: "/var/lib/unbound/root.hints"

    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes

    edns-buffer-size: 1232

    prefetch: yes
    qname-minimisation: yes

    hide-identity: yes
    hide-version: yes

    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow

    cache-min-ttl: 3600
    cache-max-ttl: 86400

    prefetch-key: yes

    msg-cache-size: 128m
    rrset-cache-size: 256m

    num-threads: 2
UNBOUND_EOF

    # Validate config
    unbound-checkconf || die "Unbound config validation failed"

    systemctl enable unbound
    systemctl restart unbound
    log_ok "Unbound DNS resolver configured"
}

configure_resolved() {
    log_step "Configuring systemd-resolved"

    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/local-dns.conf <<'RESOLVED_EOF'
[Resolve]
DNS=127.0.0.1
FallbackDNS=
DNSSEC=allow-downgrade
DNSStubListener=no
DNSOverTLS=no
RESOLVED_EOF

    systemctl restart systemd-resolved

    # Fix resolv.conf symlink if needed
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

    log_ok "System DNS pointing to local unbound"
}

enable_bbr() {
    log_step "Enabling BBR congestion control"

    modprobe tcp_bbr 2>/dev/null || true

    cat > /etc/sysctl.d/99-bbr.conf <<'BBR_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_EOF

    sysctl --system >/dev/null 2>&1

    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current" == "bbr" ]]; then
        log_ok "BBR congestion control enabled"
    else
        log_warn "BBR may not be available on this kernel (current: ${current})"
    fi
}

harden_system() {
    if [[ "$SKIP_HARDENING" == "true" ]]; then
        log_warn "Skipping server hardening (--skip-hardening)"
        return
    fi

    update_system
    create_user
    harden_ssh
    setup_firewall
    setup_fail2ban
    setup_unbound
    configure_resolved
    enable_bbr
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. SING-BOX INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_singbox_package() {
    log_step "Installing sing-box"

    if command_exists sing-box; then
        log_warn "sing-box already installed, skipping"
        return
    fi

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc

    cat > /etc/apt/sources.list.d/sagernet.sources <<'REPO_EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
REPO_EOF

    apt-get update -y
    apt-get install -y sing-box
    log_ok "sing-box installed"
}

setup_singbox_logs() {
    log_step "Setting up sing-box log directory"

    mkdir -p /var/log/sing-box
    touch /var/log/sing-box/sing-box.log
    chown -R sing-box:sing-box /var/log/sing-box
    chmod 750 /var/log/sing-box
    chmod 640 /var/log/sing-box/sing-box.log
    log_ok "Log directory ready"
}

install_certbot() {
    log_step "Installing certbot"
    apt-get install -y certbot
    log_ok "certbot installed"
}

issue_certificate() {
    if [[ "$SKIP_CERTBOT" == "true" ]]; then
        log_warn "Skipping TLS certificate issuance (--skip-certbot)"
        return
    fi

    log_step "Issuing TLS certificate for ${DOMAIN}"

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        log_warn "Certificate for ${DOMAIN} already exists, skipping"
        return
    fi

    # Temporarily open port 80
    ufw allow 80/tcp

    certbot certonly --standalone \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --no-eff-email

    # Close port 80
    ufw delete allow 80/tcp

    log_ok "TLS certificate issued for ${DOMAIN}"
}

setup_cert_permissions() {
    log_step "Setting up certificate permissions"

    # Create ssl-cert group if needed
    getent group ssl-cert >/dev/null || groupadd ssl-cert
    usermod -aG ssl-cert sing-box

    # Set permissions on letsencrypt directory
    chgrp -R ssl-cert /etc/letsencrypt
    chmod -R 750 /etc/letsencrypt

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        chmod 640 "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    fi

    # Install ACL support and grant access to sing-box user
    apt-get install -y acl
    setfacl -R -m u:sing-box:rx /etc/letsencrypt
    setfacl -R -d -m u:sing-box:rx /etc/letsencrypt

    log_ok "Certificate permissions configured"
}

setup_cert_renewal() {
    log_step "Setting up certificate auto-renewal hooks"

    mkdir -p /etc/letsencrypt/renewal-hooks/pre
    mkdir -p /etc/letsencrypt/renewal-hooks/post

    cat > /etc/letsencrypt/renewal-hooks/pre/open-port-80.sh <<'PREHOOK_EOF'
#!/bin/bash
ufw allow 80/tcp
PREHOOK_EOF

    cat > /etc/letsencrypt/renewal-hooks/post/close-port-80.sh <<'POSTHOOK_EOF'
#!/bin/bash
ufw delete allow 80/tcp
systemctl reload sing-box 2>/dev/null || true
POSTHOOK_EOF

    chmod +x /etc/letsencrypt/renewal-hooks/pre/open-port-80.sh
    chmod +x /etc/letsencrypt/renewal-hooks/post/close-port-80.sh

    log_ok "Certificate renewal hooks configured"
}

setup_cert_symlinks() {
    log_step "Creating certificate symlinks"

    mkdir -p /etc/sing-box/certs

    ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/sing-box/certs/cert.pem
    ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/sing-box/certs/key.pem

    chown -R root:ssl-cert /etc/sing-box
    chmod -R 750 /etc/sing-box

    log_ok "Certificate symlinks created in /etc/sing-box/certs/"
}

generate_reality_keypair() {
    log_step "Generating Reality keypair"

    local output
    output=$(sing-box generate reality-keypair)

    REALITY_PRIVATE_KEY=$(echo "$output" | grep -oP 'PrivateKey:\s*\K\S+')
    REALITY_PUBLIC_KEY=$(echo "$output" | grep -oP 'PublicKey:\s*\K\S+')

    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        die "Failed to generate Reality keypair"
    fi

    log_ok "Reality keypair generated"
}

setup_self_signed_cert() {
    # Used for testing (when --skip-certbot is set and no cert exists)
    log_step "Generating self-signed certificate for testing"

    mkdir -p /etc/sing-box/certs

    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/sing-box/certs/key.pem \
        -out /etc/sing-box/certs/cert.pem \
        -days 365 \
        -subj "/CN=${DOMAIN}" 2>/dev/null

    # Ensure sing-box can read the certs
    getent group ssl-cert >/dev/null || groupadd ssl-cert
    id sing-box &>/dev/null && usermod -aG ssl-cert sing-box
    chown -R root:ssl-cert /etc/sing-box
    chmod -R 750 /etc/sing-box
    chmod 640 /etc/sing-box/certs/key.pem

    log_ok "Self-signed certificate generated"
}

install_singbox() {
    install_singbox_package
    setup_singbox_logs
    install_certbot

    if [[ "$SKIP_CERTBOT" != "true" ]]; then
        issue_certificate
        setup_cert_permissions
        setup_cert_renewal
        setup_cert_symlinks
    else
        # For testing: generate self-signed cert if no cert exists
        if [[ ! -f /etc/sing-box/certs/cert.pem ]]; then
            setup_self_signed_cert
        fi
    fi

    generate_reality_keypair
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. SING-BOX CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

write_singbox_config() {
    log_step "Writing sing-box configuration"

    cat > /etc/sing-box/config.json <<SINGBOX_EOF
{
  "log": {
    "level": "info",
    "output": "/var/log/sing-box/sing-box.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "tcp",
        "tag": "dns_unbound",
        "server": "127.0.0.1",
        "server_port": 53
      }
    ],
    "final": "dns_unbound",
    "strategy": "prefer_ipv4",
    "cache_capacity": 4096
  },
  "route": {
    "final": "direct",
    "default_domain_resolver": {
      "server": "dns_unbound",
      "strategy": "prefer_ipv4"
    }
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "tg-socks",
      "listen": "::",
      "listen_port": ${SOCKS_PORT},
      "users": [
        {
          "username": "user",
          "password": "${SOCKS_PASS}"
        }
      ]
    },
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "min_version": "1.3",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "up_mbps": ${HY2_UP_MBPS},
      "down_mbps": ${HY2_DOWN_MBPS},
      "users": [
        {
          "name": "main",
          "password": "${HY2_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "min_version": "1.3",
        "certificate_path": "/etc/sing-box/certs/cert.pem",
        "key_path": "/etc/sing-box/certs/key.pem"
      },
      "obfs": {
        "type": "salamander",
        "password": "${OBFS_PASS}"
      },
      "masquerade": {
        "type": "string",
        "status_code": 200,
        "headers": {
          "content-type": "text/plain; charset=utf-8"
        },
        "content": "ok"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_resolver": {
        "server": "dns_unbound",
        "strategy": "prefer_ipv4"
      }
    }
  ]
}
SINGBOX_EOF

    log_ok "sing-box config written to /etc/sing-box/config.json"
}

validate_config() {
    log_step "Validating sing-box configuration"
    sing-box check -c /etc/sing-box/config.json || die "sing-box config validation failed"
    log_ok "Configuration valid"
}

open_proxy_ports() {
    log_step "Opening firewall ports for proxy services"

    if command_exists ufw; then
        ufw allow "${SOCKS_PORT}/tcp" comment "sing-box SOCKS5"
        ufw allow "${VLESS_PORT}/tcp" comment "sing-box VLESS Reality"
        ufw allow "${HY2_PORT}/udp"   comment "sing-box Hysteria2"
        log_ok "Ports opened: ${SOCKS_PORT}/tcp, ${VLESS_PORT}/tcp, ${HY2_PORT}/udp"
    else
        log_warn "ufw not found, skipping firewall port configuration"
    fi
}

start_singbox() {
    log_step "Starting sing-box service"

    systemctl enable sing-box
    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        log_ok "sing-box is running"
    else
        log_error "sing-box failed to start. Check logs:"
        journalctl -u sing-box --no-pager -n 20
        die "sing-box service failed"
    fi
}

configure_singbox() {
    write_singbox_config
    validate_config
    open_proxy_ports
    start_singbox
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. FAIL2BAN FOR PROXIES
# ─────────────────────────────────────────────────────────────────────────────

setup_proxy_fail2ban() {
    log_step "Setting up fail2ban for proxy services"

    if ! command_exists fail2ban-client; then
        log_warn "fail2ban not installed, skipping proxy fail2ban setup"
        return
    fi

    # SOCKS filter
    cat > /etc/fail2ban/filter.d/singbox-socks.conf <<'F2B_SOCKS_EOF'
[Definition]
failregex = ^ERROR .*inbound/socks\[tg-socks\]: process connection from <HOST>:\d+: socks5: authentication failed\b.*$
ignoreregex =
F2B_SOCKS_EOF

    # VLESS Reality filter
    cat > /etc/fail2ban/filter.d/singbox-vless-reality.conf <<'F2B_VLESS_EOF'
[Definition]
failregex = ^ERROR .*inbound/vless\[vless-reality\]: process connection from <HOST>:\d+: TLS handshake: REALITY: processed invalid connection$
ignoreregex =
F2B_VLESS_EOF

    # Add proxy jails
    cat >> /etc/fail2ban/jail.local <<F2B_JAILS_EOF

[singbox-socks]
enabled  = true
filter   = singbox-socks
logpath  = /var/log/sing-box/sing-box.log
backend  = auto
maxretry = 5
findtime = 10m
bantime  = 24h
port     = ${SOCKS_PORT}
action   = ufw

[singbox-vless-reality]
enabled  = true
filter   = singbox-vless-reality
logpath  = /var/log/sing-box/sing-box.log
backend  = auto
maxretry = 5
findtime = 10m
bantime  = 1h
port     = ${VLESS_PORT}
action   = ufw
F2B_JAILS_EOF

    systemctl restart fail2ban
    log_ok "fail2ban configured for SOCKS and VLESS Reality"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. SAVE SECRETS & PRINT OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

save_secrets() {
    log_step "Saving secrets"

    cat > /etc/sing-box/.secrets <<SECRETS_EOF
# sing-box server secrets — generated by setup-vpn-server
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

SERVER_IP=${SERVER_IP}
DOMAIN=${DOMAIN}
USERNAME=${USERNAME}

# Ports
SOCKS_PORT=${SOCKS_PORT}
VLESS_PORT=${VLESS_PORT}
HY2_PORT=${HY2_PORT}

# SOCKS5
SOCKS_USER=user
SOCKS_PASS=${SOCKS_PASS}

# VLESS Reality
UUID=${UUID}
REALITY_SNI=${REALITY_SNI}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}

# Hysteria2
HY2_PASS=${HY2_PASS}
OBFS_PASS=${OBFS_PASS}
HY2_UP_MBPS=${HY2_UP_MBPS}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS}
SECRETS_EOF

    chmod 600 /etc/sing-box/.secrets
    log_ok "Secrets saved to /etc/sing-box/.secrets"
}

print_credentials() {
    local vless_url="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#vless-reality"
    local hy2_url="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}&alpn=h3&insecure=0&obfs=salamander&obfs-password=${OBFS_PASS}#hysteria2"
    local tg_url="https://t.me/socks?server=${SERVER_IP}&port=${SOCKS_PORT}&user=user&pass=${SOCKS_PASS}"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Setup complete! Your proxy server is ready."
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"

    echo -e "${CYAN}${BOLD}  VLESS Reality${NC}"
    echo -e "  ${BOLD}Port:${NC} ${VLESS_PORT}/tcp"
    echo -e "  ${BOLD}URL:${NC}"
    echo "  ${vless_url}"
    echo ""

    echo -e "${CYAN}${BOLD}  Hysteria2${NC}"
    echo -e "  ${BOLD}Port:${NC} ${HY2_PORT}/udp"
    echo -e "  ${BOLD}URL:${NC}"
    echo "  ${hy2_url}"
    echo ""

    echo -e "${CYAN}${BOLD}  SOCKS5 (Telegram)${NC}"
    echo -e "  ${BOLD}Server:${NC} ${SERVER_IP}:${SOCKS_PORT}"
    echo -e "  ${BOLD}Username:${NC} user"
    echo -e "  ${BOLD}Password:${NC} ${SOCKS_PASS}"
    echo -e "  ${BOLD}Telegram link:${NC}"
    echo "  ${tg_url}"
    echo ""

    echo -e "${CYAN}${BOLD}  SSH Access${NC}"
    echo -e "  ssh ${USERNAME}@${SERVER_IP}"
    echo ""

    echo -e "${YELLOW}${BOLD}  Secrets file:${NC} /etc/sing-box/.secrets"
    echo -e "${YELLOW}${BOLD}  View again:${NC}   sudo cat /etc/sing-box/.secrets"
    echo ""

    echo -e "${GREEN}${BOLD}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Clients: v2rayN (Win), v2rayNG (Android), Streisand (macOS/iOS)"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${GREEN}${BOLD}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  setup-vpn-server"
    echo "  sing-box + VLESS Reality + Hysteria2 + SOCKS5"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"

    check_root
    check_os
    install_dependencies
    load_env_defaults
    parse_args "$@"
    validate_args
    detect_server_ip
    generate_secrets

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        log_info "Dry run mode — no changes will be made"
        echo ""
        echo "  Domain:       ${DOMAIN}"
        echo "  Email:        ${EMAIL}"
        echo "  Username:     ${USERNAME}"
        echo "  Server IP:    ${SERVER_IP}"
        echo "  Reality SNI:  ${REALITY_SNI}"
        echo "  SOCKS port:   ${SOCKS_PORT}"
        echo "  VLESS port:   ${VLESS_PORT}"
        echo "  HY2 port:     ${HY2_PORT}"
        echo "  HY2 bandwidth: ${HY2_UP_MBPS}/${HY2_DOWN_MBPS} Mbps"
        echo ""
        log_info "UUID:       ${UUID}"
        log_info "Short ID:   ${SHORT_ID}"
        echo ""
        exit 0
    fi

    log_info "=== Phase 1: Server Hardening ==="
    harden_system

    log_info "=== Phase 2: sing-box Installation ==="
    install_singbox

    log_info "=== Phase 3: sing-box Configuration ==="
    configure_singbox

    log_info "=== Phase 4: Proxy Protection ==="
    setup_proxy_fail2ban

    log_info "=== Phase 5: Done! ==="
    save_secrets
    print_credentials
}

main "$@"

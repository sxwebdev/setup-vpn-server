#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# vpn-users.sh — sing-box user management (add/remove/list/urls/rebuild-config)
#
# Installed at /opt/vpn-admin/vpn-users.sh by setup.sh
# Requires: jq, sing-box, openssl, systemctl
# ═══════════════════════════════════════════════════════════════════════════════

SINGBOX_DIR="/etc/sing-box"
USERS_DIR="${SINGBOX_DIR}/users"
CONFIG_FILE="${SINGBOX_DIR}/config.json"
SECRETS_FILE="${SINGBOX_DIR}/.secrets"
LOCK_FILE="${SINGBOX_DIR}/.lock"

die() { echo "{\"error\": \"$*\"}" >&2; exit 1; }

# Validate username: lowercase alphanumeric, hyphens, underscores, 1-32 chars
validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
        die "Invalid username '${name}'. Use lowercase letters, digits, hyphens, underscores (1-32 chars, must start with letter or digit)"
    fi
}

generate_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local hex
        hex=$(openssl rand -hex 16)
        printf '%s-%s-4%s-%x%s-%s' \
            "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
            $(( 0x${hex:16:1} & 0x3 | 0x8 )) "${hex:17:3}" "${hex:20:12}"
    fi
}

load_secrets() {
    [[ -f "$SECRETS_FILE" ]] || die "Secrets file not found: ${SECRETS_FILE}"
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

cmd_add() {
    local name="${1:?Usage: vpn-users.sh add <username>}"
    validate_name "$name"

    local user_file="${USERS_DIR}/${name}.json"
    [[ ! -f "$user_file" ]] || die "User '${name}' already exists"

    local uuid socks_pass hy2_pass created
    uuid=$(generate_uuid)
    socks_pass=$(openssl rand -hex 32)
    hy2_pass=$(openssl rand -hex 32)
    created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq -n \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg socks_pass "$socks_pass" \
        --arg hy2_pass "$hy2_pass" \
        --arg created "$created" \
        '{
            name: $name,
            created: $created,
            vless_uuid: $uuid,
            socks_password: $socks_pass,
            hy2_password: $hy2_pass
        }' > "$user_file"

    chmod 600 "$user_file"

    rebuild_config

    # Output user info + server params for URL construction
    output_user_with_server "$name"
}

cmd_remove() {
    local name="${1:?Usage: vpn-users.sh remove <username>}"
    validate_name "$name"

    local user_file="${USERS_DIR}/${name}.json"
    [[ -f "$user_file" ]] || die "User '${name}' not found"

    # Prevent removing the last user
    local count
    count=$(find "$USERS_DIR" -name '*.json' -type f | wc -l)
    if [[ "$count" -le 1 ]]; then
        die "Cannot remove the last user. At least one user must exist."
    fi

    rm -f "$user_file"
    rebuild_config

    echo '{"ok": true}'
}

cmd_list() {
    if [[ ! -d "$USERS_DIR" ]] || ! compgen -G "${USERS_DIR}/*.json" > /dev/null 2>&1; then
        echo '[]'
        return
    fi

    jq -s '[.[] | {name, created}]' "${USERS_DIR}"/*.json
}

cmd_show() {
    local name="${1:?Usage: vpn-users.sh show <username>}"
    validate_name "$name"

    local user_file="${USERS_DIR}/${name}.json"
    [[ -f "$user_file" ]] || die "User '${name}' not found"

    output_user_with_server "$name"
}

cmd_urls() {
    local name="${1:?Usage: vpn-users.sh urls <username>}"
    validate_name "$name"

    local user_file="${USERS_DIR}/${name}.json"
    [[ -f "$user_file" ]] || die "User '${name}' not found"

    load_secrets

    local uuid socks_pass hy2_pass
    uuid=$(jq -r '.vless_uuid' "$user_file")
    socks_pass=$(jq -r '.socks_password' "$user_file")
    hy2_pass=$(jq -r '.hy2_password' "$user_file")

    local vless_url="vless://${uuid}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${name}-vless"
    local hy2_url="hysteria2://${hy2_pass}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}&alpn=h3&insecure=0&obfs=salamander&obfs-password=${OBFS_PASS}#${name}-hy2"
    local tg_url="https://t.me/socks?server=${SERVER_IP}&port=${SOCKS_PORT}&user=${name}&pass=${socks_pass}"

    jq -n \
        --arg vless "$vless_url" \
        --arg hy2 "$hy2_url" \
        --arg tg "$tg_url" \
        '{vless: $vless, hysteria2: $hy2, telegram_socks: $tg}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Config rebuild
# ─────────────────────────────────────────────────────────────────────────────

rebuild_config() {
    # Acquire lock to prevent concurrent modifications
    exec 200>"$LOCK_FILE"
    flock -w 30 200 || die "Could not acquire lock"

    if ! compgen -G "${USERS_DIR}/*.json" > /dev/null 2>&1; then
        die "No users found. Cannot rebuild config with empty user list."
    fi

    # Build user arrays from individual user files
    local vless_users hy2_users socks_users
    vless_users=$(jq -s '[.[] | {uuid: .vless_uuid, flow: "xtls-rprx-vision"}]' "${USERS_DIR}"/*.json)
    hy2_users=$(jq -s '[.[] | {name: .name, password: .hy2_password}]' "${USERS_DIR}"/*.json)
    socks_users=$(jq -s '[.[] | {username: .name, password: .socks_password}]' "${USERS_DIR}"/*.json)

    # Backup current config
    cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # Update users arrays in each inbound
    jq --argjson vless "$vless_users" \
       --argjson hy2 "$hy2_users" \
       --argjson socks "$socks_users" \
       '(.inbounds[] | select(.tag == "vless-reality") | .users) = $vless |
        (.inbounds[] | select(.tag == "hy2-in") | .users) = $hy2 |
        (.inbounds[] | select(.tag == "tg-socks") | .users) = $socks' \
       "${CONFIG_FILE}.bak" > "${CONFIG_FILE}.new"

    # Validate new config
    if ! sing-box check -c "${CONFIG_FILE}.new" 2>/dev/null; then
        rm -f "${CONFIG_FILE}.new"
        die "Config validation failed. Keeping old config."
    fi

    # Atomically replace config
    mv -f "${CONFIG_FILE}.new" "$CONFIG_FILE"

    # Restart sing-box
    systemctl restart sing-box 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

output_user_with_server() {
    local name="$1"
    local user_file="${USERS_DIR}/${name}.json"

    load_secrets

    local user_json
    user_json=$(cat "$user_file")

    jq -n \
        --argjson user "$user_json" \
        --arg domain "$DOMAIN" \
        --arg server_ip "$SERVER_IP" \
        --arg vless_port "$VLESS_PORT" \
        --arg hy2_port "$HY2_PORT" \
        --arg socks_port "$SOCKS_PORT" \
        --arg reality_sni "$REALITY_SNI" \
        --arg reality_pub "$REALITY_PUBLIC_KEY" \
        --arg short_id "$SHORT_ID" \
        --arg obfs_pass "$OBFS_PASS" \
        '{
            user: $user,
            server: {
                domain: $domain,
                server_ip: $server_ip,
                vless_port: ($vless_port | tonumber),
                hy2_port: ($hy2_port | tonumber),
                socks_port: ($socks_port | tonumber),
                reality_sni: $reality_sni,
                reality_public_key: $reality_pub,
                short_id: $short_id,
                obfs_password: $obfs_pass
            }
        }'
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
    add)    cmd_add "${2:-}" ;;
    remove) cmd_remove "${2:-}" ;;
    list)   cmd_list ;;
    show)   cmd_show "${2:-}" ;;
    urls)   cmd_urls "${2:-}" ;;
    rebuild-config) rebuild_config; echo '{"ok": true}' ;;
    *)
        echo "Usage: vpn-users.sh {add|remove|list|show|urls|rebuild-config} [username]" >&2
        exit 1
        ;;
esac

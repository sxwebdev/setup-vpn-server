#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# test.sh — Test setup-vpn-server in a Docker container
#
# Usage:
#   ./test.sh           # Run full integration test
#   ./test.sh syntax    # Run syntax check only
#   ./test.sh clean     # Remove test container and image
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONTAINER_NAME="vpn-test"
TEST_DOMAIN="test.local"
TEST_EMAIL="test@test.local"
TEST_USERNAME="testuser"
TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForDockerTestingOnly000000000000000 test@local"

log_info()  { echo -e "${CYAN}[TEST]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

TESTS_PASSED=0
TESTS_FAILED=0

assert() {
    local description="$1"
    shift
    if "$@" 2>/dev/null; then
        log_ok "$description"
        ((TESTS_PASSED++))
    else
        log_fail "$description"
        ((TESTS_FAILED++))
    fi
}

assert_output_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -q "$expected"; then
        log_ok "$description"
        ((TESTS_PASSED++))
    else
        log_fail "$description (expected: $expected)"
        ((TESTS_FAILED++))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

syntax_test() {
    log_info "Running syntax checks..."

    # Bash syntax check
    assert "setup.sh has valid bash syntax" bash -n setup.sh

    # Check shellcheck if available
    if command -v shellcheck &>/dev/null; then
        assert "setup.sh passes shellcheck" shellcheck -S warning setup.sh
    else
        log_warn "shellcheck not installed, skipping"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

integration_test() {
    log_info "Building Docker image..."
    docker compose build --quiet

    log_info "Starting container with systemd..."
    docker compose up -d

    # Wait for systemd to initialize
    log_info "Waiting for systemd to initialize..."
    sleep 5

    # Verify systemd is running
    assert "systemd is running in container" \
        docker exec "$CONTAINER_NAME" systemctl is-system-running --wait 2>/dev/null || \
        docker exec "$CONTAINER_NAME" test -d /run/systemd/system

    log_info "Running setup.sh inside container (this may take a few minutes)..."
    local setup_output
    setup_output=$(docker exec "$CONTAINER_NAME" bash /root/setup.sh \
        --domain "$TEST_DOMAIN" \
        --email "$TEST_EMAIL" \
        --username "$TEST_USERNAME" \
        --ssh-key "$TEST_SSH_KEY" \
        --skip-certbot \
        --skip-hardening 2>&1) || true

    echo "$setup_output" | tail -50

    log_info "Running assertions..."

    # Check sing-box is installed
    assert "sing-box is installed" \
        docker exec "$CONTAINER_NAME" which sing-box

    # Check sing-box config exists and is valid
    assert "sing-box config exists" \
        docker exec "$CONTAINER_NAME" test -f /etc/sing-box/config.json

    assert "sing-box config is valid" \
        docker exec "$CONTAINER_NAME" sing-box check -c /etc/sing-box/config.json

    # Check sing-box service
    assert "sing-box service is active" \
        docker exec "$CONTAINER_NAME" systemctl is-active --quiet sing-box

    # Check secrets file
    assert "secrets file exists" \
        docker exec "$CONTAINER_NAME" test -f /etc/sing-box/.secrets

    assert "secrets file has correct permissions (600)" \
        docker exec "$CONTAINER_NAME" test "$(docker exec "$CONTAINER_NAME" stat -c '%a' /etc/sing-box/.secrets)" = "600"

    # Check secrets file content
    local secrets
    secrets=$(docker exec "$CONTAINER_NAME" cat /etc/sing-box/.secrets)

    assert_output_contains "secrets contains SERVER_IP" "$secrets" "SERVER_IP="
    assert_output_contains "secrets contains UUID" "$secrets" "UUID="
    assert_output_contains "secrets contains REALITY_PUBLIC_KEY" "$secrets" "REALITY_PUBLIC_KEY="
    assert_output_contains "secrets contains REALITY_PRIVATE_KEY" "$secrets" "REALITY_PRIVATE_KEY="
    assert_output_contains "secrets contains SOCKS_PASS" "$secrets" "SOCKS_PASS="
    assert_output_contains "secrets contains HY2_PASS" "$secrets" "HY2_PASS="
    assert_output_contains "secrets contains OBFS_PASS" "$secrets" "OBFS_PASS="

    # Check self-signed cert was created
    assert "self-signed cert exists" \
        docker exec "$CONTAINER_NAME" test -f /etc/sing-box/certs/cert.pem

    assert "self-signed key exists" \
        docker exec "$CONTAINER_NAME" test -f /etc/sing-box/certs/key.pem

    # Check log directory
    assert "log directory exists" \
        docker exec "$CONTAINER_NAME" test -d /var/log/sing-box

    # Check output contains client URLs
    assert_output_contains "output contains VLESS URL" "$setup_output" "vless://"
    assert_output_contains "output contains Hysteria2 URL" "$setup_output" "hysteria2://"
    assert_output_contains "output contains Telegram link" "$setup_output" "t.me/socks"

    # Check ports are listening
    local listening
    listening=$(docker exec "$CONTAINER_NAME" ss -tulpn 2>/dev/null) || true

    assert_output_contains "SOCKS port 1081 is listening" "$listening" ":1081"
    assert_output_contains "VLESS port 10443 is listening" "$listening" ":10443"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "  Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "  Tests failed: ${RED}${TESTS_FAILED}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo ""
        log_warn "Some tests failed. Check container logs:"
        echo "  docker exec $CONTAINER_NAME journalctl -u sing-box --no-pager -n 30"
        echo "  docker exec $CONTAINER_NAME cat /etc/sing-box/config.json"
        echo "  docker exec $CONTAINER_NAME cat /etc/sing-box/.secrets"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    log_info "Cleaning up..."
    docker compose down -v --rmi local 2>/dev/null || true
    log_ok "Cleanup complete"
}

# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
    syntax)
        syntax_test
        ;;
    clean)
        cleanup
        ;;
    *)
        syntax_test
        echo ""
        integration_test
        echo ""
        log_info "Run './test.sh clean' to remove the test container"
        ;;
esac

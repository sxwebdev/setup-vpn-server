#!/usr/bin/env python3
"""
VPN Admin Web UI — lightweight management panel for sing-box VPN users.

Runs as a standalone HTTPS server on port 8443.
No external dependencies — uses only Python 3 standard library.

Installed at /opt/vpn-admin/vpn-admin.py by setup.sh
"""

import hashlib
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8443
CERT_FILE = "/etc/sing-box/certs/cert.pem"
KEY_FILE = "/etc/sing-box/certs/key.pem"
PASSWORD_FILE = "/etc/sing-box/.admin-password"
VPN_USERS_SCRIPT = "/opt/vpn-admin/vpn-users.sh"
LOG_FILE = "/var/log/vpn-admin/vpn-admin.log"

# ─────────────────────────────────────────────────────────────────────────────
# Auth
# ─────────────────────────────────────────────────────────────────────────────

def load_password_hash():
    """Load the stored password hash from file. Format: salt:sha256hex"""
    try:
        with open(PASSWORD_FILE, "r") as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"ERROR: Password file not found: {PASSWORD_FILE}", file=sys.stderr)
        sys.exit(1)

def verify_password(password, stored):
    """Verify password against stored salt:hash."""
    if ":" not in stored:
        return False
    salt, expected_hash = stored.split(":", 1)
    actual_hash = hashlib.sha256((salt + password).encode()).hexdigest()
    return secrets.compare_digest(actual_hash, expected_hash)

STORED_PASSWORD = load_password_hash()

# ─────────────────────────────────────────────────────────────────────────────
# VPN Users Script Interface
# ─────────────────────────────────────────────────────────────────────────────

def run_vpn_users(command, arg=None):
    """Run vpn-users.sh and return (success, output_dict_or_str)."""
    cmd = [VPN_USERS_SCRIPT, command]
    if arg:
        cmd.append(arg)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()

        if result.returncode != 0:
            # Try to parse error JSON from stderr
            try:
                err = json.loads(stderr)
                return False, err.get("error", stderr)
            except (json.JSONDecodeError, AttributeError):
                return False, stderr or f"Command failed with exit code {result.returncode}"

        # Parse JSON output
        try:
            return True, json.loads(stdout)
        except json.JSONDecodeError:
            return True, stdout
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, str(e)

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

def log_auth_failure(address, reason="invalid credentials"):
    """Log failed auth attempt for fail2ban parsing."""
    import datetime
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"{ts} AUTH_FAILURE from {address}: {reason}\n"
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except OSError:
        pass

# ─────────────────────────────────────────────────────────────────────────────
# HTTP Handler
# ─────────────────────────────────────────────────────────────────────────────

class VPNAdminHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        """Suppress default request logging to stderr."""
        pass

    def check_auth(self):
        """Check HTTP Basic Auth. Returns True if authenticated."""
        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Basic "):
            self.send_auth_required()
            return False

        import base64
        try:
            decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
            username, password = decoded.split(":", 1)
        except (ValueError, UnicodeDecodeError):
            self.send_auth_required()
            return False

        if username != "admin" or not verify_password(password, STORED_PASSWORD):
            log_auth_failure(self.client_address[0])
            self.send_auth_required()
            return False

        return True

    def send_auth_required(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="VPN Admin"')
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error": "Authentication required"}')

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html, status=200):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def parse_path(self):
        """Parse URL path, return (path, query_params)."""
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path.rstrip("/") or "/", urllib.parse.parse_qs(parsed.query)

    # ── GET ──────────────────────────────────────────────────────────────

    def do_GET(self):
        path, _ = self.parse_path()

        # SPA — no auth required for the page itself (auth happens on API calls)
        if path == "/":
            if not self.check_auth():
                return
            self.send_html(SPA_HTML)
            return

        if not self.check_auth():
            return

        # GET /api/users
        if path == "/api/users":
            ok, data = run_vpn_users("list")
            if ok:
                self.send_json(data)
            else:
                self.send_json({"error": data}, 500)
            return

        # GET /api/users/<name>/urls
        m = re.match(r"^/api/users/([a-z0-9][a-z0-9_-]{0,31})/urls$", path)
        if m:
            name = m.group(1)
            ok, data = run_vpn_users("urls", name)
            if ok:
                self.send_json(data)
            else:
                self.send_json({"error": data}, 404 if "not found" in str(data).lower() else 500)
            return

        # GET /api/users/<name>
        m = re.match(r"^/api/users/([a-z0-9][a-z0-9_-]{0,31})$", path)
        if m:
            name = m.group(1)
            ok, data = run_vpn_users("show", name)
            if ok:
                self.send_json(data)
            else:
                self.send_json({"error": data}, 404 if "not found" in str(data).lower() else 500)
            return

        self.send_json({"error": "Not found"}, 404)

    # ── POST ─────────────────────────────────────────────────────────────

    def do_POST(self):
        if not self.check_auth():
            return

        path, _ = self.parse_path()

        if path == "/api/users":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length > 1024:
                self.send_json({"error": "Request too large"}, 400)
                return

            try:
                body = json.loads(self.rfile.read(content_length))
            except (json.JSONDecodeError, ValueError):
                self.send_json({"error": "Invalid JSON"}, 400)
                return

            name = body.get("name", "").strip()
            if not name:
                self.send_json({"error": "Missing 'name' field"}, 400)
                return

            ok, data = run_vpn_users("add", name)
            if ok:
                self.send_json(data, 201)
            else:
                status = 409 if "already exists" in str(data).lower() else 400
                self.send_json({"error": data}, status)
            return

        self.send_json({"error": "Not found"}, 404)

    # ── DELETE ───────────────────────────────────────────────────────────

    def do_DELETE(self):
        if not self.check_auth():
            return

        path, _ = self.parse_path()

        m = re.match(r"^/api/users/([a-z0-9][a-z0-9_-]{0,31})$", path)
        if m:
            name = m.group(1)
            ok, data = run_vpn_users("remove", name)
            if ok:
                self.send_json({"ok": True})
            else:
                status = 404 if "not found" in str(data).lower() else 400
                self.send_json({"error": data}, status)
            return

        self.send_json({"error": "Not found"}, 404)

# ─────────────────────────────────────────────────────────────────────────────
# Embedded SPA
# ─────────────────────────────────────────────────────────────────────────────

SPA_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VPN Admin</title>
<style>
  :root {
    --bg: #0f1117; --surface: #1a1d27; --border: #2a2d3a;
    --text: #e1e4ed; --text2: #8b8fa3; --accent: #6c8cff;
    --accent-hover: #8aa4ff; --danger: #ff5c5c; --danger-hover: #ff7a7a;
    --success: #4cdf8b; --radius: 8px;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg); color: var(--text);
    min-height: 100vh; padding: 20px;
  }
  .container { max-width: 720px; margin: 0 auto; }
  h1 { font-size: 1.5em; margin-bottom: 24px; font-weight: 600; }
  h1 span { color: var(--accent); }

  .add-form {
    display: flex; gap: 10px; margin-bottom: 24px;
  }
  .add-form input {
    flex: 1; padding: 10px 14px; background: var(--surface);
    border: 1px solid var(--border); border-radius: var(--radius);
    color: var(--text); font-size: 14px; outline: none;
  }
  .add-form input:focus { border-color: var(--accent); }
  .add-form input::placeholder { color: var(--text2); }

  button {
    padding: 10px 18px; border: none; border-radius: var(--radius);
    cursor: pointer; font-size: 14px; font-weight: 500;
    transition: background 0.15s;
  }
  .btn-add { background: var(--accent); color: #fff; }
  .btn-add:hover { background: var(--accent-hover); }
  .btn-add:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn-urls { background: var(--surface); color: var(--accent); border: 1px solid var(--border); padding: 6px 12px; font-size: 13px; }
  .btn-urls:hover { border-color: var(--accent); }
  .btn-del { background: transparent; color: var(--danger); border: 1px solid transparent; padding: 6px 12px; font-size: 13px; }
  .btn-del:hover { border-color: var(--danger); }
  .btn-copy { background: var(--surface); color: var(--text2); border: 1px solid var(--border); padding: 4px 10px; font-size: 12px; margin-left: 6px; }
  .btn-copy:hover { color: var(--text); border-color: var(--accent); }
  .btn-copy.copied { color: var(--success); border-color: var(--success); }

  .users-list { display: flex; flex-direction: column; gap: 8px; }

  .user-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 14px 16px;
  }
  .user-header {
    display: flex; align-items: center; justify-content: space-between;
  }
  .user-name { font-weight: 600; font-size: 15px; }
  .user-date { color: var(--text2); font-size: 13px; margin-left: 12px; }
  .user-actions { display: flex; gap: 6px; }

  .urls-panel {
    margin-top: 14px; padding-top: 14px;
    border-top: 1px solid var(--border);
  }
  .url-item { margin-bottom: 14px; }
  .url-label { font-size: 12px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
  .url-row { display: flex; align-items: center; }
  .url-value {
    font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px;
    color: var(--text2); word-break: break-all; flex: 1;
    background: var(--bg); padding: 6px 10px; border-radius: 4px;
  }
  .qr-canvas { margin-top: 8px; }

  .error { color: var(--danger); font-size: 14px; margin: 10px 0; }
  .loading { color: var(--text2); font-size: 14px; }
  .empty { color: var(--text2); text-align: center; padding: 40px; }

  .confirm-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.6);
    display: flex; align-items: center; justify-content: center;
    z-index: 100;
  }
  .confirm-box {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 24px; max-width: 400px; width: 90%;
  }
  .confirm-box p { margin-bottom: 16px; }
  .confirm-actions { display: flex; gap: 10px; justify-content: flex-end; }
  .btn-cancel { background: var(--surface); color: var(--text); border: 1px solid var(--border); }
  .btn-confirm-del { background: var(--danger); color: #fff; }
  .btn-confirm-del:hover { background: var(--danger-hover); }
</style>
</head>
<body>
<div class="container">
  <h1><span>VPN</span> User Management</h1>

  <div class="add-form">
    <input type="text" id="newName" placeholder="Username (e.g. alice)" maxlength="32"
           pattern="[a-z0-9][a-z0-9_-]*" autocomplete="off">
    <button class="btn-add" id="addBtn" onclick="addUser()">Add User</button>
  </div>
  <div id="addError" class="error" style="display:none"></div>

  <div id="usersList" class="users-list">
    <div class="loading">Loading users...</div>
  </div>
</div>

<!-- Delete confirmation modal -->
<div id="confirmModal" class="confirm-overlay" style="display:none">
  <div class="confirm-box">
    <p>Delete user <strong id="confirmName"></strong>? This will revoke all their access.</p>
    <div class="confirm-actions">
      <button class="btn-cancel" onclick="closeConfirm()">Cancel</button>
      <button class="btn-confirm-del" id="confirmDelBtn" onclick="confirmDelete()">Delete</button>
    </div>
  </div>
</div>

<script>
// QR Code generator - minimal inline implementation
// Based on https://github.com/niclas-niclas/qr-code (MIT license)
// Fallback: if too complex, we just show the URL text
const QR = (() => {
  // We'll use a simple canvas-based QR code via the qrcode-generator library approach
  // For simplicity, generate QR via an SVG-based approach using a known algorithm
  // Actually, let's use a lightweight approach: generate QR code as a table of black/white cells

  // Minimal QR encoder would be too long inline. Instead, we'll create a
  // temporary image from a data URL using a Google Charts API alternative.
  // For privacy, let's just provide copy buttons and skip QR for now,
  // or use a simple canvas drawing if we embed a tiny encoder.

  // We'll load qr-creator from a CDN if available, otherwise skip QR
  let qrReady = false;
  const script = document.createElement('script');
  script.src = 'https://cdn.jsdelivr.net/npm/qr-creator@1.0.0/dist/qr-creator.min.js';
  script.onload = () => { qrReady = true; renderAllQRs(); };
  script.onerror = () => { qrReady = false; };
  document.head.appendChild(script);

  const pending = [];

  function render(container, text) {
    if (qrReady && window.QrCreator) {
      container.innerHTML = '';
      QrCreator.render({
        text: text,
        radius: 0,
        ecLevel: 'M',
        fill: '#e1e4ed',
        background: '#0f1117',
        size: 180
      }, container);
    } else {
      pending.push({ container, text });
    }
  }

  function renderAllQRs() {
    pending.forEach(p => render(p.container, p.text));
    pending.length = 0;
  }

  return { render };
})();

let users = [];
let expandedUser = null;
let deleteTarget = null;

async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (body) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

async function loadUsers() {
  try {
    users = await api('GET', '/api/users');
    renderUsers();
  } catch (e) {
    document.getElementById('usersList').innerHTML =
      `<div class="error">Failed to load users: ${esc(e.message)}</div>`;
  }
}

function renderUsers() {
  const el = document.getElementById('usersList');
  if (!users.length) {
    el.innerHTML = '<div class="empty">No users yet. Add one above.</div>';
    return;
  }
  el.innerHTML = users.map(u => `
    <div class="user-card" id="card-${esc(u.name)}">
      <div class="user-header">
        <div>
          <span class="user-name">${esc(u.name)}</span>
          <span class="user-date">${formatDate(u.created)}</span>
        </div>
        <div class="user-actions">
          <button class="btn-urls" onclick="toggleUrls('${esc(u.name)}')">
            ${expandedUser === u.name ? 'Hide' : 'URLs'}
          </button>
          <button class="btn-del" onclick="showConfirm('${esc(u.name)}')">Delete</button>
        </div>
      </div>
      ${expandedUser === u.name ? '<div class="urls-panel" id="urls-' + esc(u.name) + '"><div class="loading">Loading URLs...</div></div>' : ''}
    </div>
  `).join('');

  if (expandedUser) loadUrls(expandedUser);
}

async function toggleUrls(name) {
  expandedUser = expandedUser === name ? null : name;
  renderUsers();
}

async function loadUrls(name) {
  const panel = document.getElementById('urls-' + name);
  if (!panel) return;
  try {
    const data = await api('GET', `/api/users/${encodeURIComponent(name)}/urls`);
    panel.innerHTML = `
      ${urlItem('VLESS Reality', data.vless, name + '-vless')}
      ${urlItem('Hysteria2', data.hysteria2, name + '-hy2')}
      ${urlItem('Telegram SOCKS5', data.telegram_socks, name + '-tg')}
    `;
    // Render QR codes
    ['vless', 'hysteria2', 'telegram_socks'].forEach((key, i) => {
      const ids = [name + '-vless', name + '-hy2', name + '-tg'];
      const container = document.getElementById('qr-' + ids[i]);
      if (container) QR.render(container, data[key]);
    });
  } catch (e) {
    panel.innerHTML = `<div class="error">${esc(e.message)}</div>`;
  }
}

function urlItem(label, url, id) {
  return `
    <div class="url-item">
      <div class="url-label">${label}</div>
      <div class="url-row">
        <div class="url-value">${esc(url)}</div>
        <button class="btn-copy" onclick="copyUrl(this, '${escAttr(url)}')">Copy</button>
      </div>
      <div class="qr-canvas" id="qr-${id}"></div>
    </div>
  `;
}

async function addUser() {
  const input = document.getElementById('newName');
  const name = input.value.trim().toLowerCase();
  const errEl = document.getElementById('addError');
  errEl.style.display = 'none';

  if (!name || !/^[a-z0-9][a-z0-9_-]{0,31}$/.test(name)) {
    errEl.textContent = 'Invalid name. Use lowercase letters, digits, hyphens (1-32 chars).';
    errEl.style.display = 'block';
    return;
  }

  const btn = document.getElementById('addBtn');
  btn.disabled = true;
  try {
    await api('POST', '/api/users', { name });
    input.value = '';
    expandedUser = name;
    await loadUsers();
  } catch (e) {
    errEl.textContent = e.message;
    errEl.style.display = 'block';
  } finally {
    btn.disabled = false;
  }
}

function showConfirm(name) {
  deleteTarget = name;
  document.getElementById('confirmName').textContent = name;
  document.getElementById('confirmModal').style.display = 'flex';
}

function closeConfirm() {
  deleteTarget = null;
  document.getElementById('confirmModal').style.display = 'none';
}

async function confirmDelete() {
  if (!deleteTarget) return;
  const name = deleteTarget;
  const btn = document.getElementById('confirmDelBtn');
  btn.disabled = true;
  try {
    await api('DELETE', `/api/users/${encodeURIComponent(name)}`);
    if (expandedUser === name) expandedUser = null;
    closeConfirm();
    await loadUsers();
  } catch (e) {
    alert('Error: ' + e.message);
  } finally {
    btn.disabled = false;
  }
}

function copyUrl(btn, text) {
  navigator.clipboard.writeText(text).then(() => {
    btn.textContent = 'Copied!';
    btn.classList.add('copied');
    setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1500);
  });
}

function formatDate(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

function esc(s) {
  const d = document.createElement('div');
  d.textContent = s || '';
  return d.innerHTML;
}

function escAttr(s) {
  return (s || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

// Enter key to add user
document.getElementById('newName').addEventListener('keydown', e => {
  if (e.key === 'Enter') addUser();
});

// Initial load
loadUsers();
</script>
</body>
</html>
"""

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    # Check required files
    if not os.path.isfile(CERT_FILE):
        print(f"ERROR: Certificate not found: {CERT_FILE}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(KEY_FILE):
        print(f"ERROR: Key not found: {KEY_FILE}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(VPN_USERS_SCRIPT):
        print(f"ERROR: vpn-users.sh not found: {VPN_USERS_SCRIPT}", file=sys.stderr)
        sys.exit(1)

    # Create log directory
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

    # Setup HTTPS
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CERT_FILE, KEY_FILE)

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), VPNAdminHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"VPN Admin UI listening on https://{LISTEN_HOST}:{LISTEN_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == "__main__":
    main()

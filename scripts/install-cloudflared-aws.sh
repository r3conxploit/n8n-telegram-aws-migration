#!/usr/bin/env bash
# =============================================================================
# install-cloudflared-aws.sh — connector Cloudflare Tunnel di EC2 (amd64/arm64)
#
#   TUNNEL_ID=<uuid> DOMAIN=n8n.example.com bash ~/aws/install-cloudflared-aws.sh
#
# Prasyarat: credential tunnel sudah ada di ~/aws/<TUNNEL_ID>.json (0600).
# Hasil: /etc/cloudflared/config.yml + service systemd `cloudflared` enabled.
# Prinsip: ingress hanya 1 hostname, sisanya http_status:404 (default deny).
# =============================================================================
set -euo pipefail

TUNNEL_ID="${TUNNEL_ID:?TUNNEL_ID wajib (UUID tunnel Cloudflare)}"
DOMAIN="${DOMAIN:?DOMAIN wajib (mis. n8n.example.com)}"
CRED_SRC="${CRED_SRC:-$HOME/aws/${TUNNEL_ID}.json}"
CRED_DST="/etc/cloudflared/${TUNNEL_ID}.json"
ORIGIN="${ORIGIN:-http://127.0.0.1:5678}"

[ -f "$CRED_SRC" ] || { echo "ERROR: credential tidak ada: $CRED_SRC"; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) PKG="cloudflared-linux-amd64.deb" ;;
  aarch64|arm64) PKG="cloudflared-linux-arm64.deb" ;;
  *) echo "ERROR: arsitektur tidak didukung: $ARCH"; exit 1 ;;
esac

echo "=== [1/4] install cloudflared ($ARCH) ==="
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/${PKG}"
  sudo dpkg -i /tmp/cloudflared.deb
fi
cloudflared --version

echo "=== [2/4] credential (0600 root, tidak pernah world-readable) ==="
sudo mkdir -p /etc/cloudflared
sudo install -m 600 -o root -g root "$CRED_SRC" "$CRED_DST"

echo "=== [3/4] config.yml ==="
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_DST}
no-autoupdate: true

ingress:
  - hostname: ${DOMAIN}
    service: ${ORIGIN}
  - service: http_status:404
EOF
sudo chmod 600 /etc/cloudflared/config.yml
sudo cat /etc/cloudflared/config.yml

echo "=== [4/4] systemd ==="
sudo cloudflared service install 2>/dev/null || echo "(service sudah terpasang)"
sudo systemctl enable --now cloudflared
sleep 8
sudo systemctl --no-pager --full status cloudflared | head -12 || true

echo
echo "Tes: curl -s -o /dev/null -w '%{http_code}\\n' https://${DOMAIN}/healthz"
echo "Kalau 502: origin 200 tapi ingress rusak -> docs/troubleshooting.md T6"

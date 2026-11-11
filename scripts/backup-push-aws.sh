#!/usr/bin/env bash
# =============================================================================
# backup-push-aws.sh — workstation -> EC2, jalur MANUAL (tanpa orkestrator)
#
#   bash scripts/backup-push-aws.sh ubuntu@<host>   # atau <host> (default user ubuntu)
#
# Dipakai kalau hanya ingin mengirim state & skrip, lalu menjalankannya sendiri
# di server. Untuk migrasi penuh pakai deploy.sh.
# =============================================================================
set -euo pipefail

VM="${1:-}"
[ -z "$VM" ] && { echo "Pakai: bash backup-push-aws.sh <user@host|host>"; exit 1; }
case "$VM" in *@*) TARGET="$VM" ;; *) TARGET="ubuntu@$VM" ;; esac

KEY="${KEY:-$HOME/.ssh/id_ed25519}"
TUNNEL_HOME="${TUNNEL_HOME:-$HOME/.cloudflared}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="n8n-data.tar.gz"

echo "=== [1/5] pastikan n8n lokal MATI ==="
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:5678/healthz || true)
[ "$code" = "200" ] && { echo "ERROR: n8n lokal masih hidup (healthz=200). Matikan dulu."; exit 1; }
echo "  healthz=${code} -> aman"

echo "=== [2/5] cek file wajib ==="
[ -f "$HOME/.n8n/database.sqlite" ] || { echo "ERROR: database.sqlite tidak ada"; exit 1; }
[ -f "$HOME/.n8n/config" ] || { echo "ERROR: config (encryption key) tidak ada"; exit 1; }
TUNNEL_ID="${TUNNEL_ID:-}"
if [ -z "$TUNNEL_ID" ]; then
  TUNNEL_ID="$(ls "$TUNNEL_HOME"/*.json 2>/dev/null | head -1 | xargs -r basename | sed 's/\.json$//')"
fi
[ -n "$TUNNEL_ID" ] && [ -f "$TUNNEL_HOME/$TUNNEL_ID.json" ] || { echo "ERROR: credential tunnel tidak ditemukan"; exit 1; }
echo "  sqlite $(du -h "$HOME/.n8n/database.sqlite" | cut -f1) | config ada | tunnel $TUNNEL_ID"

echo "=== [3/5] arsip ==="
tar -czf "$OUT" -C "$HOME" .n8n
echo "  $(du -h "$OUT" | cut -f1)"

echo "=== [4/5] kirim ke $TARGET ==="
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$TARGET" 'mkdir -p ~/aws'
scp -i "$KEY" "$OUT" "$TARGET:~/aws/"
ssh -i "$KEY" "$TARGET" "cat > aws/$TUNNEL_ID.json && chmod 600 aws/$TUNNEL_ID.json" \
  < "$TUNNEL_HOME/$TUNNEL_ID.json"
scp -i "$KEY" "$SCRIPT_DIR/install-n8n-aws.sh" "$SCRIPT_DIR/restore.sh" \
  "$SCRIPT_DIR/install-cloudflared-aws.sh" "$TARGET:~/aws/"
echo "  terkirim"

echo "=== [5/5] selesai ==="
cat <<EOS
Lanjutkan di server:
  ssh -i $KEY $TARGET "DOMAIN=<domain> bash ~/aws/install-n8n-aws.sh && bash ~/aws/restore.sh && \\
    TUNNEL_ID=$TUNNEL_ID DOMAIN=<domain> bash ~/aws/install-cloudflared-aws.sh"
EOS

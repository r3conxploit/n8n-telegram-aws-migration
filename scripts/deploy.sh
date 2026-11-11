#!/usr/bin/env bash
# =============================================================================
# deploy.sh — orkestrator migrasi n8n lokal -> AWS EC2
#
# Dijalankan dari WORKSTATION (git-bash/WSL/macOS/Linux), bukan dari EC2.
#
#   cp .env.example .env.deploy && $EDITOR .env.deploy
#   set -a; . ./.env.deploy; set +a
#   bash scripts/deploy.sh
#
# Wajib di environment:
#   HOST        hostname/IP EC2 (mis. ec2-x-x-x-x.ap-southeast-2.compute.amazonaws.com)
#   DOMAIN      domain publik n8n, tanpa skema (mis. n8n.example.com)
#   TUNNEL_ID   UUID tunnel Cloudflare
#   KEY         path private key (.pem/.ed25519)
# Opsional:
#   SSH_USER    default: ubuntu
#   LOG         default: ./deploy.log
#   SKIP_TUNNEL set 1 untuk migrasi data saja (tanpa menyentuh ingress)
#
# Sifat: IDEMPOTEN. Aman dijalankan berulang; berhenti pada kegagalan pertama.
# =============================================================================
set -uo pipefail

HOST="${HOST:?HOST belum di-set (hostname/IP EC2)}"
DOMAIN="${DOMAIN:?DOMAIN belum di-set (mis. n8n.example.com)}"
TUNNEL_ID="${TUNNEL_ID:?TUNNEL_ID belum di-set (UUID tunnel Cloudflare)}"
KEY="${KEY:?KEY belum di-set (path private key)}"
SSH_USER="${SSH_USER:-ubuntu}"
LOG="${LOG:-./deploy.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec > >(tee -a "$LOG") 2>&1
ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }
die() { echo "GAGAL: $*"; exit 1; }

say "================ DEPLOY $(date '+%Y-%m-%d %H:%M:%S') ================"
say "target : $SSH_USER@$HOST   domain: $DOMAIN"

# ---------- 0. key ----------
[ -f "$KEY" ] || die "private key tidak ada: $KEY"
chmod 600 "$KEY" 2>/dev/null || true
say "[0] key ok: $KEY"

SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes"
SCP="scp -i $KEY -o StrictHostKeyChecking=accept-new"

# ---------- 1. konektivitas ----------
say "[1] tes SSH..."
if ! $SSH "$SSH_USER@$HOST" 'echo MASUK_OK' | grep -q MASUK_OK; then
  cat <<'EOS'
GAGAL SSH. Periksa berurutan:
  - instance Running?
  - Security Group membuka 22/tcp dari IP publik Anda saat ini?
  - key pair instance = key ini?
  - username benar? (Ubuntu AMI -> ubuntu, Amazon Linux -> ec2-user, Debian -> admin)
  - instance punya IP publik / Elastic IP?
EOS
  exit 1
fi
$SSH "$SSH_USER@$HOST" 'echo "  host : $(hostname)"; echo "  arch : $(uname -m)"; \
  echo "  os   : $(. /etc/os-release; echo $PRETTY_NAME)"; \
  echo "  ram  : $(free -h | awk "/Mem:/{print \$2}")"; \
  echo "  disk : $(df -h / | awk "NR==2{print \$4\" free\"}")"'

# ---------- 1b. disk ----------
say "[1b] cek & siapkan disk..."
$SSH "$SSH_USER@$HOST" 'AVAIL=$(df --output=avail / | tail -1); if [ "$AVAIL" -lt 4000000 ]; then
  echo "  disk sempit ($AVAIL KB) -> coba growpart"
  sudo apt-get install -y -qq cloud-guest-utils >/dev/null 2>&1 || true
  sudo growpart /dev/nvme0n1 1 >/dev/null 2>&1 || sudo growpart /dev/xvda 1 >/dev/null 2>&1 || true
  for p in /dev/nvme0n1p1 /dev/xvda1 /dev/root; do
    [ -b "$p" ] && sudo resize2fs "$p" >/dev/null 2>&1 && break
  done
else echo "  disk cukup"; fi
sudo docker system prune -af >/dev/null 2>&1 || true   # TANPA --volumes (jangan hapus n8n_data)
sudo apt-get clean >/dev/null 2>&1 || true
AVAIL=$(df --output=avail / | tail -1)
if [ "$AVAIL" -lt 3500000 ]; then
  echo "  masih sempit ($AVAIL KB) -> kecilkan swapfile jadi 512MB"
  sudo swapoff /swapfile 2>/dev/null || true
  sudo rm -f /swapfile
  sudo sed -i "/swapfile/d" /etc/fstab 2>/dev/null || true
  sudo fallocate -l 512M /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  sudo chmod 600 /swapfile; sudo mkswap /swapfile >/dev/null; sudo swapon /swapfile 2>/dev/null || true
fi
TOTAL=$(df -BG / | tail -1 | awk "{print \$2}" | tr -d G)
if [ "${TOTAL:-0}" -lt 20 ]; then
  echo "  PERINGATAN: volume total ${TOTAL}G -> Console > EC2 > Volumes > Modify volume -> 30 GB"
else echo "  volume total ${TOTAL}G OK"; fi
echo "  hasil: $(df -h / | tail -1) | swap: $(free -h | awk "/Swap/{print \$2}")"' || true

# ---------- 2. quiesce sumber ----------
say "[2] pastikan n8n lokal MATI (sqlite harus tenang)..."
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:5678/healthz || true)
if [ "$code" = "200" ]; then
  echo "  n8n lokal masih hidup, mematikan..."
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | \
    Where-Object { \$_.CommandLine -like '*n8n*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
    2>/dev/null || pkill -f 'n8n start' 2>/dev/null || true
  sleep 4
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:5678/healthz || true)
fi
[ "$code" = "200" ] && die "n8n lokal masih hidup (healthz=200). Matikan manual lalu ulangi."
say "  healthz lokal = $code -> aman diarsipkan"

# ---------- 3. file wajib ----------
for f in "$HOME/.n8n/database.sqlite" "$HOME/.n8n/config" "$HOME/.cloudflared/$TUNNEL_ID.json"; do
  [ -f "$f" ] || die "file wajib tidak ada -> $f"
done
say "[3] file wajib lengkap (sqlite + encryption key + credential tunnel)"

# ---------- 4. arsip & transfer ----------
say "[4] arsip ~/.n8n..."
tar -czf ./n8n-data.tar.gz -C "$HOME" .n8n || die "tar gagal (disk workstation penuh?)"
say "  ukuran: $(du -h ./n8n-data.tar.gz | cut -f1)"

say "[4] siapkan folder di EC2..."
$SSH "$SSH_USER@$HOST" "mkdir -p ~/aws && sudo chown -R \$USER:\$USER ~/aws && \
  sudo rm -f ~/aws/$TUNNEL_ID.json && df -h / | tail -1" || die "gagal menyiapkan ~/aws"

$SCP ./n8n-data.tar.gz "$SSH_USER@$HOST:~/aws/" || die "scp arsip gagal"
# credential dikirim lewat stdin: tidak bergantung permission file lokal (Windows) / file lama milik root
$SSH "$SSH_USER@$HOST" "cat > aws/$TUNNEL_ID.json && chmod 600 aws/$TUNNEL_ID.json && wc -c aws/$TUNNEL_ID.json" \
  < "$HOME/.cloudflared/$TUNNEL_ID.json" || die "gagal mengirim credential tunnel"
$SCP "$SCRIPT_DIR/install-n8n-aws.sh" "$SCRIPT_DIR/restore.sh" "$SCRIPT_DIR/install-cloudflared-aws.sh" \
  "$SSH_USER@$HOST:~/aws/" || die "scp skrip gagal"
say "  terkirim"

# ---------- 5. install / restore / ingress ----------
say "[5] install n8n di EC2 (3-5 menit, docker pull paling lama)..."
$SSH "$SSH_USER@$HOST" 'bash ~/aws/install-n8n-aws.sh' | tail -25

say "[5] restore state..."
$SSH "$SSH_USER@$HOST" 'bash ~/aws/restore.sh' | tail -25

if [ "${SKIP_TUNNEL:-0}" = "1" ]; then
  say "[5] SKIP_TUNNEL=1 -> ingress tidak disentuh"
else
  say "[5] pasang Cloudflare Tunnel..."
  $SSH "$SSH_USER@$HOST" "TUNNEL_ID=$TUNNEL_ID DOMAIN=$DOMAIN bash ~/aws/install-cloudflared-aws.sh" | tail -25
fi

# ---------- 6. verifikasi ----------
say "[6] verifikasi (lokal vs publik)..."
pub=""
for i in $(seq 1 12); do
  sleep 5
  pub=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://$DOMAIN/healthz" || true)
  loc=$($SSH "$SSH_USER@$HOST" 'curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:5678/healthz' || true)
  echo "  ${i}: lokal=$loc publik=$pub"
  [ "$pub" = "200" ] && break
done

echo
if [ "${pub:-}" = "200" ]; then
  echo "=== SUKSES: https://$DOMAIN/healthz = 200 ==="
  echo "Lanjut manual: buka editor, login, aktifkan workflow, uji 1 webhook Telegram."
else
  cat <<EOS
=== BELUM 200 (publik=${pub:-000}) ===
Diagnosa berurutan (jangan restart semuanya):
  ssh -i "$KEY" $SSH_USER@$HOST 'systemctl is-active cloudflared'
  ssh -i "$KEY" $SSH_USER@$HOST 'sudo journalctl -u cloudflared -n 50 --no-pager'
  ssh -i "$KEY" $SSH_USER@$HOST 'sudo cat /etc/cloudflared/config.yml; sudo ls -l /etc/cloudflared/'
Lihat docs/troubleshooting.md T6 (lokal 200 + publik 502 = masalah ingress).
EOS
fi
say "log lengkap: $LOG"

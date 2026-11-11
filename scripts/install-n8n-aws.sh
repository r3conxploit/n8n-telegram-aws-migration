#!/usr/bin/env bash
# =============================================================================
# install-n8n-aws.sh — pasang n8n di EC2 (Ubuntu 22.04/24.04/26.04, x86_64)
# Jalankan DI DALAM instance:  bash ~/aws/install-n8n-aws.sh
#
# Idempoten: aman diulang. Container lama dihapus, volume TIDAK disentuh.
# Env opsional: N8N_VERSION (default 2.38.7), DOMAIN, MEM_LIMIT_MB
# =============================================================================
set -euo pipefail

N8N_VERSION="${N8N_VERSION:-2.38.7}"
DOMAIN="${DOMAIN:?DOMAIN wajib di-set (mis. n8n.example.com)}"
HEAP_MB="${HEAP_MB:-768}"

echo "=== [0/6] info mesin ==="
uname -m; free -h | head -2; df -h / | tail -1

echo "=== [1/6] swap 2GB (t3.micro hanya ~900MB RAM) ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "  swap aktif: $(free -h | awk '/Swap/{print $2}')"
else
  echo "  swap sudah ada ($(free -h | awk '/Swap/{print $2}'))"
fi

echo "=== [2/6] paket dasar ==="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl sqlite3 tar

echo "=== [3/6] docker ==="
command -v docker >/dev/null 2>&1 || sudo apt-get install -y -qq docker.io
sudo systemctl enable --now docker >/dev/null 2>&1 || true
for i in $(seq 1 15); do
  sudo docker info >/dev/null 2>&1 && break
  echo "  menunggu docker daemon... ($i)"
  sleep 2
done
sudo docker info >/dev/null 2>&1 || {
  echo "GAGAL: docker daemon tidak jalan"
  sudo systemctl status docker --no-pager | head -10
  exit 1
}
# grup docker untuk sesi berikutnya (skrip ini tetap memakai sudo)
sudo usermod -aG docker "$USER" 2>/dev/null || true
echo "  docker $(sudo docker --version | awk '{print $3}' | tr -d ,) siap"

echo "=== [4/6] volume data (state TIDAK ikut terhapus) ==="
sudo docker volume create n8n_data >/dev/null
echo "  $(sudo docker volume inspect -f '{{.Mountpoint}}' n8n_data)"

echo "=== [5/6] container n8n ${N8N_VERSION} ==="
if sudo docker ps -a --format '{{.Names}}' | grep -qx n8n; then
  echo "  container lama dihapus (volume tetap)"
  sudo docker rm -f n8n >/dev/null
fi

# Catatan penting:
#  - binding 127.0.0.1 -> port TIDAK terbuka ke internet (ingress hanya lewat cloudflared)
#  - N8N_PROXY_HOPS=1 wajib di belakang Cloudflare, kalau tidak URL webhook salah
sudo docker run -d \
  --name n8n \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -v n8n_data:/home/node/.n8n \
  -e N8N_HOST="$DOMAIN" \
  -e N8N_PROTOCOL=https \
  -e N8N_PROXY_HOPS=1 \
  -e WEBHOOK_URL="https://$DOMAIN/" \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e GENERIC_TIMEZONE=Asia/Jakarta \
  -e TZ=Asia/Jakarta \
  -e EXECUTIONS_DATA_PRUNE=true \
  -e EXECUTIONS_DATA_MAX_AGE=336 \
  -e NODE_OPTIONS="--max-old-space-size=${HEAP_MB}" \
  "docker.n8n.io/n8nio/n8n:${N8N_VERSION}"

echo "=== [6/6] tunggu siap ==="
code=000
for i in $(seq 1 30); do
  sleep 4
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:5678/healthz || true)
  echo "  ${i}: healthz=${code}"
  [ "$code" = "200" ] && break
done

sudo docker ps -a --filter name=n8n --format '  {{.Names}}  {{.Status}}  {{.Image}}'
echo
if [ "${code:-000}" != "200" ]; then
  echo "--- log container (40 baris terakhir) ---"
  sudo docker logs --tail 40 n8n 2>&1 || true
  exit 1
fi
echo "SELESAI. n8n listen 127.0.0.1:5678 (tidak terbuka ke internet)."
echo "Lanjut: bash ~/aws/restore.sh   lalu   bash ~/aws/install-cloudflared-aws.sh"

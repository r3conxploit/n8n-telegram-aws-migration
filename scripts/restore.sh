#!/usr/bin/env bash
# =============================================================================
# restore.sh — jalankan DI EC2. Isi docker volume n8n_data dari arsip .n8n
#
#   bash ~/aws/restore.sh [path/arsip.tar.gz]
#
# Urutan: stop container -> snapshot isi lama (rollback instan) -> ekstrak ->
#         chown 1000:1000 (n8n jalan sebagai UID 1000) -> start -> verifikasi.
# Aman diulang; arsip lama tetap tersimpan sebagai /data.pre-restore.tar.gz.
# =============================================================================
set -euo pipefail

TARBALL="${1:-$HOME/aws/n8n-data.tar.gz}"
VOLUME="n8n_data"

[ -f "$TARBALL" ] || { echo "ERROR: arsip tidak ada: $TARBALL"; exit 1; }
sudo docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
  echo "ERROR: volume $VOLUME belum ada — jalankan install-n8n-aws.sh dulu"
  exit 1
}

echo "=== [1/5] arsip $(du -h "$TARBALL" | cut -f1) ==="
tar tzf "$TARBALL" >/dev/null || { echo "ERROR: arsip korup / bukan tar.gz"; exit 1; }

echo "=== [2/5] stop container ==="
sudo docker stop n8n >/dev/null 2>&1 || true

echo "=== [3/5] snapshot isi volume lama (rollback) ==="
sudo docker run --rm -v "${VOLUME}:/data" alpine sh -c \
  'if [ -n "$(ls -A /data 2>/dev/null)" ]; then tar czf /data.pre-restore.tar.gz -C /data . && \
   echo "  isi lama -> /data.pre-restore.tar.gz"; else echo "  volume kosong"; fi'

echo "=== [4/5] ekstrak (strip .n8n) + ownership UID 1000 ==="
sudo docker run --rm -i -v "${VOLUME}:/data" alpine sh -c \
  'tar xzf - -C /data --strip-components=1 && chown -R 1000:1000 /data'
sudo docker run --rm -v "${VOLUME}:/data" alpine sh -c 'ls -la /data | head -10'

echo "=== [5/5] start + verifikasi ==="
sudo docker start n8n >/dev/null
code=000
for i in $(seq 1 40); do
  sleep 4
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:5678/healthz || true)
  echo "  ${i}: healthz=${code}"
  [ "$code" = "200" ] && break
done

echo
echo "--- isi state setelah restore ---"
sudo docker exec n8n sh -c 'sqlite3 /home/node/.n8n/database.sqlite "
  select \"workflows=\"||count(*) from workflow_entity
  union all select \"active=\"||count(*) from workflow_entity where active=1
  union all select \"credentials=\"||count(*) from credentials_entity
  union all select \"executions=\"||count(*) from execution_entity;" 2>/dev/null' \
  || echo "  (sqlite3 tidak ada di image; hitung lewat UI)"

if [ "$code" != "200" ]; then
  echo "--- log container ---"
  sudo docker logs --tail 40 n8n 2>&1 || true
  exit 1
fi
echo
echo "healthz=200. Lanjut: bash ~/aws/install-cloudflared-aws.sh"

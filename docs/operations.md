# Operations — runbook harian

Semua perintah diasumsikan dijalankan dari workstation dengan variabel:

```bash
set -a; . ./.env.deploy; set +a     # HOST, DOMAIN, KEY, TUNNEL_ID
SSH="ssh -i $KEY ubuntu@$HOST"
```

---

## 1. Dashboard 30 detik

```bash
$SSH 'echo "== n8n ==";        docker ps --filter name=n8n --format "{{.Status}}  {{.Image}}"
      echo "== tunnel ==";     systemctl is-active cloudflared
      echo "== disk ==";       df -h / | tail -1
      echo "== mem ==";        free -h | sed -n "2,3p"
      echo "== health ==";     curl -s localhost:5678/healthz'
curl -s -o /dev/null -w 'publik=%{http_code} tls=%{time_total}s\n' https://n8n.$DOMAIN/healthz
```

Interpretasi cepat:

| Lokal | Publik | Arti |
|---|---|---|
| 200 | 200 | sehat |
| 200 | 502 | **ingress** bermasalah (cloudflared), bukan n8n |
| 000 | 502/52x | container mati atau host mati |
| 000 | 000 | DNS/akun Cloudflare atau instance down |

---

## 2. Siklus hidup service

```bash
$SSH 'docker restart n8n'                              # restart aplikasi (state aman)
$SSH 'sudo systemctl restart cloudflared'              # restart ingress
$SSH 'sudo systemctl status cloudflared --no-pager -l' # kenapa ingress diam
$SSH 'docker logs --tail 200 -f n8n'                   # ikuti log aplikasi
$SSH 'sudo journalctl -u cloudflared -n 100 --no-pager'
```

`n8n` memakai `--restart unless-stopped`; `cloudflared` memakai systemd `enabled`. Keduanya
otomatis hidup setelah reboot — **kecuali** jika container pernah di-`docker stop` manual
(itulah arti `unless-stopped`).

---

## 3. Backup

### 3a. Harian (cron di EC2)

```bash
$SSH 'sudo tee /etc/cron.d/n8n-backup >/dev/null <<"EOF"
# backup volume n8n tiap hari 02:00 WIB, retensi 7 hari
CRON_TZ=Asia/Jakarta
0 2 * * * root mkdir -p /opt/n8n-backups && docker run --rm -v n8n_data:/data:ro \
  -v /opt/n8n-backups:/backup alpine sh -c \
  "tar czf /backup/n8n-$(date +\%Y\%m\%d).tar.gz -C /data ." && \
  find /opt/n8n-backups -name "n8n-*.tar.gz" -mtime +7 -delete
EOF
sudo chmod 644 /etc/cron.d/n8n-backup'

# buktikan jalan (jangan tunggu besok)
$SSH 'sudo /usr/sbin/cron -f >/dev/null 2>&1 & sleep 1; sudo bash -c "mkdir -p /opt/n8n-backups && docker run --rm -v n8n_data:/data:ro -v /opt/n8n-backups:/backup alpine tar czf /backup/n8n-manual-\$(date +%Y%m%d).tar.gz -C /data ." && ls -lh /opt/n8n-backups'
```

> Backup yang tidak pernah diuji restore = asumsi, bukan backup. Lakukan **restore drill**
> sebulan sekali ke instance sementara (lihat §3c).

### 3b. Ambil backup ke workstation (off-site)

```bash
$SSH 'ls -t /opt/n8n-backups | head -1'
scp -i "$KEY" ubuntu@$HOST:/opt/n8n-backups/n8n-YYYYMMDD.tar.gz ./backups/
sha256sum ./backups/n8n-YYYYMMDD.tar.gz
```

Simpan minimal satu salinan **di luar AWS** (laptop/NAS/object storage lain). Satu akun AWS
bukan dua tempat penyimpanan.

### 3c. Restore drill (uji, bukan asumsi)

```bash
# di instance uji (boleh t3.micro sementara)
bash install-n8n-aws.sh
scp backup.tar.gz ubuntu@<host-uji>:~/aws/n8n-data.tar.gz
ssh -i "$KEY" ubuntu@<host-uji> 'bash ~/aws/restore.sh'
# target: healthz 200 + jumlah workflow sama dengan baseline
```

---

## 4. Disk & retensi

Anggaran disk 28–30 GiB. Pemakai terbesar: volume sqlite (243 MB dan tumbuh oleh eksekusi),
2–3 layer image n8n (± 1 GB masing-masing), log Docker, dan arsip backup lokal.

```bash
$SSH 'df -h /; sudo du -sh /var/lib/docker/volumes/n8n_data/_data /var/lib/docker /opt/n8n-backups 2>/dev/null'
$SSH 'docker system df'
$SSH 'sudo docker system prune -af --volumes=false'   # HATI-HATI: prune volume akan hapus data
```

Aturan: **jangan pernah** `docker system prune --volumes` di host ini — itu menghapus
`n8n_data`. Gunakan `--volumes=false` secara eksplisit.

Retensi eksekusi dikendalikan environment container:

```text
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=336        # hari
```

Kalau butuh lebih agresif: turunkan ke 168 (7 hari) lalu `docker rm -f n8n` + jalankan ulang
container dengan env yang sama.

---

## 5. Upgrade n8n (prosedur aman)

```bash
NEW=2.39.0
$SSH 'docker run --rm -v n8n_data:/data:ro -v /opt/n8n-backups:/backup alpine \
      tar czf /backup/pre-upgrade-$(date +%Y%m%d-%H%M).tar.gz -C /data .'
$SSH "docker rm -f n8n && docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:5678:5678 -v n8n_data:/home/node/.n8n \
  -e N8N_HOST=n8n.$DOMAIN -e N8N_PROTOCOL=https -e N8N_PROXY_HOPS=1 \
  -e WEBHOOK_URL=https://n8n.$DOMAIN/ -e GENERIC_TIMEZONE=Asia/Jakarta -e TZ=Asia/Jakarta \
  -e EXECUTIONS_DATA_PRUNE=true -e EXECUTIONS_DATA_MAX_AGE=336 \
  -e NODE_OPTIONS=--max-old-space-size=768 \
  docker.n8n.io/n8nio/n8n:$NEW"
curl -s -o /dev/null -w '%{http_code}\n' https://n8n.$DOMAIN/healthz
```

Rollback: jalankan blok yang sama dengan tag lama, lalu restore arsip `pre-upgrade` bila
migrasi skema bermasalah. **Jangan** upgrade dan mengubah workflow aktif di hari yang sama.

---

## 6. Perubahan konfigurasi ingress

`safe` — edit `config.yml`, `systemctl reload-or-restart cloudflared`, uji 1 webhook.

```bash
$SSH 'sudo nano /etc/cloudflared/config.yml && sudo systemctl restart cloudflared && \
      sleep 5 && systemctl is-active cloudflared'
```

Format `config.yml` yang dipakai:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
no-autoupdate: true

ingress:
  - hostname: n8n.<domain>
    service: http://127.0.0.1:5678
  - service: http_status:404     # default deny untuk hostname lain
```

---

## 7. Monitoring minimum (tanpa agent tambahan)

| Sinyal | Cara murah | Aksi |
|---|---|---|
| Instance hidup | CloudWatch `StatusCheckFailed` alarm | stop/start |
| Disk > 80 % | CloudWatch EBS `VolumeUsedPercent` (butuh agent) **atau** cron `df` + email | prune/naikkan volume |
| n8n sehat | cron tiap 5 menit: `curl -f localhost:5678/healthz \|\| docker restart n8n` | auto-heal |
| Ingress sehat | cron: `curl -f https://n8n.$DOMAIN/healthz` | restart cloudflared |
| Error workflow | n8n *Error Trigger* workflow → kirim notifikasi Telegram | perbaiki node |

Contoh watchdog (dipasang di `/usr/local/bin/n8n-watchdog.sh` + cron `*/5`):

```bash
#!/usr/bin/env bash
set -u
if ! curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null; then
  logger -t n8n-watchdog "healthz gagal, restart container"
  docker restart n8n
fi
if ! systemctl is-active --quiet cloudflared; then
  logger -t n8n-watchdog "cloudflared mati, restart"
  systemctl restart cloudflared
fi
```

---

## 8. Checklist mingguan

- [ ] healthz publik 200 (7 hari berturut)
- [ ] `df -h /` < 70 %
- [ ] backup terbaru ada + ukuran wajar (± 24 MB)
- [ ] jumlah error eksekusi n8n tidak naik
- [ ] versi image masih tag yang diinginkan (bukan `latest`)
- [ ] `aws ec2 describe-instances` → tidak ada instance uji tertinggal (biaya)

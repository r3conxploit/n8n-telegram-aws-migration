# Troubleshooting — kasus nyata dari migrasi ini

Semua entri di bawah berasal dari `deploy.log` asli (5 percobaan, 11 Nov). Format:
**gejala → akar masalah → perbaikan → pencegahan**. Kalau error-nya tidak ada di sini,
mulai dari urutan diagnosa di §9.

---

## T1 — `permission denied ... /var/run/docker.sock`

```text
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

**Akar masalah.** `install-n8n-aws.sh` awal memakai `docker` tanpa `sudo` sebelum user masuk
grup docker (dan grup baru efektif setelah login ulang). Skrip berhenti di langkah volume.

**Perbaikan.** Skrip di repo ini memakai `sudo docker ...` konsisten + menunggu socket siap:

```bash
for i in $(seq 1 15); do sudo docker info >/dev/null 2>&1 && break; sleep 2; done
sudo docker info >/dev/null 2>&1 || { echo "GAGAL: daemon docker tidak jalan"; exit 1; }
sudo usermod -aG docker "$USER"     # untuk sesi berikutnya
```

**Pencegahan.** Jangan mengandalkan keanggotaan grup di sesi yang sama; skrip harus bekerja
tanpa interaksi login ulang.

---

## T2 — `ERROR: volume belum ada, jalankan install-n8n-aws.sh`

**Akar masalah.** Urutan eksekusi salah: `restore.sh` dijalankan padahal langkah install gagal
di tengah (T1), sehingga volume `n8n_data` belum dibuat.

**Perbaikan.** `restore.sh` memeriksa prasyarat dan berhenti dengan pesan jelas — inilah
perilaku yang diinginkan. Jalankan `install-n8n-aws.sh`, verifikasi `docker ps`, baru restore.

**Pencegahan.** `deploy.sh` menjalankan tahap secara **berurutan dengan `set -e` + pemeriksaan**;
jangan menjalankan tahap lanjutan secara manual sebelum tahu tahap sebelumnya sukses.

---

## T3 — `scp: Permission denied` saat kirim credential tunnel

```text
scp: dest open "aws/<TUNNEL_ID>.json": Permission denied
scp: failed to upload file ... to ~/aws/
```

**Akar masalah.** File tujuan di EC2 sudah ada dan dimiliki `root` (sisa percobaan sebelumnya).
`scp` tidak bisa menimpa file milik root dari user `ubuntu`.

**Perbaikan.** Kirim lewat stdin, bukan sebagai file, lalu set permission di sisi tujuan:

```bash
ssh -i "$KEY" ubuntu@$HOST "cat > aws/<TUNNEL_ID>.json && chmod 600 aws/<TUNNEL_ID>.json" \
  < "$HOME/.cloudflared/<TUNNEL_ID>.json"
```

**Pencegahan.** `deploy.sh` menghapus file lama lebih dulu (`sudo rm -f ~/aws/<id>.json`), dan
tidak bergantung pada permission file lokal (di Windows permission itu tidak bermakna).

---

## T4 — `no space left on device` saat `docker pull`

```text
docker: failed to extract layer ... to overlayfs as "...": mount callback failed ...
write /var/lib/containerd/tmpmounts/.../usr/lib/libssl.so.3: no space left on device
```

**Akar masalah.** Volume root 8 GiB. Image n8n (± 1 GB terkompresi, ± 2,5 GB ter-extract) +
layer lama + sqlite 243 MB menghabiskan sisa ruang. `df` menunjukkan **0 byte** pada percobaan
ke-4.

**Perbaikan (dua lapis).**

```bash
# segera: bebaskan ruang
sudo docker system prune -af            # TANPA --volumes
sudo apt-get clean
sudo journalctl --vacuum-size=100M

# struktural: perbesar EBS lalu tumbuhkan filesystem tanpa rebuild
#   Console > EC2 > Volumes > Modify volume -> 30 GB
sudo apt-get install -y cloud-guest-utils
sudo growpart /dev/nvme0n1 1 || sudo growpart /dev/xvda 1
sudo resize2fs /dev/nvme0n1p1      # atau /dev/xvda1 / /dev/root
```

**Pencegahan.** Volume 30 GiB sejak awal (ADR-007), `df -h /` dicek di setiap deploy, retensi
eksekusi 14 hari, dan swap tidak lebih dari 2 GiB.

---

## T5 — `tar: write error: No space left on device` (saat arsip/restore)

**Akar masalah.** Sama seperti T4, tapi terjadi di tengah ekstraksi ke volume — lebih berbahaya
karena volume bisa berisi data setengah jadi.

**Perbaikan.**

```bash
df -h /                                        # pastikan ada > 1 GB bebas
sudo docker stop n8n
sudo docker run --rm -v n8n_data:/data alpine sh -c 'rm -rf /data/*'   # bersihkan sisa gagal
# ulangi restore setelah ruang cukup
bash restore.sh
```

**Pencegahan.** `restore.sh` membuat `/data.pre-restore.tar.gz` **sebelum** menimpa; jadi sisa
ekstraksi gagal bisa dikembalikan, tidak perlu panik.

---

## T6 — Publik **502** padahal lokal **200**

```text
[6] verifikasi publik...
  1: lokal=200 publik=502
  ...
 12: lokal=200 publik=502
```

**Ini kasus paling sering dan paling sering disalahartikan.** Aplikasi sehat; yang rusak adalah
jalur ingress. Urutan diagnosa (jangan langsung restart semuanya):

```bash
$SSH 'systemctl is-active cloudflared'                 # 1. service hidup?
$SSH 'sudo journalctl -u cloudflared -n 50 --no-pager' # 2. ada error credential?
$SSH 'sudo cat /etc/cloudflared/config.yml'            # 3. tunnel id & service URL benar?
$SSH 'sudo ls -l /etc/cloudflared/'                    # 4. credential ada, 600, root?
$SSH 'curl -s localhost:5678/healthz'                  # 5. origin benar-benar 200?
```

Penyebab yang pernah terjadi di sini:

| Cek | Temuan | Solusi |
|---|---|---|
| credential tunnel | file tidak ada / `Permission denied` saat kirim | kirim via `cat >` (T3), lalu `systemctl restart cloudflared` |
| `cloudflared` | `active (running)` tapi origin di `config.yml` salah port | perbaiki `service: http://127.0.0.1:5678` |
| tunnel id | `config.yml` beda dengan credential | samakan ID |
| n8n | listen `0.0.0.0:5678` vs `127.0.0.1:5678` | tunnel memakai loopback, jadi `127.0.0.1` sudah benar |

**Pencegahan.** Pisahkan dua metrik di dashboard (lokal vs publik, lihat `docs/operations.md` §1);
kalau keduanya dibedakan, 502 tidak pernah lagi dibaca sebagai "n8n mati".

---

## T7 — Container restart-loop setelah restore

**Gejala.** `docker ps` → `Restarting (1) ...`; log menyebut sqlite read-only / permission.

**Akar masalah.** File hasil ekstrak dimiliki `root` atau UID lain, sedangkan image n8n berjalan
sebagai UID `1000` (`node`).

**Perbaikan.**

```bash
$SSH 'sudo docker stop n8n 2>/dev/null; sudo docker run --rm -v n8n_data:/data alpine \
      chown -R 1000:1000 /data; sudo docker start n8n'
```

**Pencegahan.** `restore.sh` menjalankan `chown -R 1000:1000 /data` di akhir ekstrak — jangan
dihapus saat memodifikasi skrip.

---

## T8 — OOM / n8n mati mendadak

**Gejala.** Container hilang dari `docker ps`, `dmesg` berisi `Out of memory: Killed process`,
atau healthz 000 sesaat setelah akses berat.

**Akar masalah.** RAM efektif 908 MiB; Node default heap bisa melampaui itu saat satu eksekusi
membawa banyak item (mis. 1.000 baris sheets).

**Perbaikan.**

```bash
$SSH 'free -h; dmesg -T | tail -20 | grep -i oom'
$SSH 'docker inspect n8n --format "{{.State.OOMKilled}}"'     # true = terbukti OOM
# turunkan heap & pastikan swap aktif
$SSH 'sudo swapon --show'
```

Jalankan ulang container dengan `NODE_OPTIONS=--max-old-space-size=768` (sudah default di
`install-n8n-aws.sh`) dan pecah workflow besar menjadi batch (node `Split In Batches`).

**Pencegahan.** Swap 2 GiB, batasi heap, retensi eksekusi 14 hari. Kalau OOM tetap muncul:
naik kelas ke `t3.small` (2 GiB) — keputusan sadar, bukan kegagalan.

---

## T9 — Webhook URL salah / redirect ke hostname internal

**Gejala.** Telegram menerima error `Wrong response from the webhook` atau n8n menghasilkan URL
`http://localhost:5678/...` saat register webhook.

**Akar masalah.** Di belakang proxy, n8n butuh tahu bahwa ia berada di balik satu hop HTTPS.

**Perbaikan.** Environment yang wajib ada (sudah dipasang skrip):

```text
N8N_HOST=n8n.<domain>
N8N_PROTOCOL=https
N8N_PROXY_HOPS=1
WEBHOOK_URL=https://n8n.<domain>/
```

Setelah mengubah env: `docker rm -f n8n` lalu jalankan ulang (**restart** tidak menerapkan env
baru), kemudian re-register webhook di sisi bot (`setWebhook`).

---

## T10 — Credential n8n tidak bisa didekripsi

```text
Credentials could not be decrypted. The likely reason is that a different
"encryptionKey" was used to encrypt the data.
```

**Akar masalah.** `config` (56 byte) tidak ikut di-restore, atau volume berisi data dari instance
lain dengan key berbeda.

**Perbaikan.** Restore `config` dari arsip yang benar, lalu restart:

```bash
$SSH 'sudo docker run --rm -v n8n_data:/data alpine cat /data/config | head -c 20; echo'
# bandingkan dengan arsip: tar tzf n8n-data.tar.gz | grep -c "/config"   -> harus 1
```

Kalau `config` hilang permanen: **tidak ada** cara memulihkan credential — buat ulang 7
kredensial (Sheets, Telegram, dll.) dan simpan key baru di backup. Itulah sebabnya `config`
disebut di setiap dokumen di repo ini.

---

## 11. Urutan diagnosa umum (kalau error tidak ada di daftar)

```bash
# 1. Apakah host hidup?
ping -c1 $HOST; ssh -i "$KEY" ubuntu@$HOST 'uptime' || echo "host/SSH bermasalah"

# 2. Apakah container hidup?
$SSH 'docker ps -a --filter name=n8n --format "{{.Status}}"; docker inspect n8n --format "{{.State.OOMKilled}} {{.RestartCount}}"'

# 3. Apakah aplikasi sehat?
$SSH 'curl -s -o /dev/null -w "%{http_code}\n" localhost:5678/healthz'

# 4. Apakah ingress sehat?
$SSH 'systemctl is-active cloudflared; sudo journalctl -u cloudflared -n 30 --no-pager'

# 5. Apakah edge sehat?
curl -s -o /dev/null -w "publik=%{http_code} dns=%{time_namelookup}s tls=%{time_appconnect}s total=%{time_total}s\n" https://n8n.$DOMAIN/healthz

# 6. Apakah ruang masih ada?
$SSH 'df -h /; free -h'
```

Aturan praktis: **200/200** sehat · **200/502** ingress · **000/502** container · **000/000**
host/DNS. Satu tabel ini menyelesaikan 80 % laporan "n8n down".

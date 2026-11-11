# Migration Runbook — lokal → AWS

Runbook ini adalah versi terurut dari apa yang benar-benar dijalankan (dan gagal 4× sebelum
berhasil). Setiap fase punya **checkpoint**: jangan lanjut kalau checkpoint belum terpenuhi.

Estimasi total: **45–60 menit** (pertama kali), **± 6 menit** untuk redeploy/recovery.

---

## Fase 0 — Inventaris & prasyarat

```bash
# di workstation (Windows/git-bash)
ls -la ~/.n8n                      # database.sqlite, config, event log
ls -la ~/.cloudflared/<TUNNEL_ID>.json   # credential tunnel
du -sh ~/.n8n
```

Checkpoint:

- [ ] `~/.n8n/config` ada (56 byte) — **encryption key**, wajib ikut
- [ ] `~/.n8n/database.sqlite` ada dan ukurannya wajar
- [ ] credential tunnel Cloudflare ada
- [ ] `n8n.<domain>` sudah ada di Cloudflare (DNS dipegang tunnel, bukan A record manual)
- [ ] key pair `.pem` untuk instance tersedia, permission `0600`

> Catat baseline: jumlah workflow, credential, dan workflow yang **aktif**.
> `sqlite3 ~/.n8n/database.sqlite "select count(*) from workflow_entity;"`
> Angka ini jadi pembanding setelah restore — tanpa baseline, "berhasil" cuma perasaan.

---

## Fase 1 — Provision EC2

| Setting | Nilai | Alasan |
|---|---|---|
| AMI | Ubuntu Server 26.04 LTS (x86_64) | paket `docker.io` tersedia, systemd stabil |
| Instance type | `t3.micro` | lihat ADR-001/006 |
| Storage | gp3 **30 GiB** | ADR-007 — 8 GiB terbukti habis |
| Security Group | inbound **22/tcp dari IP admin saja** | tidak ada 80/443/5678 |
| Key pair | `server-bot` | disimpan `0600` di workstation |

Checkpoint:

```bash
ssh -i ~/.ssh/key.pem ubuntu@<host> 'uname -m; . /etc/os-release; echo $PRETTY_NAME; df -h / | tail -1'
# harap: x86_64 / Ubuntu 26.04 / ≥ 28G
```

Kalau SSH gagal, urutan diagnosa: instance `running`? SG 22 dari IP saat ini? key pair cocok?
username `ubuntu` (bukan `ec2-user` untuk Ubuntu AMI)?

---

## Fase 2 — Quiesce sumber (downtime dimulai)

```bash
# Windows: matikan n8n lokal
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
  Where-Object { \$_.CommandLine -like '*n8n*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }"

# verifikasi benar-benar mati
curl -s -o /dev/null -w '%{http_code}\n' --max-time 4 http://127.0.0.1:5678/healthz   # harap 000
```

Checkpoint: healthz **bukan** 200. sqlite yang diarsip saat masih hidup akan membawa WAL yang
tidak konsisten.

> Praktik lebih aman untuk produksi: `pause` semua workflow dulu, tunggu eksekusi berjalan
> selesai, baru stop proses.

---

## Fase 3 — Install runtime di EC2 (idempoten)

```bash
scp -i "$KEY" scripts/install-n8n-aws.sh scripts/restore.sh scripts/install-cloudflared-aws.sh \
  ubuntu@$HOST:~/aws/
ssh -i "$KEY" ubuntu@$HOST 'bash ~/aws/install-n8n-aws.sh'
```

Yang dilakukan skrip: swap 2 GiB → `apt-get` paket dasar → `docker.io` + tunggu socket →
`docker volume create n8n_data` → `docker run` n8n dengan binding `127.0.0.1:5678` → tunggu
`/healthz` 200 (maks 2 menit).

Checkpoint:

```bash
ssh -i "$KEY" ubuntu@$HOST 'docker ps; curl -s localhost:5678/healthz'
# harap: n8n Up (healthy-ish) + {"status":"ok"}
```

Kalau belum 200, skrip mencetak 40 baris log container terakhir — baca bagian itu, jangan menebak.

---

## Fase 4 — Transfer & restore state

```bash
# di workstation
tar czf n8n-data.tar.gz -C "$HOME" .n8n
scp -i "$KEY" n8n-data.tar.gz ubuntu@$HOST:~/aws/
# credential tunnel lewat stdin agar permission file lokal tidak jadi masalah
ssh -i "$KEY" ubuntu@$HOST "cat > aws/<TUNNEL_ID>.json && chmod 600 aws/<TUNNEL_ID>.json" \
  < "$HOME/.cloudflared/<TUNNEL_ID>.json"

# di EC2
ssh -i "$KEY" ubuntu@$HOST 'bash ~/aws/restore.sh'
```

Isi `restore.sh`: stop container → **snapshot isi volume lama** ke `/data.pre-restore.tar.gz`
(rollback instan) → ekstrak tar ke volume dengan `--strip-components=1` → `chown -R 1000:1000` →
start → tunggu healthz → hitung workflow.

Checkpoint (harus sama dengan baseline Fase 0):

```bash
ssh -i "$KEY" ubuntu@$HOST \
  'docker exec n8n sqlite3 /home/node/.n8n/database.sqlite \
   "select (select count(*) from workflow_entity), (select count(*) from credentials_entity), (select count(*) from execution_entity);"'
# contoh hasil nyata: 20|7|104
```

---

## Fase 5 — Ingress (Cloudflare Tunnel)

```bash
ssh -i "$KEY" ubuntu@$HOST 'bash ~/aws/install-cloudflared-aws.sh'
```

Isi: install `cloudflared` (deb amd64) → credential ke `/etc/cloudflared/<id>.json` `0600 root` →
tulis `/etc/cloudflared/config.yml` (ingress satu hostname + `http_status:404`) →
`cloudflared service install` → `systemctl enable --now cloudflared`.

Checkpoint:

```bash
ssh -i "$KEY" ubuntu@$HOST 'systemctl is-active cloudflared; sudo journalctl -u cloudflared -n 20 --no-pager'
curl -s -o /dev/null -w '%{http_code}\n' https://n8n.$DOMAIN/healthz   # harap 200
```

**Kalau lokal 200 tapi publik 502** — itu masalah ingress, bukan aplikasi. Tiga penyebab tersering:

1. `cloudflared` tidak `active` (credential salah path → service restart-loop).
2. `credentials-file` di `config.yml` menunjuk file yang tidak ada / permission salah.
3. Tunnel ID di `config.yml` beda dengan credential yang dikirim.

---

## Fase 6 — Verifikasi & cutover

Matriks verifikasi minimum sebelum menyatakan "selesai":

| # | Cek | Perintah | Harapan |
|---|---|---|---|
| 1 | Health publik | `curl -s https://n8n.$DOMAIN/healthz` | `{"status":"ok"}`, TLS ok |
| 2 | Editor bisa login | buka di browser | halaman login n8n, bukan 502 |
| 3 | Jumlah workflow | query sqlite | = baseline |
| 4 | Credential terbaca | buka 1 node ber-credential | tidak ada "could not decrypt" |
| 5 | Workflow aktif | UI → active toggle | 2 workflow (material & NTE) aktif |
| 6 | Webhook Telegram | kirim 1 pesan uji ke grup | baris baru masuk Google Sheets |
| 7 | Auto-restart | `sudo reboot`, tunggu 90 s | healthz kembali 200 tanpa intervensi |
| 8 | Tunnel persist | `systemctl is-enabled cloudflared` | `enabled` |

Setelah 8 cek hijau: **matikan autostart n8n lokal** (`autostart-backup/*.vbs`, `start-n8n.bat`)
supaya tidak ada dua instance yang berebut webhook yang sama.

---

## Rollback

Trigger rollback: cek #2, #4, atau #6 gagal dan tidak selesai dalam 15 menit.

```bash
# A. rollback cepat di sisi data (EC2)
ssh -i "$KEY" ubuntu@$HOST \
  'docker stop n8n && docker run --rm -v n8n_data:/data alpine \
     sh -c "rm -rf /data/* && tar xzf /data.pre-restore.tar.gz -C /data && chown -R 1000:1000 /data" \
   && docker start n8n'

# B. rollback penuh ke lokal
#    state lokal TIDAK pernah ditulis oleh proses migrasi (restore hanya menulis ke volume EC2)
start-n8n.bat        # Windows
#    lalu nonaktifkan workflow di EC2 agar tidak ada eksekusi ganda:
ssh -i "$KEY" ubuntu@$HOST 'docker stop n8n'
```

Catatan: selama n8n EC2 mati dan tunnel hidup, publik akan **502**. Itu perilaku yang diinginkan —
gagal cepat dan jelas, bukan diam-diam memproses dengan state lama.

---

## Log & jejak

`deploy.sh` menulis seluruh output ke `deploy.log` (tee). Dari log ini terlihat 5 percobaan pada
hari yang sama, dengan penyebab kegagalan berbeda-beda — inilah nilai nyata runbook ini: setiap
kegagalan jadi satu baris di `troubleshooting.md`, bukan pelajaran yang hilang.

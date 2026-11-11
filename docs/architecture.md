# Arsitektur — n8n + Bot Telegram di AWS

Dokumen ini menjelaskan **apa yang berjalan di mana**, **batas kepercayaan**, dan **apa yang
gagal lebih dulu** ketika ada masalah. Semua angka diambil dari instance yang benar-benar
menjalankan beban ini.

---

## 1. Komponen

| Komponen | Letak | Peran | State? |
|---|---|---|---|
| `cloudflared.service` | EC2, systemd, root | Connector outbound ke Cloudflare edge, TLS termination di edge | Tidak (config `/etc/cloudflared/`) |
| container `n8n` | EC2, Docker, UID 1000 | Editor + webhook + scheduler workflow | Ya → volume `n8n_data` |
| volume `n8n_data` | `/var/lib/docker/volumes/n8n_data/_data` | `database.sqlite`, `config` (encryption key), event log | Ya |
| EBS gp3 28 GiB | AWS | Media fisik volume | Ya |
| Cloudflare DNS + Tunnel | edge | `n8n.<domain>` → tunnel | Konfigurasi |
| Telegram Bot API | internet | Sumber event | — |
| Google Sheets API | internet | Tujuan data | — |

**Invariant penting:** container boleh mati, dibuat ulang, atau di-upgrade kapan saja.
Volume dan `config` tidak boleh hilang. Semua desain backup berpusat pada dua objek itu.

---

## 2. Jalur request

```text
Telegram (webhook POST)
  └─> Cloudflare edge  (TLS terminate, WAF, rate limit opsional)
        └─> QUIC tunnel 7844/tcp (dibuka DARI dalam EC2, outbound)
              └─> cloudflared (systemd, config /etc/cloudflared/config.yml)
                    └─> http://127.0.0.1:5678  (n8n container, host network mapping loopback)
                          └─> workflow -> node Code (parser L0) -> Google Sheets append
```

Yang **tidak** ada di jalur ini: ALB, Nginx, Certbot, NAT Gateway, port 443 inbound,
IP publik yang mengekspos aplikasi. Ini keputusan sadar (ADR-003), dengan konsekuensi:
**jika akun Cloudflare bermasalah, ingress mati** meski EC2 sehat.

---

## 3. Batas kepercayaan

| Zona | Isi | Yang boleh masuk |
|---|---|---|
| **Publik / untrusted** | Internet, Cloudflare edge | Hanya HTTPS ke hostname yang di-ingress |
| **Host EC2** | OS, docker daemon, cloudflared (`root`) | SSH dari IP admin; SSM idealnya |
| **Container** | n8n, UID 1000, no privileged | Hanya lewat 127.0.0.1:5678 |
| **Data** | volume `n8n_data`, sqlite, encryption key | Hanya proses n8n (UID 1000) |

Kontrol per batas:

- Edge → host: `no-autoupdate: true`, `http_status:404` sebagai *explicit default deny* untuk
  hostname lain, credential tunnel `0600 root:root`.
- Host → container: `-p 127.0.0.1:5678:5678` (bukan `0.0.0.0`). Security Group tanpa aturan 5678.
- Container → data: `chown -R 1000:1000` setelah restore; tanpa ini sqlite menjadi read-only.
- Manusia → host: key pair `0600` di workstation, host key di-pin (`StrictHostKeyChecking=accept-new`).

---

## 4. Sizing & anggaran sumber daya

| Sumber daya | Kapasitas | Pemakaian terukur | Ambang tindakan |
|---|---|---|---|
| vCPU | 2 (burst, t3.micro) | < 5 % idle, spike saat pull/restore | CPU credit balance < 50 → naik kelas |
| RAM | 908 MiB | 653 MiB used, 288 MiB cache | OOM / swap thrash → t3.small |
| Swap | 2 GiB | 330 MiB terpakai | dipakai terus → tambah RAM |
| Disk | 28 GiB | 6,8 GiB (25 %) | > 80 % → prune + arsipkan eksekusi |
| sqlite | 243 MB (logis) | 104 eksekusi, 20 workflow | > 2 GB → `EXECUTIONS_DATA_PRUNE` lebih agresif / pindah Postgres |

Nilai environment yang mengikat ke ukuran mesin (ada di `install-n8n-aws.sh`):

```text
NODE_OPTIONS=--max-old-space-size=768     # heap Node dibatasi < RAM total
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=336               # 14 hari retensi eksekusi
GENERIC_TIMEZONE=Asia/Jakarta, TZ=Asia/Jakarta
N8N_PROXY_HOPS=1                          # wajib di belakang Cloudflare
```

---

## 5. Failure mode (urut dari yang paling mungkin)

| # | Kegagalan | Gejala | Deteksi | Mitigasi |
|---|---|---|---|---|
| 1 | Disk penuh | n8n crash-loop, `/healthz` 000, `df` mendekati 100 % | `df -h /`, alert EBS | prune, naikkan volume, retensi eksekusi |
| 2 | Tunnel mati | publik **502**, lokal **200** | `systemctl is-active cloudflared` | restart service; cek credential path |
| 3 | Container restart-loop | `docker ps` = `Restarting` | `docker ps`, `docker logs` | cek ownership volume / heap OOM |
| 4 | OOM | proses dibunuh kernel, `dmesg` OOM-kill | `free -h`, `dmesg -T \| tail` | swap, turunkan `max-old-space-size` |
| 5 | Credential n8n rusak | workflow error "credentials could not be decrypted" | log eksekusi | restore `config` dari arsip |
| 6 | Instance mati (host failure) | total down | CloudWatch `StatusCheckFailed` | stop/start (EBS persist), atau restore ke instance baru |
| 7 | Cloudflare blokir akun | total down | dashboard Cloudflare | DNS langsung + Nginx/Caddy sebagai jalur cadangan |

**RTO/RPO yang realistis untuk desain ini:**

- RTO: ± 10 menit (buat instance baru → `install-n8n-aws.sh` → `restore.sh` → tunnel).
- RPO: sebesar interval backup (target 24 jam; arsipkan sebelum setiap upgrade).

---

## 6. Yang sengaja tidak dipakai (dan kapan harus berubah)

| Tidak dipakai | Kapan harus pindah |
|---|---|
| Auto Scaling Group | Ketika n8n jadi *stateless* (Postgres + queue mode + Redis) |
| RDS PostgreSQL | Eksekusi > 100 rb/hari, butuh PITR, atau multi-node |
| ECS/EKS | Ketika ada > 3 service yang perlu orkestrasi & rolling deploy |
| ALB + ACM | Ketika perlu WAF/GeoMatch milik AWS atau SLA Cloudflare tidak cukup |
| Terraform | **Segera** — begitu ada instance kedua atau environment staging |
| CloudWatch agent | Ketika butuh log terpusat & alarm tanpa login SSH |

Ini bukan kekurangan implementasi; ini pencatatan sisa utang teknis yang sadar.

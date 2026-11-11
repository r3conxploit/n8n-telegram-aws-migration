# Architecture Decision Records

Format: konteks → opsi → keputusan → konsekuensi. Setiap ADR menyebut apa yang **ditolak**,
karena keputusan tanpa alternatif bukan keputusan.

---

## ADR-001 — EC2 `t3.micro` + Docker sebagai platform

**Konteks.** n8n menyimpan state (sqlite + encryption key), butuh proses long-running untuk
scheduler/queue, dan menulis ke filesystem. Beban nyata: < 1 request/detik, 2 workflow aktif,
104 eksekusi per 6 jam.

**Opsi.**

| Opsi | Kelebihan | Kekurangan |
|---|---|---|
| **EC2 + Docker** | Murah, persisten, kontrol penuh, cepat dipahami | Patching OS jadi tanggung jawab kita |
| ECS Fargate | Tanpa server | Butuh EFS untuk state, ALB untuk ingress, biaya ± 3× untuk beban ini |
| Lambda | Skala otomatis, bayar per request | Tidak cocok: n8n server, bukan fungsi; editor & scheduler tidak jalan |
| Lightsail | Murah & sederhana | Ekosistem IAM/VPC/CloudWatch terbatas |
| Laptop + tunnel (status quo) | Gratis | Uptime = uptime laptop; IP/koneksi tidak stabil; ini masalahnya |

**Keputusan.** EC2 `t3.micro`, Ubuntu 26.04 LTS, ap-southeast-2 (dekat pengguna, latensi Telegram
↔ webhook rendah).

**Konsekuensi.** (+) Biaya ± $13/bln, kontrol penuh, migrasi ≤ 6 menit. (−) Kita pemilik OS
patching, backup, dan monitoring. Batas jelas: > 10 workflow aktif atau butuh HA → lihat ADR-004.

---

## ADR-002 — Runtime Docker dengan image resmi yang di-pin

**Konteks.** Versi n8n di laptop berubah-ubah mengikuti `npm i -g`; upgrade bisa mematahkan
workflow tanpa jejak versi.

**Opsi.** (a) `npm i -g n8n` di host · (b) Docker `docker.n8n.io/n8nio/n8n:<versi>` · (c) build image
sendiri.

**Keputusan.** Docker, tag eksplisit `2.38.7` (bukan `latest`).

**Konsekuensi.** (+) Versi reproducible, rollback = ganti tag, host bersih dari Node global,
`--restart unless-stopped` menangani reboot. (−) Butuh pemahaman volume & UID 1000 (lihat ADR-006
dan troubleshooting #5).

---

## ADR-003 — Cloudflare Tunnel sebagai satu-satunya ingress

**Konteks.** Butuh HTTPS di domain sendiri tanpa membuka port aplikasi, tanpa biaya ALB, dan
tanpa mengelola sertifikat di server.

**Opsi.**

| Opsi | Biaya | Port inbound | Kompleksitas |
|---|---|---|---|
| **Cloudflare Tunnel** | $0 | Tidak ada (outbound 7844) | Rendah |
| ALB + ACM | ± $18/bln + LCU | 443 publik | Sedang (target group, health check, SG) |
| Nginx + Let's Encrypt | $0 | 80/443 publik | Sedang (renewal, CSP, TLS config) |
| API Gateway + Lambda | per request | Tidak | Tinggi (rewrite n8n) |

**Keputusan.** Cloudflare Tunnel, `no-autoupdate: true`, ingress hanya untuk satu hostname,
`http_status:404` sebagai default deny.

**Konsekuensi.** (+) Nol port inbound, TLS & DNS gratis, IP asal tersembunyi. (−) Ketergantungan
pada akun Cloudflare; **502** menjadi gejala khas masalah ingress (bukan aplikasi). Mitigasi:
credential tunnel & `config.yml` ikut di-backup, dan jalur cadangan (DNS langsung + Caddy) dicatat
di `troubleshooting.md`.

---

## ADR-004 — Tetap SQLite, tunda Postgres

**Konteks.** n8n mendukung sqlite (default) dan Postgres/MySQL. Volume data 243 MB, single node,
tidak butuh HA atau PITR.

**Keputusan.** Pertahankan sqlite.

**Konsekuensi.** (+) Tanpa biaya RDS (± $15/bln minimum), restore = copy satu file, tidak ada
latensi jaringan. (−) Backup harus **quiesce** dulu (stop container), tidak ada concurrent writer,
tidak ada PITR. Pemicu pindah: > 100 rb eksekusi/hari, butuh queue mode multi-worker, atau butuh
backup point-in-time → RDS Postgres + `DB_TYPE=postgresdb`.

---

## ADR-005 — Unit backup = arsip `~/.n8n` (sqlite + WAL + `config`)

**Konteks.** Apa yang sebenarnya perlu dibawa agar instance baru setara dengan yang lama?

**Inventaris state:**

| File | Isi | Kalau hilang |
|---|---|---|
| `database.sqlite` (+`-wal`,`-shm`) | workflow, 7 credential terenkripsi, 104 eksekusi | semua workflow hilang |
| `config` (56 byte) | **encryption key** | credential tidak bisa didekripsi → buat ulang 7 kredensial |
| `n8nEventLog*.log` | audit | histori audit hilang (boleh) |

**Keputusan.** `tar czf` seluruh `.n8n` **setelah container/lokal dimatikan**, plus credential
tunnel Cloudflare dikirim terpisah lewat `scp`/stdin.

**Konsekuensi.** (+) Restore utuh termasuk riwayat eksekusi (24 MB). (−) Perlu downtime singkat
untuk konsistensi sqlite. Snapshot EBS dipakai sebagai lapis kedua, bukan pengganti.

---

## ADR-006 — Swap 2 GiB + heap Node 768 MB di mesin 1 GiB

**Konteks.** t3.micro punya 908 MiB RAM efektif. Saat `docker pull` + restore sqlite 243 MB,
kernel sempat OOM.

**Keputusan.** `/swapfile` 2 GiB (persist di `/etc/fstab`), `NODE_OPTIONS=--max-old-space-size=768`,
retensi eksekusi 14 hari.

**Konsekuensi.** (+) Tidak perlu t3.small (hemat ± $11/bln), pull & restore selesai. (−) Swap
memperlambat saat spike, dan memakai disk. Ambang naik kelas: swap terpakai > 1 GiB persisten atau
CPU credit habis.

---

## ADR-007 — Volume 28–30 GiB (bukan default 8 GiB)

**Konteks.** Percobaan ke-4 berhenti dengan `disk : 0 free`; image Docker (n8n ± 1 GB) + restore
243 MB + log eksekusi menghabiskan 8 GiB.

**Keputusan.** gp3 30 GiB, plus langkah `growpart`/`resize2fs` di `deploy.sh` untuk volume yang
diperbesar dari console tanpa rebuild.

**Konsekuensi.** (+) Ruang untuk 2–3 versi image dan backup lokal sementara. (−) +$2/bln; tetap
harus dipantau (alert 80 %).

---

## ADR-008 — Infrastruktur sebagai skrip bash idempoten

**Konteks.** Migrasi dijalankan 5 kali (iterasi perbaikan). Klik-per-klik console tidak bisa
diulang dan tidak bisa di-review.

**Keputusan.** `deploy.sh` sebagai orkestrator + 4 skrip tahap (`install`, `restore`, `tunnel`,
`backup-push`), semuanya `set -euo pipefail`, aman dijalankan ulang, dan berhenti pada kegagalan
alih-alih melanjutkan.

**Konsekuensi.** (+) Migrasi bisa direproduksi, log tunggal (`deploy.log`), jadi dokumentasi nyata.
(−) Bash bukan Terraform: tidak ada state, tidak ada drift detection, tidak ada plan/diff →
**utang teknis #1** untuk diganti Terraform/OpenTofu saat ada environment kedua.

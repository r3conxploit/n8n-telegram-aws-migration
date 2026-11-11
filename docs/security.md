# Keamanan

Dokumen ini mencatat **apa yang dilindungi**, **di mana disimpan**, dan **bagaimana memutar**
(rotate) bila bocor. Aturan dasar repo ini: tidak ada nilai rahasia yang masuk git — pernah.

---

## 1. Model ancaman singkat

| Aset | Dampak bila bocor | Vektor utama |
|---|---|---|
| Token bot Telegram (2 bot) | Penyerang bisa mengirim pesan sebagai bot, spam grup, eksfiltrasi data | commit `.env`, screenshot, log mentah |
| `config` n8n (encryption key) | **Semua 7 credential** (Sheets, Telegram, dsb.) dapat didekripsi | backup yang di-share, tar di folder publik |
| `database.sqlite` | Seluruh workflow + credential terenkripsi + riwayat eksekusi | file 243 MB ter-commit / ter-upload |
| Credential tunnel Cloudflare | Penyerang bisa mengarahkan hostname ke origin miliknya | file JSON di folder yang di-backup ke publik |
| SSH private key (`.pem`) | Akses root-capable ke instance | repo publik, clipboard, chat |
| Data operasional di Google Sheets | Kebocoran data internal | workflow yang di-export dengan data contoh |

**Prinsip yang dipakai:** kredensial hidup di mesin, bukan di repo; akses masuk minimal;
kegagalan harus berisik (502) bukan diam-diam.

---

## 2. Inventaris secret & lokasi

| Secret | Lokasi produksi | Lokasi cadangan | Rotasi |
|---|---|---|---|
| `TELEGRAM_BOT_*_TOKEN` | `/home/node/.n8n/database.sqlite` (credential n8n, terenkripsi) | bot Telegram → `/revoke` lalu `/newbot` | 90 hari atau saat dicurigai |
| `config` (encryption key n8n) | volume `n8n_data`, file `config` | arsip backup terenkripsi | **jangan** dirotasi tanpa re-enkripsi — n8n punya CLI untuk ini |
| Credential tunnel | `/etc/cloudflared/<id>.json` `0600 root:root` | arsip di workstation | `cloudflared tunnel rotate-secret` |
| SSH key pair | `~/.ssh/<key>.pem` `0600` di workstation | tidak | buat key pair baru, ganti di instance |
| Google service account | credential n8n (terenkripsi) | Google Cloud console | 90 hari |
| `.env` (dev/lokal) | workstation, **gitignored** | — | saat mesin dipensiunkan |

---

## 3. Kontrol yang sudah terpasang

1. **Tidak ada port aplikasi yang terbuka.** `-p 127.0.0.1:5678:5678`; Security Group hanya 22
   dari IP admin. `nmap` dari internet tidak menemukan 5678.
2. **Ingress default-deny.** `config.yml` hanya meng-ingress satu hostname; sisanya
   `http_status:404`.
3. **Secret tidak di repo.** `.gitignore` memblokir `.env`, `*.pem`, `*.key`, `*.sqlite*`,
   `*.tar.gz`, `*.cloudflared*`, `*credentials*.json`; ada pemeriksaan sebelum commit.
4. **Permission ketat.** credential tunnel `0600 root`, key `0600`, volume `1000:1000`.
5. **Versi runtime dipin.** `docker.n8n.io/n8nio/n8n:2.38.7` — bukan `latest`, sehingga
   supply-chain surprise tidak masuk diam-diam.
6. **`no-autoupdate: true`** pada cloudflared → update hanya lewat perubahan yang di-review.

---

## 4. Celah yang masih terbuka (jujur, bukan disembunyikan)

| # | Celah | Risiko | Perbaikan |
|---|---|---|---|
| S-1 | SSH 22 terbuka (walau dibatasi IP) | key bocor = akses host | **AWS SSM Session Manager** — tanpa inbound sama sekali + audit CloudTrail |
| S-2 | `config` disimpan di disk host, bukan secret manager | siapa pun dengan akses disk dapat kunci | pindah ke SSM Parameter Store / Secrets Manager + `_FILE` env |
| S-3 | Tanpa WAF/rate-limit di edge | endpoint webhook bisa di-spam | Cloudflare WAF + rate limiting rule per path |
| S-4 | Tanpa log terpusat / alert | kompromi bisa tidak terdeteksi | CloudWatch agent + alarm, atau shipper ke Loki |
| S-5 | n8n auth = akun lokal (email+password) | tidak ada MFA/SSO | aktifkan MFA n8n bila versi mendukung, atau Cloudflare Access di depan editor |
| S-6 | Patch OS manual | CVE menumpuk | `unattended-upgrades` + jadwal review bulanan |

Celah ini dicatat di repo karena portofolio yang hanya memuat keberhasilan bukan portofolio
engineering — melainkan brosur.

---

## 5. Prosedur bila secret bocor

```bash
# 1. CABUT DULU, jangan bersih-bersih dulu.
#    Telegram: /revoke di @BotFather (token lama langsung mati)
#    Cloudflare: cloudflared tunnel rotate-secret <TUNNEL_ID>  lalu redeploy credential
#    SSH: hapus public key di instance, buat key pair baru

# 2. Ganti nilai di tempat yang benar (bukan di repo)
#    - token bot  -> credential n8n (UI) atau .env di mesin + restart
#    - tunnel     -> /etc/cloudflared/<id>.json baru + systemctl restart cloudflared

# 3. Kalau sudah ter-commit / ter-push:
git log --all --oneline -- .env            # temukan commit
#    -> anggap publik. rotate (langkah 1) WAJIB, bukan opsional.
#    -> git rm --cached TIDAK cukup: history masih menyimpan blob.
#    -> purge dengan git filter-repo, lalu force-push SETELAH rotasi selesai.
```

Aturan turunan: **rotasi dulu, bersih-bersih belakangan.** Membersihkan history tidak
membatalkan kebocoran yang sudah terjadi.

---

## 6. Hardening lanjutan (checklist 30 menit)

```bash
# a) nonaktifkan login password SSH (key only)
$SSH 'sudo sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config && sudo systemctl reload ssh'

# b) unattended security updates
$SSH 'sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades'

# c) firewall lokal (defense in depth, tetap izinkan 22 dari IP admin)
$SSH 'sudo apt-get install -y ufw && sudo ufw default deny incoming && \
      sudo ufw allow from <IP_ADMIN> to any port 22 proto tcp && sudo ufw --force enable'

# d) audit docker: pastikan tidak ada container lain yang expose 0.0.0.0
$SSH 'docker ps --format "{{.Names}} {{.Ports}}"'

# e) pastikan IMDSv2 wajib (blokir SSRF ke metadata)
aws ec2 modify-instance-metadata-options --instance-id <id> \
  --http-tokens required --http-put-response-hop-limit 1
```

---

## 7. Untuk repo publik ini

- Semua hostname yang bisa diidentifikasi disamarkan (`n8n.<domain>`), IP instance dan ID
  instance tidak dipublikasikan.
- `.env.example` hanya berisi nama variabel.
- Contoh payload di `bot/example-payload.json` **sintetis** — nomor WO, SN, NIK, nama teknisi
  semuanya fiktif. Tidak ada data pelanggan, mitra, atau karyawan di repo ini.
- Tidak ada workflow JSON yang di-export mentah: export n8n menyertakan ID credential dan
  struktur internal. Kalau perlu berbagi workflow, sanitasi dulu field `credentials`.

# Sisi Telegram — dua bot, satu backend n8n

Lapisan ini sengaja dipisah dari dokumen cloud karena perannya sederhana: **menerima pesan grup,
meneruskannya ke webhook n8n, lalu membalas hasilnya**. Semua logika berat ada di n8n.

> Kode parser produksi tidak disertakan di repo publik ini (memuat aturan bisnis internal).
> Yang disertakan adalah **kontrak payload** dan alur, supaya arsitekturnya bisa dipahami
> dan direplikasi.

---

## 1. Dua bot, dua domain data

| Bot | Fungsi | Field kunci | Tujuan |
|---|---|---|---|
| `bot-material` | Pencatatan pengeluaran material | `NO WO`, `ID RESERVASI`, `KODE BARANG`, `BARANG KELUAR`, `MITRA`, `NIK` | Google Sheets (append 1 baris/item) |
| `bot-nte` | Pencatatan perangkat masuk/keluar | `NO IDO`, `SN - STBID`, `MAC`, `NO DUS`, `NAMA TEKNISI`, `TANGGAL MASUK/KELUAR` | Google Sheets (append 1 baris/unit) |

Dipisah karena: token terisolasi (satu bot bocor ≠ dua bot lumpuh), format pesan berbeda, dan
routing workflow di n8n bisa dipilih dari `kind` tanpa parsing ulang.

---

## 2. Alur

```text
Grup Telegram
   │  pesan teks / foto struk
   ▼
Bot (long polling ATAU webhook)
   │  POST https://n8n.<domain>/webhook/<path>   ← lewat Cloudflare Tunnel
   ▼
n8n: Webhook → Switch(kind) → Code node "Parser L0"
   │
   ├─ semua field dikenali  → Google Sheets append (0 token, 0 ms)
   └─ ada alias tak dikenal → L1 fallback (LLM) → tandai _jalur="L1" untuk audit
   ▼
Balasan ke grup: ringkasan baris yang tertulis / field yang perlu dikoreksi
```

**Kenapa parsing deterministik dulu (L0)?** Pesan operasional berpola tetap: alias field +
posisi nilai. Parser regex/alias-map menyelesaikannya tanpa inferensi model — biaya 0, hasil
identik setiap kali, dan bisa diuji. Model hanya dipakai untuk kasus yang benar-benar ambigu.

---

## 3. Kontrak payload (webhook)

Contoh lengkap & sintetis: [`example-payload.json`](example-payload.json).

```json
{
  "kind": "nte",
  "message": {
    "from": { "id": 123456789, "username": "teknisi_contoh" },
    "chat": { "id": -1001234567890, "title": "GUDANG - CONTOH" },
    "text": "TANGGAL MASUK 2026-01-05 NO IDO IDO-0001 ..."
  }
}
```

Field yang dibaca workflow:

| Field | Wajib | Keterangan |
|---|---|---|
| `kind` | ya | `material` \| `nte` — menentukan workflow tujuan |
| `message.text` | ya | teks mentah; parser memetakan alias → nama kolom sheet |
| `message.from.id` | tidak | allowlist pengirim (mencegah siapa pun di grup menulis) |
| `message.chat.id` | tidak | balasan dikirim ke grup yang sama |

**Prinsip kontrak:** bot tidak mengirim data yang sudah "setengah diparsing". Semua keputusan
bentuk data terjadi di n8n, sehingga aturan bisa diubah tanpa menyentuh kode bot/Redeploy.

---

## 4. Token & konfigurasi

`.env` bot (tidak pernah di-commit):

```dotenv
TELEGRAM_BOT_MATERIAL_TOKEN=<token dari BotFather>
TELEGRAM_BOT_NTE_TOKEN=<token dari BotFather>
WEBHOOK_DOMAIN=https://n8n.<domain>
N8N_BASE_URL=https://n8n.<domain>
```

Praktik:

- Token disimpan **hanya** di mesin/credential n8n; rotasi = `/revoke` di BotFather → update
  credential → re-`setWebhook`.
- Webhook didaftarkan ke hostname publik (bukan IP), karena ingress satu-satunya adalah tunnel.
- `allowed_chat_id`/allowlist NIK dicek di n8n, bukan di bot — supaya audit trail-nya ada di
  eksekusi workflow (bisa dilihat & di-replay).

---

## 5. Kalau bot tidak merespons — urutan cek

```bash
# 1. token valid?
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"

# 2. webhook terdaftar & sehat?
curl -s "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"

# 3. backend hidup? (ini domain cloud, bukan bot)
curl -s -o /dev/null -w '%{http_code}\n' https://n8n.<domain>/healthz

# 4. eksekusi terakhir sukses?  n8n UI > Executions > filter "Error"
```

Pembagian tanggung jawab ini yang membuat debugging cepat: `getWebhookInfo` menunjukkan error
dari sisi Telegram (mis. `Wrong response from the webhook: 502`), yang langsung menunjuk ke
dokumen ingress (`docs/troubleshooting.md` T6), bukan ke kode bot.

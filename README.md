# Sayspack Management System

Aplikasi manajemen operasional & keuangan untuk usaha sablon cup Sayspack.
Stack: Next.js 15 + TypeScript + Tailwind CSS 4, Supabase (PostgreSQL, Auth, Storage), deploy ke Vercel.

Arsitektur, metode akuntansi, skema, asumsi, dan status tiap tahap: **[docs/ARSITEKTUR.md](docs/ARSITEKTUR.md)**.

## Struktur

```
supabase/migrations/   SQL skema, fungsi, RLS (jalankan berurutan)
supabase/seed/         Data DEMO opsional
supabase/tests/        Uji alur kritis (PostgreSQL lokal)
scripts/test-db.sh     Menjalankan uji database
src/app/               Halaman & server actions
src/lib/               Supabase client, auth, format rupiah/tanggal, upload bukti
```

## Setup Supabase (sekali)

1. Buat project di https://supabase.com (region Singapore paling dekat).
2. **SQL Editor** → jalankan isi file berikut **berurutan**:
   `20261022000001_foundation.sql`, `..._0002_operations.sql`, `..._0003_reporting_security.sql`, `..._0004_storage.sql`.
   (Atau dengan Supabase CLI: `supabase link --project-ref <ref>` lalu `supabase db push`.)
3. **Authentication → Sign In / Providers → Email**: matikan **Allow new users to sign up**. Akun dibuat manual oleh owner.
4. **Authentication → Users → Add user**: buat akun owner (email + kata sandi, centang *Auto Confirm*).
   User **pertama** otomatis menjadi `owner`. User berikutnya berstatus `pending` (tanpa akses).
5. Untuk investor nanti: buat user baru, lalu di SQL Editor:
   `update profiles set role = 'investor' where id = (select id from auth.users where email = 'email-investor');`
6. (Opsional) Data contoh: jalankan `supabase/seed/seed_demo.sql`. Semua berlabel `[DEMO]`.
   Hapus dengan login sebagai owner lalu memanggil `purge_demo_data()` (UI-nya menyusul di Tahap 8).

## Jalankan lokal

```bash
cp .env.example .env.local   # isi URL & anon/publishable key dari Project Settings → API
npm install
npm run dev                  # http://localhost:3000
```

Langkah pertama setelah login: **Akun kas** → tambah akun (Kas Tunai, Bank) → **Transaksi** → catat *Saldo awal* tiap akun dan *Setoran modal investor* saat dana diterima.

## Deploy ke Vercel

1. Push repo ke GitHub, lalu **Import Project** di Vercel.
2. Isi Environment Variables: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`. **Jangan** menambahkan service_role key.
3. Deploy. Di Supabase → Authentication → URL Configuration, isi Site URL dengan domain Vercel.

## Pengujian

```bash
npm run typecheck && npm run build
# Uji database (butuh PostgreSQL 16 lokal):
PGHOST=localhost PGUSER=postgres ./scripts/test-db.sh
```
Uji database mencakup: anti dobel transaksi, penerimaan pembelian sekali, stok tidak minus, pesanan → produksi → kirim → lunas, upah harian (tarif di luar rentang wajib alasan, bayar sebagian/lunas), komisi per cup & snapshot tarif, depresiasi tanpa memotong kas, laba-rugi, tutup buku + kunci periode, bagi hasil, dan hak akses investor/pending.

## Backup & pemulihan

- **Otomatis:** Supabase menyimpan backup harian (paket Pro: point-in-time recovery). Cek di Database → Backups.
- **Manual (disarankan bulanan setelah tutup buku):**
  ```bash
  pg_dump "postgresql://postgres:[PASSWORD]@db.[REF].supabase.co:5432/postgres" \
    --schema=public --schema=auth -Fc -f sayspack-$(date +%F).dump
  ```
- **Pulihkan** ke project baru (tidak perlu menjalankan migrasi lagi): `pg_restore --clean --if-exists -d "<connection-string>" sayspack-YYYY-MM-DD.dump`, lalu unduh ulang file bucket `bukti` (Storage) bila perlu.
- Laporan per bulan juga bisa diunduh sebagai CSV dari menu **Laporan**.

## Keamanan

- Aplikasi hanya memakai anon/publishable key + sesi user. Semua aturan ditegakkan di database (RLS + fungsi yang memeriksa role), bukan hanya disembunyikan di tampilan.
- Transaksi yang sudah diposting tidak bisa dihapus/diubah; koreksi dengan pembatalan beralasan (tercatat di `audit_log`).
- Bukti transaksi disimpan di bucket privat dan dibuka lewat signed URL 60 detik.

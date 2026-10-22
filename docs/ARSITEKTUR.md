# Arsitektur, Skema Database, dan Asumsi

## 1. Arsitektur

```
Browser (HP/desktop)
   │  HTTPS
   ▼
Next.js 15 (App Router, TypeScript) di Vercel
   ├─ Server Components  → baca data (sesi user, RLS berlaku)
   ├─ Server Actions     → validasi Zod → panggil fungsi RPC Postgres
   └─ middleware.ts      → segarkan sesi, arahkan ke /masuk bila belum login
   │  anon/publishable key + JWT user (TIDAK ADA service_role key di aplikasi)
   ▼
Supabase
   ├─ Auth (email + kata sandi, signup publik DIMATIKAN)
   ├─ PostgreSQL
   │    ├─ Tabel + constraint + trigger (penomoran, kunci periode, audit, anti-hapus)
   │    ├─ Fungsi RPC atomik (SECURITY DEFINER + cek owner) untuk semua uang & stok
   │    └─ Row Level Security per role
   └─ Storage bucket privat "bukti" (signed URL 60 detik)
```

Aturan inti integritas data:

| Risiko | Pencegahan |
|---|---|
| Kas berkurang dua kali | Setiap pembayaran (upah, komisi, pesanan, pemasok, bagi hasil) membuat tepat satu baris `cash_transactions`; unique index `(source_type, source_id)` + `client_ref` anti dobel klik. |
| Stok berkurang dua kali | Stok hanya berubah lewat `stock_movements` (trigger mengunci baris produk). `qty_on_hand` tidak bisa diubah langsung. Penerimaan pembelian dikunci status. |
| Data hilang diam-diam | Trigger `forbid_delete` di semua ledger; koreksi = pembatalan + alasan, tercatat di `audit_log`. |
| Laporan berubah setelah tutup buku | Trigger `guard_closed_period` menolak transaksi bertanggal periode tertutup; laba periode disimpan sebagai snapshot. |
| Akses lewat API langsung | RLS: klien tidak punya izin INSERT/UPDATE ke ledger; semua lewat RPC yang memeriksa role. Fungsi internal (`_post_cash`) di-revoke dari klien. |

## 2. Metode akuntansi (konsisten di semua laporan)

Laba-rugi memakai **akrual sederhana**; arus kas memakai **uang aktual**. Satu kejadian hanya diakui di satu baris L/R:

| Pos | Diakui di L/R saat | Kas berubah saat |
|---|---|---|
| Omzet | Pesanan mencapai status pengakuan (default **selesai**, bisa diubah ke **terkirim**) | DP/pelunasan dicatat (bukan omzet) |
| HPP cup & bahan | Bersamaan dengan omzet pesanan tsb (nilai stok keluar, metode rata-rata tertimbang) | Pembelian dibayar ke pemasok |
| Upah produksi | Tanggal kerja (kehadiran) | Tombol Bayar Upah |
| Komisi marketing | Bersamaan dengan omzet (fee/cup × cup terkirim bersih) | Pembayaran komisi |
| Beban operasional | Tanggal transaksi | Tanggal transaksi |
| Mesin/aset | Depresiasi bulanan (garis lurus) | Pembelian aset dibayar |
| Cadangan & bagi hasil | **Bukan beban** — alokasi laba setelah tutup buku | Saat bagi hasil benar-benar ditransfer |
| Modal investor | **Bukan pendapatan** | Saat dana diterima |

Contoh dari uji otomatis (September 2026): omzet 4.500.000 − HPP 1.935.000 − upah 140.000 − komisi 250.000 − listrik 200.000 − depresiasi 500.000 = **laba 1.475.000** → cadangan 147.500, investor 663.750, pemilik 663.750. Kas akhir 21.110.000 (berbeda dari laba — itu memang seharusnya).

## 3. Skema database

**Fondasi:** `profiles` (role: owner/investor/staff/pending), `app_settings`, `audit_log`, `doc_counters`, `profit_sharing_rules` (insert-only = riwayat), `accounting_periods`.

**Keuangan:** `cash_accounts`, `transaction_categories` (kolom `report_group` menentukan masuk L/R atau tidak), `cash_transactions` (ledger tunggal kas), `reconciliations`.

**Persediaan:** `products`, `stock_movements`, `purchases`, `purchase_items`, `purchase_payments`.

**Penjualan:** `customers`, `suppliers`, `marketers`, `orders` (fee/cup snapshot, status, qty produksi/cacat/retur), `order_items`, `order_status_history`, `order_payments`, `commission_payments`.

**Produksi:** `workers`, `work_days` (tarif aktual per hari), `wage_payments`.

**Aset:** `assets`, `depreciation_entries`. **Bagi hasil:** `profit_payouts`.

**View:** `v_account_balances`, `v_inventory`, `v_purchase_balances`, `v_order_summary`, `v_work_day_wages`, `v_order_commissions`, `v_asset_book_values`.

**RPC utama:** `record_cash_transaction`, `void_cash_transaction`, `transfer_between_accounts`, `record_reconciliation`, `record_stock_adjustment`, `record_stock_opname`, `reverse_stock_movement`, `receive_purchase`, `pay_purchase`, `set_order_status`, `use_materials`, `record_production`, `deliver_order`, `record_order_return`, `record_order_payment`, `void_order_payment`, `pay_wage`, `void_wage_payment`, `pay_commission`, `void_commission_payment`, `post_depreciation`, `profit_and_loss`, `cash_flow`, `dashboard_summary`, `period_close_preview`, `close_period`, `pay_profit_share`, `purge_demo_data`.

## 4. Asumsi yang perlu dikonfirmasi pemilik

Semua bisa diubah lewat pengaturan/aturan tanpa mengubah kode, kecuali disebut lain.

1. **Kapan omzet diakui:** default saat status **selesai**. Alternatif: **terkirim**. (`app_settings.revenue_recognition`)
2. **Dasar komisi marketing:** default **terkirim** (cup terkirim − retur). Alternatif **lunas** (proporsional terhadap pembayaran pelanggan). Ditandai *belum disetujui* sampai owner mengonfirmasi. Tarif tetap snapshot per pesanan.
3. **Kebijakan saat rugi:** belum disepakati → sistem tidak membagi rugi; bulan rugi hanya dicatat, bagi hasil 0. Perlu kesepakatan tertulis (apakah rugi ditutup cadangan, dibawa ke bulan berikutnya, dst.).
4. **Bagi hasil:** 10% cadangan, sisa 50:50 (berlaku mulai 1 Jan 2026 sebagai titik awal — **mohon isi tanggal perjanjian yang benar**).
5. **Mesin sablon Rp34.000.000:** contoh uji memakai umur 60 bulan, residu Rp4.000.000. **Ini hanya contoh** — isi estimasi sendiri (umur pakai realistis, nilai jual bekas). Apakah ada biaya kirim/instalasi yang ikut dikapitalisasi?
6. **Upah:** semua hari kerja dihitung sebagai beban produksi periode itu (bukan dialokasikan per pesanan di L/R). Kaitan ke pesanan disimpan untuk analisis margin per pesanan saja, agar tidak dihitung dua kali.
7. **Retur cup bersablon** dianggap tidak kembali ke stok (umumnya tidak bisa dijual ulang); dicatat sebagai jumlah retur + potongan tagihan.
8. **Penilaian persediaan:** rata-rata tertimbang (moving average).
9. **Zona waktu:** Asia/Jakarta (WIB).
10. Apakah modal Rp55 juta diterima sekaligus atau bertahap? Sistem mencatat sesuai transaksi aktual; angka perjanjian hanya pembanding.

## 5. Rencana tahap & status

| Tahap | Isi | Status |
|---|---|---|
| 1 | Auth, skema database lengkap, RLS, audit, kunci periode | **Selesai & teruji** (71 assertion) |
| 2 | Dashboard, transaksi kas, akun, transfer, rekonsiliasi, laporan L/R & arus kas + CSV | **Selesai** (UI build lolos; belum diuji ke Supabase sungguhan) |
| 3 | UI produk, pembelian, stok, opname | Database siap & teruji; UI belum |
| 4 | UI pelanggan, pesanan, produksi, pengiriman, pembayaran | Database siap & teruji; UI belum |
| 5 | UI pekerja harian (tombol Bayar Upah) & marketing | Database siap & teruji; UI belum |
| 6 | UI aset & depresiasi | Database siap & teruji; UI belum |
| 7 | UI tutup buku, bagi hasil, laporan lengkap, ekspor Excel/PDF | Database siap & teruji; UI belum |
| 8 | Manajemen user (undang investor), pengaturan, hapus data DEMO | Database siap; UI belum |

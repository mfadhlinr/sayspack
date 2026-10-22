-- Uji alur kritis Sayspack. Jalankan setelah migrasi di database uji (lihat docs/TESTING.md).
-- Semua skenario memakai bulan September 2026 (bulan lampau) agar bisa ditutup.
\set ON_ERROR_STOP 1
\set QUIET 1

create schema if not exists t;
grant usage on schema t to authenticated;
create or replace function t.expect_error(p_sql text, p_pattern text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if sqlerrm !~* p_pattern then raise exception 'Error salah. Harap "%", dapat "%"', p_pattern, sqlerrm; end if;
    raise notice '  ok (ditolak): %', sqlerrm; return;
  end;
  raise exception 'Seharusnya gagal (%): %', p_pattern, p_sql;
end $$;
create or replace function t.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if not coalesce(p_cond, false) then raise exception 'GAGAL: %', p_msg; end if;
  raise notice '  ok: %', p_msg;
end $$;
grant execute on all functions in schema t to authenticated;
create table t.ids (k text primary key, v uuid);
grant all on t.ids to authenticated;

-- Pengguna: pertama jadi owner, berikutnya pending.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000001', 'owner@sayspack.test');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000002', 'investor@sayspack.test');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000003', 'orang@lain.test');
select t.ok((select role from profiles where id = '00000000-0000-0000-0000-000000000001') = 'owner', 'user pertama = owner');
select t.ok((select role from profiles where id = '00000000-0000-0000-0000-000000000003') = 'pending', 'user berikutnya = pending');
update profiles set role = 'investor' where id = '00000000-0000-0000-0000-000000000002';

-- ===================== sebagai OWNER =====================
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '1. Akun kas, modal, aset'
insert into cash_accounts (name, kind) values ('Kas Tunai', 'kas'), ('Bank BCA', 'bank');
insert into t.ids select 'kas', id from cash_accounts where name = 'Kas Tunai';
insert into t.ids select 'bank', id from cash_accounts where name = 'Bank BCA';
select record_cash_transaction('2026-09-01', 'in', (select v from t.ids where k='bank'),
  (select id from transaction_categories where code='modal_investor'), 55000000, 'transfer', 'Modal awal investor',
  null, null, null, null, 'bukti/modal.jpg', '11111111-0000-0000-0000-000000000001');
-- dobel klik dengan client_ref sama → tidak dobel
select record_cash_transaction('2026-09-01', 'in', (select v from t.ids where k='bank'),
  (select id from transaction_categories where code='modal_investor'), 55000000, 'transfer', 'Modal awal investor',
  null, null, null, null, 'bukti/modal.jpg', '11111111-0000-0000-0000-000000000001');
select t.ok(account_balance((select v from t.ids where k='bank')) = 55000000, 'modal tercatat sekali (anti dobel)');
select t.expect_error($$select record_cash_transaction('2026-09-01','out',(select v from t.ids where k='bank'),
  (select id from transaction_categories where code='bayar_upah'),1000,'tunai','x')$$, 'dicatat otomatis');
select t.expect_error($$insert into cash_transactions (trx_date,direction,account_id,category_id,amount,payment_method,description)
  values ('2026-09-01','in',(select v from t.ids where k='bank'),(select id from transaction_categories where code='modal_owner'),1,'tunai','x')$$,
  'row-level security');

select record_cash_transaction('2026-09-01', 'out', (select v from t.ids where k='bank'),
  (select id from transaction_categories where code='beli_aset'), 34000000, 'transfer', 'Pembelian mesin sablon',
  null, null, null, null, 'bukti/mesin.jpg');
insert into assets (name, acquisition_date, acquisition_cost, useful_life_months, residual_value, depreciation_start, cash_transaction_id)
values ('Mesin sablon cup', '2026-09-01', 34000000, 60, 4000000, '2026-09-01',
  (select id from cash_transactions where description = 'Pembelian mesin sablon'));
select t.ok((select monthly_depreciation_initial from v_asset_book_values) = 500000, 'depresiasi/bulan = (34jt-4jt)/60 = 500.000');

\echo '2. Produk, pembelian, penerimaan, pembayaran pemasok'
insert into suppliers (name) values ('Toko Cup Jaya');
insert into products (sku, name, item_type, material, size_oz, unit, min_stock) values
  ('CUP-PET-12', 'Cup PET 12 oz', 'cup', 'PET', 12, 'pcs', 5000),
  ('INK-HTM', 'Tinta sablon hitam', 'tinta', null, null, 'kg', 1);
insert into t.ids select 'cup', id from products where sku='CUP-PET-12';
insert into t.ids select 'ink', id from products where sku='INK-HTM';
insert into purchases (supplier_id, purchase_date) values ((select id from suppliers limit 1), '2026-09-02');
insert into t.ids select 'po', id from purchases limit 1;
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values
  ((select v from t.ids where k='po'), (select v from t.ids where k='cup'), 10000, 350),
  ((select v from t.ids where k='po'), (select v from t.ids where k='ink'), 2, 150000);
select t.ok((select qty_on_hand from products where sku='CUP-PET-12') = 0, 'stok belum bertambah sebelum diterima');
select receive_purchase((select v from t.ids where k='po'), '2026-09-03');
select t.expect_error($$select receive_purchase((select v from t.ids where k='po'), '2026-09-03')$$, 'sudah berstatus');
select t.ok((select qty_on_hand from products where sku='CUP-PET-12') = 10000, 'stok cup = 10.000 (sekali saja)');
select t.expect_error($$update products set qty_on_hand = 99 where sku='CUP-PET-12'$$, 'hanya berubah lewat');
select pay_purchase((select v from t.ids where k='po'), '2026-09-03', 3800000, (select v from t.ids where k='bank'), 'transfer');
select t.expect_error($$select pay_purchase((select v from t.ids where k='po'), '2026-09-03', 1, (select v from t.ids where k='bank'), 'transfer')$$, 'melebihi sisa utang');

\echo '3. Pesanan, produksi, pengiriman'
insert into customers (name, phone) values ('Kopi Senja', '0812');
insert into marketers (name) values ('Dina (freelance)');
insert into orders (order_date, customer_id, marketer_id, fee_per_cup, commission_basis, status)
values ('2026-09-05', (select id from customers limit 1), (select id from marketers limit 1), 50, 'terkirim', 'penawaran');
insert into t.ids select 'order', id from orders limit 1;
insert into order_items (order_id, product_id, qty, unit_price, print_colors, print_spec)
values ((select v from t.ids where k='order'), (select v from t.ids where k='cup'), 5000, 900, 1, 'Logo 1 warna');
select t.ok((select total from orders) = 4500000, 'total pesanan 5.000 × 900 = 4.500.000');
select t.ok((select order_no from orders) = 'SP-2609-0001', 'nomor pesanan otomatis');
select t.expect_error($$update orders set status = 'selesai'$$, 'lewat tombol ubah status');
select t.ok((select revenue from (select (profit_and_loss('2026-09-01','2026-09-30')->>'revenue')::numeric revenue) x) = 0,
  'penawaran belum dihitung omzet');
select set_order_status((select v from t.ids where k='order'), 'dikonfirmasi', null, '2026-09-05');
select record_order_payment((select v from t.ids where k='order'), '2026-09-05', 'dp', 2000000, (select v from t.ids where k='bank'),
  'transfer', null, 'bukti/dp.jpg', null, '22222222-0000-0000-0000-000000000001');
select record_order_payment((select v from t.ids where k='order'), '2026-09-05', 'dp', 2000000, (select v from t.ids where k='bank'),
  'transfer', null, 'bukti/dp.jpg', null, '22222222-0000-0000-0000-000000000001');
select t.ok(order_paid((select v from t.ids where k='order')) = 2000000, 'DP tercatat sekali');
select set_order_status((select v from t.ids where k='order'), 'produksi', null, '2026-09-06');
select t.expect_error($$insert into order_items (order_id, qty, unit_price) values ((select v from t.ids where k='order'), 1, 1)$$, 'setelah masuk produksi');
select use_materials((select v from t.ids where k='order'), '2026-09-06', jsonb_build_array(jsonb_build_object('product_id', (select v from t.ids where k='ink'), 'qty', 1)));
select record_production((select v from t.ids where k='order'), '2026-09-06', 5000, 100, (select v from t.ids where k='cup'));
select t.expect_error(format($$select deliver_order(%L, '2026-09-08', jsonb_build_array(jsonb_build_object('order_item_id', %L, 'qty', 5001)))$$,
  (select v from t.ids where k='order'), (select id from order_items limit 1)), 'melebihi pesanan');
select deliver_order((select v from t.ids where k='order'), '2026-09-08',
  jsonb_build_array(jsonb_build_object('order_item_id', (select id from order_items limit 1), 'qty', 5000)));
select t.ok((select qty_on_hand from products where sku='CUP-PET-12') = 4900, 'stok cup 10.000 − 100 cacat − 5.000 kirim = 4.900');
select t.ok((select count(*) from stock_movements where movement_type='pengiriman') = 1, 'pengiriman mengurangi stok sekali');
select t.ok((select is_low_stock from v_inventory where sku='CUP-PET-12'), 'peringatan stok minimum aktif (4.900 ≤ 5.000)');
select set_order_status((select v from t.ids where k='order'), 'terkirim', null, '2026-09-08');
select record_order_payment((select v from t.ids where k='order'), '2026-09-10', 'pelunasan', 2500000, (select v from t.ids where k='bank'), 'transfer');
select t.expect_error($$select record_order_payment((select v from t.ids where k='order'), '2026-09-10', 'lanjutan', 1, (select v from t.ids where k='bank'), 'transfer')$$, 'melebihi sisa tagihan');
select set_order_status((select v from t.ids where k='order'), 'selesai', null, '2026-09-10');
select t.ok((select revenue_recognized_on from orders) = '2026-09-10', 'omzet diakui saat selesai');
select t.expect_error(format($$select set_order_status(%L, 'batal', 'coba batal')$$, (select v from t.ids where k='order')), 'sudah selesai');

\echo '4. Upah harian'
insert into workers (name, default_rate) values ('Asep', 60000), ('Ujang', 50000);
insert into work_days (worker_id, work_date, rate, order_id) values
  ((select id from workers where name='Asep'), '2026-09-06', 60000, (select v from t.ids where k='order'));
select t.expect_error($$insert into work_days (worker_id, work_date, rate) values ((select id from workers where name='Ujang'), '2026-09-06', 80000)$$, 'di luar rentang');
insert into work_days (worker_id, work_date, rate, rate_note) values ((select id from workers where name='Ujang'), '2026-09-06', 80000, 'Lembur sampai malam');
select t.expect_error($$insert into work_days (worker_id, work_date, rate) values ((select id from workers where name='Asep'), '2026-09-06', 60000)$$, 'duplicate|unik|unique');
select t.ok((select account_balance((select v from t.ids where k='kas'))) = 0, 'upah belum dibayar → kas belum berkurang');
select t.ok((select sum(outstanding) from v_work_day_wages) = 140000, 'kewajiban upah 140.000');
select pay_wage((select id from work_days where rate = 60000), (select v from t.ids where k='kas'), 'tunai', null, null, null,
  '33333333-0000-0000-0000-000000000001', '2026-09-06 17:00+07');
select pay_wage((select id from work_days where rate = 60000), (select v from t.ids where k='kas'), 'tunai', null, null, null,
  '33333333-0000-0000-0000-000000000001', '2026-09-06 17:00+07');
select t.expect_error(format($$select pay_wage(%L, %L, 'tunai')$$, (select id from work_days where rate = 60000), (select v from t.ids where k='kas')), 'sudah lunas');
select pay_wage((select id from work_days where rate = 80000), (select v from t.ids where k='bank'), 'transfer', 30000, null, null, null, '2026-09-06 17:00+07');
select t.ok((select pay_status from v_work_day_wages where rate = 80000) = 'sebagian', 'status upah sebagian');
select pay_wage((select id from work_days where rate = 80000), (select v from t.ids where k='bank'), 'transfer', null, null, null, null, '2026-09-06 17:30+07');
select t.ok((select count(*) from cash_transactions t join transaction_categories c on c.id=t.category_id where c.code='bayar_upah') = 3, '3 pembayaran upah = 3 transaksi kas');

\echo '5. Komisi marketing'
select t.ok((select earned from v_order_commissions) = 250000, 'komisi 5.000 cup × 50 = 250.000');
select pay_commission((select v from t.ids where k='order'), '2026-09-12', 100000, (select v from t.ids where k='kas'), 'tunai');
select t.expect_error($$update orders set fee_per_cup = 60$$, 'tidak bisa diubah');
select pay_commission((select v from t.ids where k='order'), '2026-09-12', 150000, (select v from t.ids where k='bank'), 'transfer');
select t.expect_error(format($$select pay_commission(%L, '2026-09-12', 1, %L, 'tunai')$$, (select v from t.ids where k='order'), (select v from t.ids where k='kas')), 'melebihi komisi');
-- Kas tunai minus karena upah dibayar tunai tanpa saldo — catat setoran kas dari bank
select transfer_between_accounts('2026-09-06', (select v from t.ids where k='bank'), (select v from t.ids where k='kas'), 500000, 'tunai', 'Ambil kas kecil');

\echo '6. Beban operasional, pembatalan, audit'
select record_cash_transaction('2026-09-15', 'out', (select v from t.ids where k='kas'),
  (select id from transaction_categories where name='Listrik & air'), 200000, 'tunai', 'Token listrik', null, null, null, null, 'bukti/listrik.jpg');
select record_cash_transaction('2026-09-15', 'out', (select v from t.ids where k='kas'),
  (select id from transaction_categories where name='Konsumsi'), 99999, 'tunai', 'Salah input', null, null, null, null, 'bukti/x.jpg');
update cash_transactions set amount = 1 where description = 'Salah input';
delete from cash_transactions where description = 'Salah input';
select t.ok((select amount from cash_transactions where description = 'Salah input') = 99999, 'klien tidak bisa ubah/hapus transaksi langsung (RLS)');
reset role;
select t.expect_error($$update cash_transactions set amount = 1 where description = 'Salah input'$$, 'tidak bisa diubah');
select t.expect_error($$delete from cash_transactions where description = 'Salah input'$$, 'tidak boleh dihapus');
set role authenticated;
select void_cash_transaction((select id from cash_transactions where description = 'Salah input'), 'Nominal salah ketik');
select t.ok((select status from cash_transactions where description = 'Salah input') = 'void', 'transaksi dibatalkan, tetap ada jejaknya');
select t.expect_error(format($$select void_cash_transaction(%L, 'coba batal')$$, (select id from cash_transactions where source_type='wage_payment' limit 1)), 'modul lain');
select t.ok((select count(*) from audit_log where table_name='cash_transactions' and action='UPDATE') >= 1, 'audit trail pembatalan tercatat');

\echo '7. Kas & laba-rugi September'
-- Kas: 55jt − 34jt − 3,8jt + 4,5jt − 140rb upah − 250rb komisi − 200rb listrik = 21.110.000
select t.ok((select sum(balance) from v_account_balances) = 21110000, 'total kas = 21.110.000');
select t.ok((select balance from v_account_balances where name='Kas Tunai') = 500000 - 60000 - 100000 - 200000, 'saldo kas tunai benar');
select record_reconciliation((select v from t.ids where k='kas'), '2026-09-30', 140000, 'Hitung fisik');
select record_reconciliation((select v from t.ids where k='bank'), '2026-09-30', 20970000, 'Rekening koran');
select t.ok((select count(*) from reconciliations where difference = 0) = 2, 'rekonsiliasi cocok');
-- L/R: omzet 4.500.000; HPP 5.000×350 + 100×350 + tinta 150.000 = 1.935.000; upah 140.000; komisi 250.000;
--      listrik 200.000; depresiasi 500.000 (dicatat saat tutup buku) → laba 1.475.000
select t.ok((select (profit_and_loss('2026-09-01','2026-09-30')->>'cogs_materials')::numeric) = 1935000, 'HPP bahan = 1.935.000');
select t.ok((select (period_close_preview('2026-09-01')->'pnl'->>'net_profit')::numeric) = 1975000, 'laba sebelum depresiasi = 1.975.000');

\echo '8. Tutup buku & bagi hasil'
select t.expect_error($$select close_period('2026-09-01', 1975000)$$, 'Angka laba berubah');
select close_period('2026-09-01', 1475000, 'Tutup buku pertama');
select t.ok((select status from accounting_periods where period='2026-09-01') = 'closed', 'September ditutup');
select t.ok((select reserve_amount from accounting_periods) = 147500, 'cadangan 10% = 147.500');
select t.ok((select investor_amount from accounting_periods) = 663750, 'investor 45% = 663.750');
select t.ok((select owner_amount from accounting_periods) = 663750, 'pemilik 45% = 663.750');
select t.ok((select sum(balance) from v_account_balances) = 21110000, 'depresiasi & cadangan tidak mengurangi kas');
select t.ok((select count(*) from depreciation_entries) = 1, 'depresiasi tercatat sekali');
select t.ok(post_depreciation('2026-09-01') = 0, 'posting ulang depresiasi tidak dobel');
select t.expect_error($$select record_cash_transaction('2026-09-20','out',(select v from t.ids where k='kas'),
  (select id from transaction_categories where name='Konsumsi'),1000,'tunai','telat')$$, 'sudah ditutup');
select t.expect_error($$select close_period('2026-09-01', 1475000)$$, 'sudah ditutup');
select pay_profit_share('2026-09-01', 'investor', '2026-10-05', 663750, (select v from t.ids where k='bank'), 'transfer');
select t.expect_error($$select pay_profit_share('2026-09-01', 'investor', '2026-10-05', 1, (select v from t.ids where k='bank'), 'transfer')$$, 'Melebihi jatah');
select t.ok((select sum(balance) from v_account_balances) = 21110000 - 663750, 'pembayaran bagi hasil mengurangi kas sekali');
select t.ok((select (profit_and_loss('2026-10-01','2026-10-31')->>'net_profit')::numeric) = 0, 'bagi hasil bukan beban di L/R Oktober');
select t.expect_error($$select close_period('2026-10-01', 0)$$, 'Bulan berjalan');

\echo '9. Stok tidak boleh minus'
select t.expect_error(format($$select record_stock_adjustment(%L, '2026-10-02', 'rusak', -99999, null, 'Pecah')$$, (select v from t.ids where k='cup')), 'tidak cukup');
select record_stock_opname((select v from t.ids where k='cup'), '2026-10-02', 4890, 'Hitung fisik Oktober');
select t.ok((select qty_on_hand from products where sku='CUP-PET-12') = 4890, 'stock opname mencatat selisih −10');

-- ===================== sebagai INVESTOR =====================
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
set role authenticated;
\echo '10. Hak akses investor & pending'
select t.ok((select count(*) from cash_transactions) > 0, 'investor bisa baca transaksi kas');
select t.ok((select count(*) from orders) = 0, 'investor tidak bisa baca detail pesanan');
select t.ok((select count(*) from work_days) = 0, 'investor tidak bisa baca data pekerja');
select t.ok((select (dashboard_summary('2026-09-01','2026-09-30')->'pnl'->>'net_profit')::numeric) = 1475000, 'investor bisa lihat dashboard/L-R');
select t.expect_error($$select record_cash_transaction('2026-10-01','in',(select id from cash_accounts limit 1),(select id from transaction_categories where code='modal_owner'),1,'tunai','x')$$, 'Hanya owner');
select t.expect_error($$insert into customers (name) values ('x')$$, 'row-level');
select t.ok((select count(*) from audit_log) = 0, 'investor tidak bisa baca audit log');
select t.expect_error($$select _post_cash('2026-10-01','in',(select id from cash_accounts limit 1),'modal_owner',1,'tunai','x','x',gen_random_uuid())$$, 'permission denied');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
set role authenticated;
select t.ok((select count(*) from cash_transactions) = 0, 'user pending tidak bisa baca apa pun');
select t.expect_error($$select dashboard_summary('2026-09-01','2026-09-30')$$, 'Tidak punya akses');
reset role;

\echo 'SEMUA UJI LOLOS'

-- DATA DEMO (opsional). Semua baris berlabel is_demo = true dan nama diawali [DEMO].
-- Jalankan di Supabase SQL Editor. Hapus kapan saja dari menu Pengaturan → Hapus data DEMO
-- (atau: select purge_demo_data(); sebagai owner).
do $$
declare v_acc uuid; v_cust uuid; v_prod uuid; v_mkt uuid; v_order uuid;
begin
  insert into public.cash_accounts (name, kind, is_demo) values ('[DEMO] Kas', 'kas', true) returning id into v_acc;
  insert into public.cash_transactions (trx_date, direction, account_id, category_id, amount, payment_method, description, is_demo)
  values (current_date, 'in', v_acc, (select id from public.transaction_categories where code = 'saldo_awal_in'),
    1000000, 'tunai', '[DEMO] Saldo awal', true);
  insert into public.cash_transactions (trx_date, direction, account_id, category_id, amount, payment_method, description, is_demo)
  values (current_date, 'out', v_acc, (select id from public.transaction_categories where name = 'Listrik & air'),
    150000, 'tunai', '[DEMO] Token listrik', true);
  insert into public.customers (name, phone, is_demo) values ('[DEMO] Kedai Kopi Contoh', '081200000000', true) returning id into v_cust;
  insert into public.marketers (name, is_demo) values ('[DEMO] Marketing Contoh', true) returning id into v_mkt;
  insert into public.products (sku, name, item_type, material, size_oz, unit, min_stock, is_demo)
  values ('DEMO-PP-14', '[DEMO] Cup PP 14 oz', 'cup', 'PP', 14, 'pcs', 1000, true) returning id into v_prod;
  insert into public.stock_movements (product_id, movement_date, movement_type, qty, unit_cost, reason, is_demo)
  values (v_prod, current_date, 'stok_awal', 3000, 300, '[DEMO] stok awal', true);
  insert into public.orders (order_date, customer_id, marketer_id, fee_per_cup, status, is_demo)
  values (current_date, v_cust, v_mkt, 40, 'penawaran', true) returning id into v_order;
  insert into public.order_items (order_id, product_id, qty, unit_price, print_colors, print_spec)
  values (v_order, v_prod, 1000, 850, 2, '[DEMO] Logo 2 warna');
  insert into public.workers (name, default_rate, is_demo) values ('[DEMO] Pekerja Contoh', 55000, true);
end $$;

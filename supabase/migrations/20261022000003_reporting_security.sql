-- =====================================================================
-- Sayspack Management System — Migrasi 3: Laporan, Tutup Buku, Bagi Hasil, RLS
-- =====================================================================

-- Ringkasan per pesanan: tagihan, pembayaran, HPP aktual.
create or replace view public.v_order_summary with (security_invoker = true) as
select o.id, o.order_no, o.order_date, o.customer_id, o.marketer_id, o.status, o.total, o.return_credit,
  (o.total - o.return_credit)::numeric(18,2) as net_sales,
  public.order_paid(o.id)::numeric(18,2) as paid,
  (o.total - o.return_credit - public.order_paid(o.id))::numeric(18,2) as outstanding,
  coalesce((select sum(-m.total_cost) from public.stock_movements m where m.order_id = o.id), 0)::numeric(18,2) as material_cost,
  coalesce((select sum(w.rate) from public.work_days w where w.order_id = o.id and w.status = 'hadir'), 0)::numeric(18,2) as labor_cost_linked,
  coalesce((select sum(qty) from public.order_items where order_id = o.id), 0) as qty_ordered,
  coalesce((select sum(qty_delivered) from public.order_items where order_id = o.id), 0) as qty_delivered,
  o.revenue_recognized_on, o.cancelled_on, o.is_demo
from public.orders o;

-- ---------------------------------------------------------------------
-- Laba-rugi (metode akrual sederhana, konsisten):
--   Omzet          = total pesanan (− retur) yang diakui pada periode (status sesuai pengaturan).
--   HPP bahan/cup  = nilai stok keluar yang terkait pesanan tsb (pengiriman, pemakaian, cacat).
--   Upah produksi  = tarif kehadiran pada periode (diakui saat kerja, bukan saat dibayar).
--   Komisi         = fee/cup × cup terkirim bersih untuk pesanan yang diakui pada periode.
--   Beban operasional & pendapatan lain = transaksi kas kategori tsb.
--   Selisih/kerusakan stok non-pesanan, dan depresiasi aset.
-- Pembayaran pelanggan, pembelian persediaan/aset, pembayaran upah/komisi/bagi hasil,
-- modal, dan transfer TIDAK masuk laba-rugi (sudah diakui di baris lain atau bukan laba).
-- ---------------------------------------------------------------------
create or replace function public.profit_and_loss(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rev numeric; v_cogs numeric; v_labor numeric; v_comm numeric; v_opex numeric; v_other numeric;
  v_inv_adj numeric; v_dep numeric; v_gross numeric; v_net numeric; v_opex_detail jsonb; v_orders integer;
begin
  if not public.can_read_reports() then raise exception 'Tidak punya akses laporan.' using errcode = '42501'; end if;

  select coalesce(sum(total - return_credit), 0), count(*) into v_rev, v_orders
  from public.orders where revenue_recognized_on between p_from and p_to;

  select coalesce(sum(-m.total_cost), 0) into v_cogs
  from public.stock_movements m join public.orders o on o.id = m.order_id
  where coalesce(o.revenue_recognized_on, o.cancelled_on) is not null
    and greatest(coalesce(o.revenue_recognized_on, o.cancelled_on), m.movement_date) between p_from and p_to;

  select coalesce(sum(rate), 0) into v_labor from public.work_days
  where status = 'hadir' and work_date between p_from and p_to;

  select coalesce(sum(commission_full), 0) into v_comm from public.v_order_commissions
  where revenue_recognized_on between p_from and p_to;

  select coalesce(sum(t.amount) filter (where c.report_group = 'beban_operasional'), 0),
         coalesce(sum(t.amount) filter (where c.report_group = 'pendapatan_lain'), 0)
  into v_opex, v_other
  from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
  where t.status = 'posted' and t.trx_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object('category', name, 'amount', amt) order by amt desc), '[]'::jsonb) into v_opex_detail
  from (select c.name, sum(t.amount) amt from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
        where t.status = 'posted' and c.report_group = 'beban_operasional' and t.trx_date between p_from and p_to
        group by c.name) x;

  select coalesce(sum(-m.total_cost), 0) into v_inv_adj
  from public.stock_movements m
  left join public.stock_movements r on r.id = m.reverses_id
  where m.order_id is null and m.movement_date between p_from and p_to
    and (m.movement_type in ('rusak', 'koreksi', 'opname', 'retur_ke_pemasok')
         or (m.movement_type = 'pembatalan' and r.movement_type in ('rusak', 'koreksi', 'opname', 'retur_ke_pemasok')));

  select coalesce(sum(amount), 0) into v_dep from public.depreciation_entries
  where period between date_trunc('month', p_from)::date and p_to;

  v_gross := v_rev - v_cogs - v_labor;
  v_net := v_gross - v_comm - v_opex + v_other - v_inv_adj - v_dep;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'orders_recognized', v_orders,
    'revenue', round(v_rev, 2), 'cogs_materials', round(v_cogs, 2), 'labor', round(v_labor, 2),
    'gross_profit', round(v_gross, 2), 'commission', round(v_comm, 2), 'opex', round(v_opex, 2),
    'opex_detail', v_opex_detail, 'other_income', round(v_other, 2), 'inventory_adjustments', round(v_inv_adj, 2),
    'depreciation', round(v_dep, 2), 'net_profit', round(v_net, 2));
end $$;

-- Arus kas: hanya uang yang benar-benar masuk/keluar.
create or replace function public.cash_flow(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_open numeric; v_close numeric; v_lines jsonb;
begin
  if not public.can_read_reports() then raise exception 'Tidak punya akses laporan.' using errcode = '42501'; end if;
  select coalesce(sum(case when direction = 'in' then amount else -amount end), 0) into v_open
  from public.cash_transactions where status = 'posted' and trx_date < p_from;
  select coalesce(sum(case when direction = 'in' then amount else -amount end), 0) into v_close
  from public.cash_transactions where status = 'posted' and trx_date <= p_to;
  select coalesce(jsonb_agg(jsonb_build_object('group', report_group, 'direction', direction, 'category', name, 'amount', amt)
           order by direction, report_group, name), '[]'::jsonb) into v_lines
  from (select c.report_group, t.direction, c.name, sum(t.amount) amt
        from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
        where t.status = 'posted' and t.trx_date between p_from and p_to and c.report_group <> 'transfer'
        group by 1, 2, 3) x;
  return jsonb_build_object('from', p_from, 'to', p_to, 'opening', v_open, 'closing', v_close, 'lines', v_lines);
end $$;

-- ---------------------------------------------------------------------
-- Bagi hasil
-- ---------------------------------------------------------------------
create or replace function public.rule_for_period(p_period date)
returns public.profit_sharing_rules language sql stable security definer set search_path = public as $$
  select * from public.profit_sharing_rules
  where effective_from <= (date_trunc('month', p_period) + interval '1 month - 1 day')::date
  order by effective_from desc, created_at desc limit 1
$$;

create or replace function public.allocate_profit(p_net numeric, p_rule public.profit_sharing_rules)
returns jsonb language plpgsql immutable as $$
declare v_res numeric := 0; v_inv numeric := 0; v_own numeric := 0;
begin
  if p_net > 0 then
    v_res := round(p_net * p_rule.reserve_pct / 100, 2);
    v_inv := round((p_net - v_res) * p_rule.investor_pct / 100, 2);
    v_own := p_net - v_res - v_inv;
  end if;
  return jsonb_build_object('net_profit', p_net, 'reserve', v_res, 'investor', v_inv, 'owner', v_own,
    'reserve_pct', p_rule.reserve_pct, 'investor_pct', p_rule.investor_pct, 'owner_pct', p_rule.owner_pct,
    'is_loss', p_net < 0, 'loss_policy', p_rule.loss_policy, 'loss_policy_agreed', p_rule.loss_policy_agreed);
end $$;

create table public.profit_payouts (
  id                   uuid primary key default gen_random_uuid(),
  period               date not null references public.accounting_periods(period),
  recipient            text not null check (recipient in ('investor', 'owner')),
  payment_date         date not null,
  amount               numeric(18,2) not null check (amount > 0),
  account_id           uuid not null references public.cash_accounts(id),
  method               text not null check (method in ('tunai', 'transfer')),
  notes                text,
  attachment_path      text,
  status               text not null default 'posted' check (status in ('posted', 'void')),
  void_reason          text,
  cash_transaction_id  uuid unique references public.cash_transactions(id),
  client_ref           uuid unique,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now()
);
create trigger profit_payouts_no_delete before delete on public.profit_payouts for each row execute function public.forbid_delete();
create trigger profit_payouts_audit after insert or update on public.profit_payouts for each row execute function public.audit_trigger();

create or replace function public.pay_profit_share(
  p_period date, p_recipient text, p_date date, p_amount numeric, p_account uuid, p_method text,
  p_notes text default null, p_attachment text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.accounting_periods; v_alloc numeric; v_paid numeric; v_id uuid := gen_random_uuid(); v_cash uuid; v_existing uuid;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_existing from public.profit_payouts where client_ref = p_client_ref;
    if v_existing is not null then return v_existing; end if;
  end if;
  select * into v from public.accounting_periods where period = date_trunc('month', p_period)::date for update;
  if v.period is null or v.status <> 'closed' then raise exception 'Bagi hasil hanya untuk periode yang sudah ditutup.'; end if;
  v_alloc := case p_recipient when 'investor' then v.investor_amount else v.owner_amount end;
  select coalesce(sum(amount), 0) into v_paid from public.profit_payouts
  where period = v.period and recipient = p_recipient and status = 'posted';
  if v_paid + p_amount > coalesce(v_alloc, 0) then
    raise exception 'Melebihi jatah % periode ini (sisa %).', p_recipient, public.fmt_rp(coalesce(v_alloc, 0) - v_paid);
  end if;
  v_cash := public._post_cash(p_date, 'out', p_account, 'bayar_bagi_hasil', p_amount, p_method,
    'Bagi hasil ' || p_recipient || ' ' || to_char(v.period, 'MM/YYYY'), 'profit_payout', v_id);
  insert into public.profit_payouts (id, period, recipient, payment_date, amount, account_id, method, notes, attachment_path, cash_transaction_id, client_ref)
  values (v_id, v.period, p_recipient, p_date, p_amount, p_account, p_method, p_notes, p_attachment, v_cash, p_client_ref);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Tutup buku
-- ---------------------------------------------------------------------
create or replace function public.period_close_preview(p_period date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_from date := date_trunc('month', p_period)::date; v_to date; v_pnl jsonb; v_rule public.profit_sharing_rules;
  v_checks jsonb := '[]'::jsonb; v_n numeric; v_amt numeric;
begin
  perform public.assert_owner();
  v_to := (v_from + interval '1 month - 1 day')::date;
  v_pnl := public.profit_and_loss(v_from, v_to);
  v_rule := public.rule_for_period(v_from);

  select count(*) into v_n from public.cash_transactions where status = 'posted' and trx_date between v_from and v_to
    and attachment_path is null and source_type is null;
  v_checks := v_checks || jsonb_build_object('key', 'bukti', 'ok', v_n = 0,
    'message', case when v_n = 0 then 'Semua transaksi manual punya bukti.' else v_n || ' transaksi manual belum ada bukti.' end);

  select count(*) into v_n from public.cash_accounts a where a.is_active
    and not exists (select 1 from public.reconciliations r where r.account_id = a.id and r.as_of >= v_to and r.difference = 0);
  v_checks := v_checks || jsonb_build_object('key', 'rekonsiliasi', 'ok', v_n = 0,
    'message', case when v_n = 0 then 'Semua akun sudah direkonsiliasi tanpa selisih.' else v_n || ' akun belum direkonsiliasi per akhir bulan.' end);

  select count(*) into v_n from public.products where qty_on_hand < 0;
  v_checks := v_checks || jsonb_build_object('key', 'stok', 'ok', v_n = 0,
    'message', case when v_n = 0 then 'Tidak ada stok minus.' else v_n || ' produk stoknya minus.' end);

  select count(*), coalesce(sum(outstanding), 0) into v_n, v_amt from public.v_work_day_wages
    where work_date <= v_to and outstanding > 0;
  v_checks := v_checks || jsonb_build_object('key', 'upah', 'ok', v_n = 0, 'amount', v_amt,
    'message', case when v_n = 0 then 'Semua upah sudah dibayar.' else v_n || ' hari kerja belum lunas (tetap jadi kewajiban).' end);

  select coalesce(sum(outstanding), 0) into v_amt from public.v_order_commissions where outstanding > 0;
  v_checks := v_checks || jsonb_build_object('key', 'komisi', 'ok', true, 'amount', v_amt,
    'message', 'Komisi terutang (informasi): ' || public.fmt_rp(v_amt));

  select count(*) into v_n from public.assets a where a.status = 'aktif'
    and date_trunc('month', a.depreciation_start)::date <= v_from
    and not exists (select 1 from public.depreciation_entries d where d.asset_id = a.id and d.period = v_from);
  v_checks := v_checks || jsonb_build_object('key', 'depresiasi', 'ok', true,
    'message', case when v_n = 0 then 'Depresiasi bulan ini sudah tercatat.' else v_n || ' aset akan didepresiasi otomatis saat tutup buku.' end);

  if (v_pnl->>'net_profit')::numeric < 0 and not v_rule.loss_policy_agreed then
    v_checks := v_checks || jsonb_build_object('key', 'kebijakan_rugi', 'ok', false,
      'message', 'Bulan ini rugi dan kebijakan kerugian belum disepakati. Rugi tidak dibagi otomatis.');
  end if;

  return jsonb_build_object('period', v_from,
    'status', coalesce((select status from public.accounting_periods where period = v_from), 'open'),
    'pnl', v_pnl, 'allocation', public.allocate_profit((v_pnl->>'net_profit')::numeric, v_rule),
    'rule_id', v_rule.id, 'checks', v_checks);
end $$;

-- p_expected_net: angka laba yang dilihat owner di pratinjau. Jika data berubah, penutupan ditolak.
create or replace function public.close_period(p_period date, p_expected_net numeric, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_from date := date_trunc('month', p_period)::date; v_to date; v_pnl jsonb; v_rule public.profit_sharing_rules;
  v_alloc jsonb; v_net numeric;
begin
  perform public.assert_owner();
  v_to := (v_from + interval '1 month - 1 day')::date;
  if v_to >= current_date then raise exception 'Bulan berjalan belum bisa ditutup.'; end if;
  insert into public.accounting_periods (period) values (v_from) on conflict (period) do nothing;
  perform 1 from public.accounting_periods where period = v_from and status = 'open' for update;
  if not found then raise exception 'Periode % sudah ditutup.', to_char(v_from, 'MM/YYYY'); end if;

  perform public.post_depreciation(v_from);
  v_pnl := public.profit_and_loss(v_from, v_to);
  v_net := (v_pnl->>'net_profit')::numeric;
  if p_expected_net is distinct from v_net then
    raise exception 'Angka laba berubah (sekarang %). Muat ulang pratinjau sebelum menutup.', public.fmt_rp(v_net);
  end if;
  v_rule := public.rule_for_period(v_from);
  v_alloc := public.allocate_profit(v_net, v_rule);

  update public.accounting_periods set status = 'closed', pnl = v_pnl, net_profit = v_net,
    reserve_amount = (v_alloc->>'reserve')::numeric, investor_amount = (v_alloc->>'investor')::numeric,
    owner_amount = (v_alloc->>'owner')::numeric, rule_id = v_rule.id, notes = p_notes,
    closed_at = now(), closed_by = auth.uid()
  where period = v_from;
  return v_alloc;
end $$;

-- ---------------------------------------------------------------------
-- Ringkasan dashboard
-- ---------------------------------------------------------------------
create or replace function public.dashboard_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_last record; v_month_pnl jsonb;
begin
  if not public.can_read_reports() then raise exception 'Tidak punya akses laporan.' using errcode = '42501'; end if;
  v_month_pnl := public.profit_and_loss(p_from, p_to);
  select * into v_last from public.accounting_periods where status = 'closed' order by period desc limit 1;
  v := jsonb_build_object(
    'cash_total', (select coalesce(sum(balance), 0) from public.v_account_balances),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'balance', balance) order by name), '[]')
                 from public.v_account_balances where is_active),
    'pnl', v_month_pnl,
    'cash_in', (select coalesce(sum(amount), 0) from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
                where t.status = 'posted' and t.direction = 'in' and c.report_group <> 'transfer' and t.trx_date between p_from and p_to),
    'cash_out', (select coalesce(sum(amount), 0) from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
                where t.status = 'posted' and t.direction = 'out' and c.report_group <> 'transfer' and t.trx_date between p_from and p_to),
    'capital_in', (select coalesce(sum(amount), 0) from public.cash_transactions t join public.transaction_categories c on c.id = t.category_id
                where t.status = 'posted' and c.report_group = 'modal'),
    'initial_capital', public.setting_num('initial_capital'),
    'orders_by_status', (select coalesce(jsonb_object_agg(status, n), '{}') from
                 (select status, count(*) n from public.orders where status not in ('selesai', 'batal') group by status) x),
    'active_orders', (select count(*) from public.orders where status in ('dikonfirmasi','menunggu_bahan','produksi','qc','siap_dikirim','terkirim')),
    'receivables', (select coalesce(sum(outstanding), 0) from public.v_order_summary where status not in ('prospek','penawaran','batal') and outstanding > 0),
    'inventory_value', (select coalesce(sum(stock_value), 0) from public.v_inventory),
    'low_stock', (select coalesce(jsonb_agg(jsonb_build_object('sku', sku, 'name', name, 'qty', qty_on_hand, 'min', min_stock, 'unit', unit)), '[]')
                  from public.v_inventory where is_low_stock),
    'unpaid_wages', (select coalesce(sum(outstanding), 0) from public.v_work_day_wages where outstanding > 0),
    'unpaid_commissions', (select coalesce(sum(outstanding), 0) from public.v_order_commissions where outstanding > 0),
    'assets_cost', (select coalesce(sum(total_cost), 0) from public.v_asset_book_values where status = 'aktif'),
    'assets_book_value', (select coalesce(sum(book_value), 0) from public.v_asset_book_values where status = 'aktif'),
    'last_closed', case when v_last.period is null then null else jsonb_build_object(
                    'period', v_last.period, 'net_profit', v_last.net_profit, 'reserve', v_last.reserve_amount,
                    'investor', v_last.investor_amount, 'owner', v_last.owner_amount) end,
    'reserve_total', (select coalesce(sum(reserve_amount), 0) from public.accounting_periods where status = 'closed'),
    'profit_simulation', public.allocate_profit((v_month_pnl->>'net_profit')::numeric, public.rule_for_period(p_to))
  );
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Data DEMO: hapus semua baris berlabel DEMO.
-- ---------------------------------------------------------------------
create or replace function public.purge_demo_data()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_owner();
  perform set_config('app.demo_purge', 'on', true);
  delete from public.commission_payments where is_demo;
  delete from public.wage_payments where is_demo;
  delete from public.order_payments where is_demo;
  delete from public.purchase_payments where is_demo;
  update public.assets set cash_transaction_id = null where is_demo;
  delete from public.cash_transactions where is_demo;
  delete from public.depreciation_entries where is_demo;
  delete from public.assets where is_demo;
  delete from public.stock_movements where is_demo;
  delete from public.work_days where is_demo;
  delete from public.workers where is_demo;
  delete from public.order_status_history where order_id in (select id from public.orders where is_demo);
  delete from public.orders where is_demo;
  delete from public.purchases where is_demo;
  delete from public.products where is_demo;
  delete from public.marketers where is_demo;
  delete from public.customers where is_demo;
  delete from public.suppliers where is_demo;
  delete from public.cash_accounts where is_demo;
  perform set_config('app.demo_purge', 'off', true);
end $$;

-- =====================================================================
-- Keamanan: Row Level Security
--   owner    : baca semua; tulis master data langsung; tulis ledger HANYA lewat fungsi RPC.
--   investor : baca-saja laporan ringkas (kas, modal, aset, persediaan, periode, bagi hasil).
--   staff    : disiapkan, belum diberi akses (ditambah per kebutuhan).
--   pending  : tidak ada akses.
-- =====================================================================
do $$
declare t text;
  all_tables text[] := array['profiles','app_settings','audit_log','doc_counters','profit_sharing_rules','accounting_periods',
    'customers','suppliers','cash_accounts','transaction_categories','cash_transactions','reconciliations','products',
    'stock_movements','purchases','purchase_items','purchase_payments','marketers','orders','order_items',
    'order_status_history','order_payments','workers','work_days','wage_payments','commission_payments','assets',
    'depreciation_entries','profit_payouts'];
  -- master data: owner boleh insert/update langsung (hapus tetap dibatasi trigger)
  owner_write text[] := array['app_settings','profit_sharing_rules','customers','suppliers','cash_accounts',
    'transaction_categories','products','purchases','purchase_items','marketers','orders','order_items','workers',
    'work_days','assets'];
  investor_read text[] := array['app_settings','profit_sharing_rules','accounting_periods','cash_accounts',
    'transaction_categories','cash_transactions','products','assets','depreciation_entries','profit_payouts'];
begin
  foreach t in array all_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    if t not in ('profiles', 'doc_counters') then
      execute format('create policy owner_read on public.%I for select to authenticated using (public.is_owner())', t);
    end if;
  end loop;
  foreach t in array owner_write loop
    execute format('create policy owner_insert on public.%I for insert to authenticated with check (public.is_owner())', t);
    execute format('create policy owner_update on public.%I for update to authenticated using (public.is_owner()) with check (public.is_owner())', t);
    execute format('create policy owner_delete on public.%I for delete to authenticated using (public.is_owner())', t);
  end loop;
  foreach t in array investor_read loop
    execute format('create policy investor_read on public.%I for select to authenticated using (public.current_app_role() = ''investor'')', t);
  end loop;
end $$;

create policy self_read on public.profiles for select to authenticated using (id = auth.uid() or public.is_owner());
create policy owner_update on public.profiles for update to authenticated using (public.is_owner()) with check (public.is_owner());

-- Fungsi internal tidak boleh dipanggil langsung dari klien.
revoke execute on function public._post_cash(date, text, uuid, text, numeric, text, text, text, uuid, text, uuid, uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public._void_cash(uuid, text) from public, anon, authenticated;
revoke execute on function public.next_doc_no(text, date) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.purge_demo_data() from public, anon;

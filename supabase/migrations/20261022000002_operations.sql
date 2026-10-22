-- =====================================================================
-- Sayspack Management System — Migrasi 2: Operasional
-- Persediaan (rata-rata tertimbang), pembelian, pesanan & produksi,
-- pekerja harian, komisi marketing, aset & depresiasi.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Produk & persediaan
-- ---------------------------------------------------------------------
create table public.products (
  id           uuid primary key default gen_random_uuid(),
  sku          text not null unique check (length(trim(sku)) > 0),
  name         text not null check (length(trim(name)) > 0),
  item_type    text not null check (item_type in ('cup', 'tutup', 'tinta', 'bahan_pendukung', 'kemasan_lain')),
  material     text,             -- PET, PP, dst. (bebas ditambah)
  size_oz      numeric(6,2),
  model        text,
  color        text,
  lid_info     text,
  unit         text not null default 'pcs',
  supplier_id  uuid references public.suppliers(id),
  min_stock    numeric(18,3) not null default 0 check (min_stock >= 0),
  location     text,
  qty_on_hand  numeric(18,3) not null default 0,
  avg_cost     numeric(18,4) not null default 0 check (avg_cost >= 0),
  is_active    boolean not null default true,
  is_demo      boolean not null default false,
  created_at   timestamptz not null default now()
);
-- qty_on_hand & avg_cost hanya boleh berubah lewat stock_movements.
create or replace function public.products_guard()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.stock_apply', true), '') <> 'on'
     and (new.qty_on_hand is distinct from old.qty_on_hand or new.avg_cost is distinct from old.avg_cost) then
    raise exception 'Stok dan biaya rata-rata hanya berubah lewat pergerakan stok.';
  end if;
  return new;
end $$;
create trigger products_guard before update on public.products for each row execute function public.products_guard();
create trigger products_audit after insert or update on public.products for each row execute function public.audit_trigger();

create table public.stock_movements (
  id              uuid primary key default gen_random_uuid(),
  movement_no     text unique,
  product_id      uuid not null references public.products(id),
  movement_date   date not null,
  movement_type   text not null check (movement_type in (
                    'stok_awal', 'pembelian', 'pemakaian_produksi', 'pengiriman', 'retur_pelanggan',
                    'retur_ke_pemasok', 'rusak', 'koreksi', 'opname', 'pembatalan')),
  qty             numeric(18,3) not null check (qty <> 0),
  unit_cost       numeric(18,4),
  total_cost      numeric(18,2),
  reason          text,
  order_id        uuid,
  purchase_id     uuid,
  reverses_id     uuid unique references public.stock_movements(id),
  allow_negative  boolean not null default false,
  client_ref      uuid unique,
  is_demo         boolean not null default false,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  check (movement_type not in ('stok_awal', 'pembelian', 'retur_pelanggan') or qty > 0),
  check (movement_type not in ('pemakaian_produksi', 'pengiriman', 'retur_ke_pemasok', 'rusak') or qty < 0),
  check (movement_type not in ('rusak', 'koreksi', 'opname', 'pembatalan', 'retur_pelanggan', 'retur_ke_pemasok')
         or length(trim(coalesce(reason, ''))) >= 3),
  check (movement_type <> 'pembatalan' or reverses_id is not null)
);
create index stock_movements_product_idx on public.stock_movements (product_id, movement_date);
create index stock_movements_order_idx on public.stock_movements (order_id);

-- Menerapkan pergerakan ke produk secara atomik (row lock) dengan metode rata-rata tertimbang.
create or replace function public.stock_apply()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.products; v_new_qty numeric; v_value numeric; v_avg numeric; v_rev public.stock_movements;
begin
  select * into p from public.products where id = new.product_id for update;
  if new.reverses_id is not null then
    select * into v_rev from public.stock_movements where id = new.reverses_id;
    if v_rev.product_id <> new.product_id or v_rev.qty <> -new.qty then
      raise exception 'Pembatalan harus membalik produk dan jumlah yang sama.';
    end if;
    new.unit_cost := v_rev.unit_cost;
  elsif new.qty < 0 or new.unit_cost is null then
    new.unit_cost := p.avg_cost;   -- barang keluar dinilai dengan biaya rata-rata saat ini
  end if;
  if new.unit_cost < 0 then raise exception 'Biaya per unit tidak boleh negatif.'; end if;

  v_new_qty := p.qty_on_hand + new.qty;
  if v_new_qty < 0 and not (new.allow_negative and public.is_owner() and length(trim(coalesce(new.reason, ''))) >= 3) then
    raise exception 'Stok % tidak cukup: tersedia %, dibutuhkan %.', p.name, p.qty_on_hand, abs(new.qty);
  end if;

  v_value := p.qty_on_hand * p.avg_cost + new.qty * new.unit_cost;
  v_avg := case when v_new_qty > 0 then greatest(v_value / v_new_qty, 0) else p.avg_cost end;
  new.total_cost := round(new.qty * new.unit_cost, 2);
  new.movement_no := public.next_doc_no('STK', new.movement_date);

  perform set_config('app.stock_apply', 'on', true);
  update public.products set qty_on_hand = v_new_qty, avg_cost = round(v_avg, 4) where id = p.id;
  perform set_config('app.stock_apply', 'off', true);
  return new;
end $$;

create or replace function public.forbid_update()
returns trigger language plpgsql as $$
begin raise exception 'Data % tidak boleh diubah. Buat pembatalan/penyesuaian.', tg_table_name; end $$;

create trigger stock_movements_apply before insert on public.stock_movements
  for each row execute function public.stock_apply();
create trigger stock_movements_period before insert or update or delete on public.stock_movements
  for each row execute function public.guard_closed_period('movement_date');
create trigger stock_movements_no_update before update on public.stock_movements
  for each row execute function public.forbid_update();
create trigger stock_movements_no_delete before delete on public.stock_movements
  for each row execute function public.forbid_delete();
create trigger stock_movements_audit after insert on public.stock_movements
  for each row execute function public.audit_trigger();

-- Penyesuaian stok manual (stok awal, rusak, koreksi, opname, retur ke pemasok).
create or replace function public.record_stock_adjustment(
  p_product uuid, p_date date, p_type text, p_qty numeric, p_unit_cost numeric, p_reason text,
  p_allow_negative boolean default false, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.assert_owner();
  if p_type not in ('stok_awal', 'rusak', 'koreksi', 'retur_ke_pemasok') then
    raise exception 'Jenis % dicatat dari modul lain.', p_type;
  end if;
  if p_client_ref is not null then
    select id into v_id from public.stock_movements where client_ref = p_client_ref;
    if v_id is not null then return v_id; end if;
  end if;
  insert into public.stock_movements (product_id, movement_date, movement_type, qty, unit_cost, reason, allow_negative, client_ref)
  values (p_product, p_date, p_type, p_qty, p_unit_cost, p_reason, coalesce(p_allow_negative, false), p_client_ref)
  returning id into v_id;
  return v_id;
end $$;

-- Stock opname: masukkan jumlah fisik, sistem mencatat selisihnya.
create or replace function public.record_stock_opname(p_product uuid, p_date date, p_counted numeric, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_qty numeric; v_id uuid;
begin
  perform public.assert_owner();
  if p_counted < 0 then raise exception 'Jumlah fisik tidak boleh negatif.'; end if;
  select qty_on_hand into v_qty from public.products where id = p_product for update;
  if p_counted = v_qty then return null; end if;
  insert into public.stock_movements (product_id, movement_date, movement_type, qty, reason)
  values (p_product, p_date, 'opname', p_counted - v_qty, p_reason) returning id into v_id;
  return v_id;
end $$;

create or replace function public.reverse_stock_movement(p_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.stock_movements; v_id uuid;
begin
  perform public.assert_owner();
  select * into m from public.stock_movements where id = p_id;
  if m.id is null then raise exception 'Pergerakan stok tidak ditemukan.'; end if;
  if m.movement_type = 'pembatalan' then raise exception 'Pembatalan tidak bisa dibatalkan lagi.'; end if;
  if m.movement_type = 'pembelian' then raise exception 'Batalkan lewat pembatalan penerimaan pembelian.'; end if;
  insert into public.stock_movements (product_id, movement_date, movement_type, qty, reason, order_id, reverses_id)
  values (m.product_id, current_date, 'pembatalan', -m.qty, p_reason, m.order_id, m.id) returning id into v_id;
  return v_id;
end $$;

create or replace view public.v_inventory with (security_invoker = true) as
select p.*, round(p.qty_on_hand * p.avg_cost, 2) as stock_value,
  (p.is_active and p.qty_on_hand <= p.min_stock) as is_low_stock
from public.products p;

-- ---------------------------------------------------------------------
-- Pembelian (stok bertambah saat barang DITERIMA) & utang pemasok
-- ---------------------------------------------------------------------
create table public.purchases (
  id             uuid primary key default gen_random_uuid(),
  purchase_no    text unique,
  supplier_id    uuid references public.suppliers(id),
  purchase_date  date not null,
  due_date       date,
  status         text not null default 'draf' check (status in ('draf', 'diterima', 'batal')),
  notes          text,
  received_on    date,
  is_demo        boolean not null default false,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
create table public.purchase_items (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchases(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          numeric(18,3) not null check (qty > 0),
  unit_cost    numeric(18,4) not null check (unit_cost >= 0)
);
create trigger purchases_audit after insert or update on public.purchases for each row execute function public.audit_trigger();

create or replace function public.purchase_items_guard()
returns trigger language plpgsql as $$
declare v_status text;
begin
  if coalesce(current_setting('app.demo_purge', true), '') = 'on' then return coalesce(new, old); end if;
  select status into v_status from public.purchases where id = coalesce(new.purchase_id, old.purchase_id);
  if v_status <> 'draf' then raise exception 'Item pembelian yang sudah diterima/batal tidak bisa diubah.'; end if;
  return coalesce(new, old);
end $$;
create trigger purchase_items_guard before insert or update or delete on public.purchase_items
  for each row execute function public.purchase_items_guard();

create or replace function public.purchase_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin new.purchase_no := public.next_doc_no('PO', new.purchase_date); new.status := 'draf'; return new; end $$;
create trigger purchases_number before insert on public.purchases for each row execute function public.purchase_before_insert();

create or replace function public.receive_purchase(p_purchase uuid, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare v public.purchases; i record;
begin
  perform public.assert_owner();
  select * into v from public.purchases where id = p_purchase for update;
  if v.id is null then raise exception 'Pembelian tidak ditemukan.'; end if;
  if v.status <> 'draf' then raise exception 'Pembelian % sudah berstatus %.', v.purchase_no, v.status; end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_purchase) then
    raise exception 'Pembelian belum punya item.';
  end if;
  for i in select * from public.purchase_items where purchase_id = p_purchase loop
    insert into public.stock_movements (product_id, movement_date, movement_type, qty, unit_cost, purchase_id, reason, is_demo)
    values (i.product_id, p_date, 'pembelian', i.qty, i.unit_cost, p_purchase, 'Penerimaan ' || v.purchase_no, v.is_demo);
  end loop;
  update public.purchases set status = 'diterima', received_on = p_date where id = p_purchase;
end $$;

create table public.purchase_payments (
  id                   uuid primary key default gen_random_uuid(),
  purchase_id          uuid not null references public.purchases(id),
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
  is_demo              boolean not null default false,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now()
);
create trigger purchase_payments_no_delete before delete on public.purchase_payments
  for each row execute function public.forbid_delete();
create trigger purchase_payments_audit after insert or update on public.purchase_payments
  for each row execute function public.audit_trigger();

create or replace view public.v_purchase_balances with (security_invoker = true) as
select p.id, p.purchase_no, p.supplier_id, p.purchase_date, p.due_date, p.status,
  coalesce((select sum(round(qty * unit_cost, 2)) from public.purchase_items where purchase_id = p.id), 0)::numeric(18,2) as total,
  coalesce((select sum(amount) from public.purchase_payments where purchase_id = p.id and status = 'posted'), 0)::numeric(18,2) as paid
from public.purchases p;

create or replace function public.pay_purchase(
  p_purchase uuid, p_date date, p_amount numeric, p_account uuid, p_method text,
  p_notes text default null, p_attachment text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.purchases; v_bal record; v_id uuid := gen_random_uuid(); v_cash uuid;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_cash from public.purchase_payments where client_ref = p_client_ref;
    if v_cash is not null then return v_cash; end if;
  end if;
  select * into v from public.purchases where id = p_purchase for update;
  if v.status = 'batal' then raise exception 'Pembelian sudah dibatalkan.'; end if;
  select * into v_bal from public.v_purchase_balances where id = p_purchase;
  if p_amount > v_bal.total - v_bal.paid then
    raise exception 'Pembayaran melebihi sisa utang (sisa %).', public.fmt_rp(v_bal.total - v_bal.paid);
  end if;
  v_cash := public._post_cash(p_date, 'out', p_account, 'bayar_pemasok', p_amount, p_method,
    'Pembayaran ' || v.purchase_no, 'purchase_payment', v_id, v.purchase_no, null, v.supplier_id, p_attachment, v.is_demo);
  insert into public.purchase_payments (id, purchase_id, payment_date, amount, account_id, method, notes, attachment_path,
    cash_transaction_id, client_ref, is_demo)
  values (v_id, p_purchase, p_date, p_amount, p_account, p_method, p_notes, p_attachment, v_cash, p_client_ref, v.is_demo);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Marketing freelance
-- ---------------------------------------------------------------------
create table public.marketers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  phone       text,
  notes       text,
  is_active   boolean not null default true,
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Pesanan & produksi
-- ---------------------------------------------------------------------
create type public.order_status as enum (
  'prospek', 'penawaran', 'dikonfirmasi', 'menunggu_bahan', 'produksi', 'qc',
  'siap_dikirim', 'terkirim', 'selesai', 'batal');

create table public.orders (
  id                     uuid primary key default gen_random_uuid(),
  order_no               text unique,
  order_date             date not null,
  customer_id            uuid not null references public.customers(id),
  marketer_id            uuid references public.marketers(id),
  status                 public.order_status not null default 'prospek',
  fee_per_cup            numeric(18,2) not null default 0 check (fee_per_cup >= 0),  -- snapshot hasil negosiasi
  commission_basis       text not null default 'terkirim' check (commission_basis in ('terkirim', 'lunas')),
  discount               numeric(18,2) not null default 0 check (discount >= 0),
  subtotal               numeric(18,2) not null default 0,
  total                  numeric(18,2) not null default 0 check (total >= 0),
  return_credit          numeric(18,2) not null default 0 check (return_credit >= 0),
  design_notes           text,
  artwork_path           text,
  notes                  text,
  qty_produced           integer not null default 0 check (qty_produced >= 0),
  qty_defect             integer not null default 0 check (qty_defect >= 0),
  qty_returned           integer not null default 0 check (qty_returned >= 0),
  revenue_recognized_on  date,
  cancelled_on           date,
  is_demo                boolean not null default false,
  created_by             uuid default auth.uid(),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  check (marketer_id is not null or fee_per_cup = 0),
  check (return_credit <= total)
);
create index orders_status_idx on public.orders (status);

create table public.order_items (
  id                     uuid primary key default gen_random_uuid(),
  order_id               uuid not null references public.orders(id) on delete cascade,
  product_id             uuid references public.products(id),
  description            text,
  qty                    integer not null check (qty > 0),
  unit_price             numeric(18,2) not null check (unit_price >= 0),
  print_colors           integer not null default 0 check (print_colors >= 0),
  print_spec             text,
  est_unit_cost          numeric(18,4),
  counts_for_commission  boolean not null default true,
  qty_delivered          integer not null default 0 check (qty_delivered >= 0),
  check (qty_delivered <= qty)
);

create table public.order_status_history (
  id           bigserial primary key,
  order_id     uuid not null references public.orders(id),
  from_status  public.order_status,
  to_status    public.order_status not null,
  note         text,
  changed_by   uuid default auth.uid(),
  changed_at   timestamptz not null default now()
);

create or replace function public.orders_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.order_no := public.next_doc_no('SP', new.order_date);
    if new.status not in ('prospek', 'penawaran') then new.status := 'prospek'; end if;
    new.revenue_recognized_on := null; new.cancelled_on := null;
    return new;
  end if;
  -- Status hanya diubah lewat set_order_status (flag sesi).
  if new.status is distinct from old.status and coalesce(current_setting('app.order_status', true), '') <> 'on' then
    raise exception 'Ubah status pesanan lewat tombol ubah status agar riwayatnya tercatat.';
  end if;
  if old.revenue_recognized_on is not null
     and (new.total, new.discount, new.fee_per_cup, new.marketer_id, new.commission_basis)
         is distinct from (old.total, old.discount, old.fee_per_cup, old.marketer_id, old.commission_basis) then
    raise exception 'Pesanan sudah diakui sebagai penjualan; harga, diskon, dan komisi tidak bisa diubah. Gunakan nilai retur.';
  end if;
  if new.fee_per_cup is distinct from old.fee_per_cup
     and exists (select 1 from public.commission_payments where order_id = old.id and status = 'posted') then
    raise exception 'Komisi pesanan ini sudah pernah dibayar; tarif tidak bisa diubah.';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger orders_before before insert or update on public.orders for each row execute function public.orders_before();
create trigger orders_audit after insert or update on public.orders for each row execute function public.audit_trigger();
create trigger orders_no_delete before delete on public.orders for each row execute function public.forbid_delete();

-- Hitung ulang subtotal/total saat item berubah. Item hanya bisa diubah sebelum produksi.
create or replace function public.order_items_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_order uuid := coalesce(new.order_id, old.order_id); v_sub numeric;
begin
  select coalesce(sum(round(qty * unit_price, 2)), 0) into v_sub from public.order_items where order_id = v_order;
  update public.orders set subtotal = v_sub, total = greatest(v_sub - discount, 0) where id = v_order;
  return null;
end $$;
create or replace function public.order_items_guard()
returns trigger language plpgsql as $$
declare v_status public.order_status;
begin
  if coalesce(current_setting('app.order_delivery', true), '') = 'on'
     or coalesce(current_setting('app.demo_purge', true), '') = 'on' then return coalesce(new, old); end if;
  select status into v_status from public.orders where id = coalesce(new.order_id, old.order_id);
  if v_status not in ('prospek', 'penawaran', 'dikonfirmasi', 'menunggu_bahan') then
    raise exception 'Item pesanan tidak bisa diubah setelah masuk produksi.';
  end if;
  if tg_op = 'UPDATE' and new.qty_delivered <> old.qty_delivered then
    raise exception 'Jumlah terkirim dicatat lewat pengiriman.';
  end if;
  return coalesce(new, old);
end $$;
create trigger order_items_guard before insert or update or delete on public.order_items
  for each row execute function public.order_items_guard();
create trigger order_items_after after insert or update or delete on public.order_items
  for each row execute function public.order_items_after();
create or replace function public.orders_discount_recalc()
returns trigger language plpgsql as $$
begin new.total := greatest(new.subtotal - new.discount, 0); return new; end $$;
create trigger orders_discount_recalc before update of discount, subtotal on public.orders
  for each row execute function public.orders_discount_recalc();

create or replace function public.order_status_rank(s public.order_status)
returns integer language sql immutable as $$
  select array_position(array['prospek','penawaran','dikonfirmasi','menunggu_bahan','produksi','qc',
    'siap_dikirim','terkirim','selesai']::public.order_status[], s)
$$;

create or replace function public.set_order_status(p_order uuid, p_status public.order_status, p_note text default null, p_date date default current_date)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders; v_recog public.order_status := public.setting_text('revenue_recognition')::public.order_status;
begin
  perform public.assert_owner();
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Pesanan tidak ditemukan.'; end if;
  if o.status = p_status then return; end if;
  if o.status in ('selesai', 'batal') then raise exception 'Pesanan % sudah %.', o.order_no, o.status; end if;
  if p_status = 'batal' then
    if o.revenue_recognized_on is not null then
      raise exception 'Pesanan sudah diakui sebagai penjualan. Catat retur, bukan pembatalan.';
    end if;
    if public.order_paid(p_order) > 0 then
      raise exception 'Masih ada pembayaran %. Catat pengembalian dana atau batalkan pembayaran dulu.', public.fmt_rp(public.order_paid(p_order));
    end if;
    if length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Alasan pembatalan pesanan wajib diisi.'; end if;
  elsif public.order_status_rank(p_status) >= public.order_status_rank('dikonfirmasi')
        and not exists (select 1 from public.order_items where order_id = p_order) then
    raise exception 'Tambahkan item pesanan sebelum dikonfirmasi.';
  elsif p_status in ('terkirim', 'selesai')
        and exists (select 1 from public.order_items where order_id = p_order and qty_delivered = 0) then
    raise exception 'Catat pengiriman barang dulu sebelum status %.', p_status;
  end if;

  perform set_config('app.order_status', 'on', true);
  update public.orders set
    status = p_status,
    cancelled_on = case when p_status = 'batal' then p_date else cancelled_on end,
    revenue_recognized_on = case
      when p_status <> 'batal' and revenue_recognized_on is null
           and public.order_status_rank(p_status) >= public.order_status_rank(v_recog) then p_date
      else revenue_recognized_on end
  where id = p_order;
  perform set_config('app.order_status', 'off', true);
  if public.is_period_closed(p_date) and (p_status = 'batal' or public.order_status_rank(p_status) >= public.order_status_rank(v_recog)) then
    raise exception 'Tanggal % ada di periode yang sudah ditutup.', p_date;
  end if;
  insert into public.order_status_history (order_id, from_status, to_status, note) values (p_order, o.status, p_status, p_note);
end $$;

-- Pemakaian bahan (tinta, bahan pendukung) untuk pesanan → masuk HPP pesanan.
create or replace function public.use_materials(p_order uuid, p_date date, p_items jsonb, p_note text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare o public.orders; i jsonb; n integer := 0;
begin
  perform public.assert_owner();
  select * into o from public.orders where id = p_order for update;
  if o.status in ('prospek', 'penawaran', 'batal') then raise exception 'Pesanan belum dikonfirmasi atau sudah batal.'; end if;
  for i in select * from jsonb_array_elements(p_items) loop
    insert into public.stock_movements (product_id, movement_date, movement_type, qty, order_id, reason, is_demo)
    values ((i->>'product_id')::uuid, p_date, 'pemakaian_produksi', -abs((i->>'qty')::numeric), p_order,
      coalesce(p_note, 'Produksi ' || o.order_no), o.is_demo);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Hasil produksi & cacat. Cup cacat mengurangi stok sebagai 'rusak' terkait pesanan (masuk HPP pesanan).
create or replace function public.record_production(p_order uuid, p_date date, p_qty_good integer, p_qty_defect integer,
  p_defect_product uuid default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  perform public.assert_owner();
  select * into o from public.orders where id = p_order for update;
  if o.status in ('prospek', 'penawaran', 'batal', 'selesai') then raise exception 'Status pesanan tidak memungkinkan pencatatan produksi.'; end if;
  if p_qty_good < 0 or p_qty_defect < 0 then raise exception 'Jumlah tidak boleh negatif.'; end if;
  update public.orders set qty_produced = qty_produced + p_qty_good, qty_defect = qty_defect + p_qty_defect where id = p_order;
  if p_qty_defect > 0 and p_defect_product is not null then
    insert into public.stock_movements (product_id, movement_date, movement_type, qty, order_id, reason, is_demo)
    values (p_defect_product, p_date, 'rusak', -p_qty_defect, p_order, coalesce(p_note, 'Cacat produksi ' || o.order_no), o.is_demo);
  end if;
end $$;

-- Pengiriman: stok cup berkurang tepat sekali per baris pengiriman, nilai = biaya rata-rata (HPP).
create or replace function public.deliver_order(p_order uuid, p_date date, p_items jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders; i jsonb; it public.order_items; v_qty integer;
begin
  perform public.assert_owner();
  select * into o from public.orders where id = p_order for update;
  if public.order_status_rank(o.status) is null or public.order_status_rank(o.status) < public.order_status_rank('dikonfirmasi')
     or o.status = 'selesai' then
    raise exception 'Pesanan % belum bisa dikirim (status %).', o.order_no, o.status;
  end if;
  perform set_config('app.order_delivery', 'on', true);
  for i in select * from jsonb_array_elements(p_items) loop
    select * into it from public.order_items where id = (i->>'order_item_id')::uuid and order_id = p_order for update;
    if it.id is null then raise exception 'Item pesanan tidak ditemukan.'; end if;
    v_qty := (i->>'qty')::integer;
    if v_qty <= 0 then raise exception 'Jumlah kirim harus lebih dari 0.'; end if;
    if it.qty_delivered + v_qty > it.qty then
      raise exception 'Jumlah kirim melebihi pesanan (sisa %).', it.qty - it.qty_delivered;
    end if;
    if it.product_id is not null then
      insert into public.stock_movements (product_id, movement_date, movement_type, qty, order_id, reason, is_demo)
      values (it.product_id, p_date, 'pengiriman', -v_qty, p_order, coalesce(p_note, 'Kirim ' || o.order_no), o.is_demo);
    end if;
    update public.order_items set qty_delivered = qty_delivered + v_qty where id = it.id;
  end loop;
  perform set_config('app.order_delivery', 'off', true);
end $$;

-- Retur pelanggan: catat jumlah & nilai potongan tagihan (cup bersablon umumnya tidak kembali ke stok).
create or replace function public.record_order_return(p_order uuid, p_qty integer, p_credit numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  perform public.assert_owner();
  select * into o from public.orders where id = p_order for update;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Alasan retur wajib diisi.'; end if;
  if o.return_credit + p_credit > o.total then raise exception 'Nilai retur melebihi total pesanan.'; end if;
  if o.revenue_recognized_on is not null and public.is_period_closed(o.revenue_recognized_on) then
    raise exception 'Penjualan pesanan ini ada di periode tertutup. Catat retur sebagai penyesuaian (transaksi baru) di periode berjalan.';
  end if;
  update public.orders set qty_returned = qty_returned + p_qty, return_credit = return_credit + p_credit,
    notes = coalesce(notes || E'\n', '') || 'Retur: ' || p_reason
  where id = p_order;
end $$;

-- Pembayaran pelanggan (DP/lanjutan/pelunasan/refund). Ini arus kas, BUKAN omzet.
create table public.order_payments (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references public.orders(id),
  payment_date         date not null,
  kind                 text not null check (kind in ('dp', 'lanjutan', 'pelunasan', 'refund')),
  amount               numeric(18,2) not null check (amount > 0),
  account_id           uuid not null references public.cash_accounts(id),
  method               text not null check (method in ('tunai', 'transfer')),
  reference_no         text,
  attachment_path      text,
  notes                text,
  status               text not null default 'posted' check (status in ('posted', 'void')),
  void_reason          text,
  cash_transaction_id  uuid unique references public.cash_transactions(id),
  client_ref           uuid unique,
  is_demo              boolean not null default false,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now()
);
create trigger order_payments_no_delete before delete on public.order_payments
  for each row execute function public.forbid_delete();
create trigger order_payments_audit after insert or update on public.order_payments
  for each row execute function public.audit_trigger();

create or replace function public.order_paid(p_order uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0)
  from public.order_payments where order_id = p_order and status = 'posted'
$$;

create or replace function public.record_order_payment(
  p_order uuid, p_date date, p_kind text, p_amount numeric, p_account uuid, p_method text,
  p_reference text default null, p_attachment text default null, p_notes text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.orders; v_paid numeric; v_due numeric; v_id uuid := gen_random_uuid(); v_cash uuid; v_existing uuid;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_existing from public.order_payments where client_ref = p_client_ref;
    if v_existing is not null then return v_existing; end if;
  end if;
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Pesanan tidak ditemukan.'; end if;
  if o.status in ('prospek', 'batal') then raise exception 'Pesanan berstatus % tidak bisa menerima pembayaran.', o.status; end if;
  v_paid := public.order_paid(p_order);
  v_due := o.total - o.return_credit;
  if p_kind = 'refund' then
    if p_amount > v_paid then raise exception 'Refund melebihi total yang sudah dibayar (%).', public.fmt_rp(v_paid); end if;
  elsif v_paid + p_amount > v_due then
    raise exception 'Pembayaran melebihi sisa tagihan (sisa %).', public.fmt_rp(v_due - v_paid);
  end if;
  v_cash := public._post_cash(p_date, case when p_kind = 'refund' then 'out' else 'in' end, p_account,
    case when p_kind = 'refund' then 'refund_pesanan' else 'penerimaan_pesanan' end, p_amount, p_method,
    initcap(p_kind) || ' ' || o.order_no, 'order_payment', v_id, coalesce(p_reference, o.order_no),
    o.customer_id, null, p_attachment, o.is_demo);
  insert into public.order_payments (id, order_id, payment_date, kind, amount, account_id, method, reference_no,
    attachment_path, notes, cash_transaction_id, client_ref, is_demo)
  values (v_id, p_order, p_date, p_kind, p_amount, p_account, p_method, p_reference, p_attachment, p_notes, v_cash, p_client_ref, o.is_demo);
  return v_id;
end $$;

create or replace function public.void_order_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.order_payments;
begin
  perform public.assert_owner();
  select * into v from public.order_payments where id = p_payment for update;
  if v.status <> 'posted' then raise exception 'Pembayaran sudah dibatalkan.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Alasan pembatalan minimal 5 karakter.'; end if;
  update public.order_payments set status = 'void', void_reason = p_reason where id = p_payment;
  perform public._void_cash(v.cash_transaction_id, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- Pekerja produksi harian
-- ---------------------------------------------------------------------
create table public.workers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(trim(name)) > 0),
  phone         text,
  default_rate  numeric(18,2) check (default_rate > 0),
  notes         text,
  is_active     boolean not null default true,
  is_demo       boolean not null default false,
  created_at    timestamptz not null default now()
);

create table public.work_days (
  id           uuid primary key default gen_random_uuid(),
  worker_id    uuid not null references public.workers(id),
  work_date    date not null,
  rate         numeric(18,2) not null check (rate > 0),  -- tarif aktual yang disepakati hari itu
  rate_note    text,
  order_id     uuid references public.orders(id),
  notes        text,
  status       text not null default 'hadir' check (status in ('hadir', 'batal')),
  void_reason  text,
  is_demo      boolean not null default false,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create unique index work_days_unique on public.work_days (worker_id, work_date) where status = 'hadir';

create or replace function public.work_days_before()
returns trigger language plpgsql as $$
declare v_min numeric := public.setting_num('wage_rate_min'); v_max numeric := public.setting_num('wage_rate_max');
begin
  if tg_op = 'UPDATE' then
    if old.status = 'batal' then raise exception 'Kehadiran sudah dibatalkan.'; end if;
    if exists (select 1 from public.wage_payments where work_day_id = old.id and status = 'posted')
       and (new.rate <> old.rate or new.status <> old.status) then
      raise exception 'Upah hari ini sudah (sebagian) dibayar. Batalkan pembayarannya dulu.';
    end if;
    if new.status = 'batal' and length(trim(coalesce(new.void_reason, ''))) < 5 then
      raise exception 'Alasan pembatalan kehadiran wajib diisi.';
    end if;
  end if;
  if (new.rate < v_min or new.rate > v_max) and length(trim(coalesce(new.rate_note, ''))) < 5 then
    raise exception 'Tarif % di luar rentang wajar %–%. Isi alasan tarif untuk melanjutkan.', public.fmt_rp(new.rate), public.fmt_rp(v_min), public.fmt_rp(v_max);
  end if;
  return new;
end $$;
create trigger work_days_before before insert or update on public.work_days for each row execute function public.work_days_before();
create trigger work_days_period before insert or update or delete on public.work_days
  for each row execute function public.guard_closed_period('work_date');
create trigger work_days_no_delete before delete on public.work_days for each row execute function public.forbid_delete();
create trigger work_days_audit after insert or update on public.work_days for each row execute function public.audit_trigger();

create table public.wage_payments (
  id                   uuid primary key default gen_random_uuid(),
  work_day_id          uuid not null references public.work_days(id),
  paid_at              timestamptz not null default now(),
  amount               numeric(18,2) not null check (amount > 0),
  account_id           uuid not null references public.cash_accounts(id),
  method               text not null check (method in ('tunai', 'transfer')),
  notes                text,
  attachment_path      text,
  status               text not null default 'posted' check (status in ('posted', 'void')),
  void_reason          text,
  cash_transaction_id  uuid unique references public.cash_transactions(id),
  client_ref           uuid unique,
  is_demo              boolean not null default false,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now()
);
create trigger wage_payments_no_delete before delete on public.wage_payments for each row execute function public.forbid_delete();
create trigger wage_payments_audit after insert or update on public.wage_payments for each row execute function public.audit_trigger();

create or replace view public.v_work_day_wages with (security_invoker = true) as
select w.id, w.worker_id, k.name as worker_name, w.work_date, w.rate, w.rate_note, w.order_id, w.status,
  coalesce(p.paid, 0)::numeric(18,2) as paid,
  (w.rate - coalesce(p.paid, 0))::numeric(18,2) as outstanding,
  case when coalesce(p.paid, 0) = 0 then 'belum_dibayar'
       when coalesce(p.paid, 0) < w.rate then 'sebagian' else 'lunas' end as pay_status,
  w.is_demo
from public.work_days w
join public.workers k on k.id = w.worker_id
left join (select work_day_id, sum(amount) paid from public.wage_payments where status = 'posted' group by work_day_id) p
  on p.work_day_id = w.id
where w.status = 'hadir';

create or replace function public.pay_wage(
  p_work_day uuid, p_account uuid, p_method text, p_amount numeric default null,
  p_notes text default null, p_attachment text default null, p_client_ref uuid default null, p_paid_at timestamptz default now())
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.work_days; v_name text; v_paid numeric; v_amount numeric; v_id uuid := gen_random_uuid(); v_cash uuid; v_existing uuid;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_existing from public.wage_payments where client_ref = p_client_ref;
    if v_existing is not null then return v_existing; end if;
  end if;
  select * into w from public.work_days where id = p_work_day for update;
  if w.id is null or w.status <> 'hadir' then raise exception 'Data kehadiran tidak valid.'; end if;
  select coalesce(sum(amount), 0) into v_paid from public.wage_payments where work_day_id = p_work_day and status = 'posted';
  v_amount := coalesce(p_amount, w.rate - v_paid);
  if v_amount <= 0 then raise exception 'Upah hari ini sudah lunas.'; end if;
  if v_paid + v_amount > w.rate then raise exception 'Pembayaran melebihi sisa upah (sisa %).', public.fmt_rp(w.rate - v_paid); end if;
  select name into v_name from public.workers where id = w.worker_id;
  v_cash := public._post_cash((p_paid_at at time zone 'Asia/Jakarta')::date, 'out', p_account, 'bayar_upah', v_amount, p_method,
    'Upah ' || v_name || ' ' || to_char(w.work_date, 'DD/MM/YYYY'), 'wage_payment', v_id, null, null, null, p_attachment, w.is_demo);
  insert into public.wage_payments (id, work_day_id, paid_at, amount, account_id, method, notes, attachment_path, cash_transaction_id, client_ref, is_demo)
  values (v_id, p_work_day, p_paid_at, v_amount, p_account, p_method, p_notes, p_attachment, v_cash, p_client_ref, w.is_demo);
  return v_id;
end $$;

create or replace function public.void_wage_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.wage_payments;
begin
  perform public.assert_owner();
  select * into v from public.wage_payments where id = p_payment for update;
  if v.status <> 'posted' then raise exception 'Pembayaran sudah dibatalkan.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Alasan pembatalan minimal 5 karakter.'; end if;
  update public.wage_payments set status = 'void', void_reason = p_reason where id = p_payment;
  perform public._void_cash(v.cash_transaction_id, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- Komisi marketing (fee per cup, snapshot di pesanan)
-- ---------------------------------------------------------------------
create table public.commission_payments (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references public.orders(id),
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
  is_demo              boolean not null default false,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now()
);
create trigger commission_payments_no_delete before delete on public.commission_payments for each row execute function public.forbid_delete();
create trigger commission_payments_audit after insert or update on public.commission_payments for each row execute function public.audit_trigger();

-- Dasar komisi:
--   'terkirim' → cup terkirim dikurangi retur.
--   'lunas'    → cup terkirim bersih × proporsi tagihan yang sudah dibayar (dibulatkan ke bawah).
create or replace view public.v_order_commissions with (security_invoker = true) as
with base as (
  select o.id as order_id, o.order_no, o.marketer_id, o.status, o.fee_per_cup, o.commission_basis,
    o.revenue_recognized_on, o.is_demo,
    greatest(coalesce((select sum(qty_delivered) from public.order_items where order_id = o.id and counts_for_commission), 0) - o.qty_returned, 0) as qty_net,
    case when o.total - o.return_credit > 0
         then least(public.order_paid(o.id) / (o.total - o.return_credit), 1) else 0 end as paid_ratio,
    coalesce((select sum(amount) from public.commission_payments where order_id = o.id and status = 'posted'), 0) as paid
  from public.orders o
  where o.marketer_id is not null and o.status <> 'batal'
)
select order_id, order_no, marketer_id, status, fee_per_cup, commission_basis, revenue_recognized_on, is_demo, qty_net,
  case commission_basis when 'terkirim' then qty_net else floor(qty_net * paid_ratio) end::integer as qty_eligible,
  (fee_per_cup * case commission_basis when 'terkirim' then qty_net else floor(qty_net * paid_ratio) end)::numeric(18,2) as earned,
  (fee_per_cup * qty_net)::numeric(18,2) as commission_full,
  paid::numeric(18,2) as paid,
  (fee_per_cup * case commission_basis when 'terkirim' then qty_net else floor(qty_net * paid_ratio) end - paid)::numeric(18,2) as outstanding
from base;

create or replace function public.pay_commission(
  p_order uuid, p_date date, p_amount numeric, p_account uuid, p_method text,
  p_notes text default null, p_attachment text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.orders; c record; v_id uuid := gen_random_uuid(); v_cash uuid; v_existing uuid; v_name text;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_existing from public.commission_payments where client_ref = p_client_ref;
    if v_existing is not null then return v_existing; end if;
  end if;
  select * into o from public.orders where id = p_order for update;
  select * into c from public.v_order_commissions where order_id = p_order;
  if c.order_id is null then raise exception 'Pesanan ini tidak punya marketing.'; end if;
  if p_amount > c.outstanding then raise exception 'Pembayaran melebihi komisi terutang (%).', public.fmt_rp(c.outstanding); end if;
  select name into v_name from public.marketers where id = o.marketer_id;
  v_cash := public._post_cash(p_date, 'out', p_account, 'bayar_komisi', p_amount, p_method,
    'Komisi ' || v_name || ' ' || o.order_no, 'commission_payment', v_id, o.order_no, null, null, p_attachment, o.is_demo);
  insert into public.commission_payments (id, order_id, payment_date, amount, account_id, method, notes, attachment_path, cash_transaction_id, client_ref, is_demo)
  values (v_id, p_order, p_date, p_amount, p_account, p_method, p_notes, p_attachment, v_cash, p_client_ref, o.is_demo);
  return v_id;
end $$;

create or replace function public.void_commission_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.commission_payments;
begin
  perform public.assert_owner();
  select * into v from public.commission_payments where id = p_payment for update;
  if v.status <> 'posted' then raise exception 'Pembayaran sudah dibatalkan.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Alasan pembatalan minimal 5 karakter.'; end if;
  update public.commission_payments set status = 'void', void_reason = p_reason where id = p_payment;
  perform public._void_cash(v.cash_transaction_id, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- Aset & depresiasi (garis lurus, revisi estimasi berlaku prospektif)
-- ---------------------------------------------------------------------
create table public.assets (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (length(trim(name)) > 0),
  category             text,
  acquisition_date     date not null,
  acquisition_cost     numeric(18,2) not null check (acquisition_cost > 0),
  capitalized_costs    numeric(18,2) not null default 0 check (capitalized_costs >= 0),
  useful_life_months   integer not null check (useful_life_months > 0),
  residual_value       numeric(18,2) not null default 0 check (residual_value >= 0),
  method               text not null default 'garis_lurus' check (method in ('garis_lurus')),
  depreciation_start   date not null,
  status               text not null default 'aktif' check (status in ('aktif', 'dilepas')),
  disposed_on          date,
  notes                text,
  cash_transaction_id  uuid references public.cash_transactions(id),
  is_demo              boolean not null default false,
  created_at           timestamptz not null default now(),
  check (residual_value < acquisition_cost + capitalized_costs)
);
create trigger assets_audit after insert or update on public.assets for each row execute function public.audit_trigger();
create trigger assets_no_delete before delete on public.assets for each row execute function public.forbid_delete();

create table public.depreciation_entries (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.assets(id),
  period      date not null check (extract(day from period) = 1),
  amount      numeric(18,2) not null check (amount >= 0),
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now(),
  unique (asset_id, period)
);
create trigger depreciation_period before insert or update or delete on public.depreciation_entries
  for each row execute function public.guard_closed_period('period');
create trigger depreciation_no_delete before delete on public.depreciation_entries for each row execute function public.forbid_delete();
create trigger depreciation_no_update before update on public.depreciation_entries for each row execute function public.forbid_update();

-- Depresiasi TIDAK menyentuh kas. Kas berkurang saat pembelian aset dibayar.
create or replace function public.post_depreciation(p_period date)
returns integer language plpgsql security definer set search_path = public as $$
declare a record; v_period date := date_trunc('month', p_period)::date; v_acc numeric; v_posted integer;
  v_remaining_months integer; v_base numeric; v_amt numeric; n integer := 0;
begin
  perform public.assert_owner();
  for a in select * from public.assets
           where status = 'aktif' and date_trunc('month', depreciation_start)::date <= v_period
           order by id for update loop
    if exists (select 1 from public.depreciation_entries where asset_id = a.id and period = v_period) then continue; end if;
    select coalesce(sum(amount), 0), count(*) into v_acc, v_posted from public.depreciation_entries where asset_id = a.id;
    v_base := a.acquisition_cost + a.capitalized_costs - a.residual_value;
    v_remaining_months := a.useful_life_months - v_posted;
    if v_remaining_months <= 0 or v_acc >= v_base then continue; end if;
    v_amt := case when v_remaining_months = 1 then v_base - v_acc else round((v_base - v_acc) / v_remaining_months, 2) end;
    insert into public.depreciation_entries (asset_id, period, amount, is_demo) values (a.id, v_period, v_amt, a.is_demo);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace view public.v_asset_book_values with (security_invoker = true) as
select a.*, (a.acquisition_cost + a.capitalized_costs)::numeric(18,2) as total_cost,
  round((a.acquisition_cost + a.capitalized_costs - a.residual_value) / a.useful_life_months, 2) as monthly_depreciation_initial,
  coalesce(d.acc, 0)::numeric(18,2) as accumulated_depreciation,
  (a.acquisition_cost + a.capitalized_costs - coalesce(d.acc, 0))::numeric(18,2) as book_value
from public.assets a
left join (select asset_id, sum(amount) acc from public.depreciation_entries group by asset_id) d on d.asset_id = a.id;

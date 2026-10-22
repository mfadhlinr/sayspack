-- =====================================================================
-- Sayspack Management System — Migrasi 1: Fondasi & Keuangan
-- Prinsip:
--   * Satu sumber kebenaran untuk kas: tabel cash_transactions.
--   * Transaksi yang sudah diposting tidak bisa dihapus/diubah; koreksi = pembatalan (void) + alasan.
--   * Periode yang sudah ditutup terkunci (trigger guard_closed_period).
--   * Semua aksi tulis penting lewat fungsi (RPC) yang atomik dan cek role owner.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Role & profil
-- ---------------------------------------------------------------------
create type public.app_role as enum ('owner', 'investor', 'staff', 'pending');

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  role        public.app_role not null default 'pending',
  created_at  timestamptz not null default now()
);

create or replace function public.current_app_role()
returns public.app_role language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'pending'::public.app_role)
$$;

create or replace function public.is_owner()
returns boolean language sql stable as $$ select public.current_app_role() = 'owner' $$;

create or replace function public.can_read_reports()
returns boolean language sql stable as $$ select public.current_app_role() in ('owner', 'investor') $$;

create or replace function public.assert_owner()
returns void language plpgsql stable as $$
begin
  if not public.is_owner() then
    raise exception 'Hanya owner yang boleh melakukan aksi ini.' using errcode = '42501';
  end if;
end $$;

-- User pertama otomatis jadi owner; user berikutnya 'pending' (tanpa akses) sampai owner mengubah role-nya.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    case when exists (select 1 from public.profiles where role = 'owner') then 'pending'::public.app_role else 'owner'::public.app_role end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Pengaturan aplikasi
-- ---------------------------------------------------------------------
create table public.app_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid()
);

insert into public.app_settings (key, value, description) values
  ('wage_rate_min', '40000', 'Batas bawah tarif harian wajar (Rp)'),
  ('wage_rate_max', '70000', 'Batas atas tarif harian wajar (Rp)'),
  ('revenue_recognition', '"selesai"', 'Status pesanan saat penjualan diakui sebagai omzet: terkirim atau selesai'),
  ('commission_basis_default', '"terkirim"', 'Dasar kelayakan komisi default: terkirim atau lunas'),
  ('commission_basis_confirmed', 'false', 'Apakah owner sudah menyetujui dasar komisi'),
  ('initial_capital', '55000000', 'Modal awal investor sesuai perjanjian (Rp) — referensi, bukan transaksi kas');

create or replace function public.setting_num(p_key text)
returns numeric language sql stable security definer set search_path = public as $$
  select (value #>> '{}')::numeric from public.app_settings where key = p_key
$$;

create or replace function public.setting_text(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value #>> '{}' from public.app_settings where key = p_key
$$;

create or replace function public.fmt_rp(p numeric)
returns text language sql immutable as $$
  select 'Rp' || replace(to_char(round(coalesce(p, 0)), 'FM999G999G999G999G990'), ',', '.')
$$;

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create table public.audit_log (
  id          bigserial primary key,
  table_name  text not null,
  row_id      text,
  action      text not null,
  old_data    jsonb,
  new_data    jsonb,
  actor       uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index audit_log_table_row_idx on public.audit_log (table_name, row_id);

create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (table_name, row_id, action, old_data, new_data)
  values (
    tg_table_name,
    coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id', to_jsonb(new)->>'key', to_jsonb(new)->>'period'),
    tg_op,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

-- Data posting tidak boleh dihapus. Pengecualian: data DEMO saat purge_demo_data() berjalan.
create or replace function public.forbid_delete()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.demo_purge', true), '') = 'on'
     and coalesce((to_jsonb(old)->>'is_demo')::boolean, false) then
    return old;
  end if;
  raise exception 'Data % tidak boleh dihapus. Gunakan pembatalan dengan alasan.', tg_table_name;
end $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create trigger app_settings_audit after insert or update or delete on public.app_settings
  for each row execute function public.audit_trigger();
create trigger app_settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Nomor dokumen otomatis (TRX-2610-0001, SP-2610-0001, dll.)
-- ---------------------------------------------------------------------
create table public.doc_counters (
  prefix   text not null,
  period   text not null,
  last_no  integer not null,
  primary key (prefix, period)
);

create or replace function public.next_doc_no(p_prefix text, p_date date)
returns text language plpgsql security definer set search_path = public as $$
declare v_period text := to_char(p_date, 'YYMM'); v_no integer;
begin
  insert into public.doc_counters (prefix, period, last_no) values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_no = public.doc_counters.last_no + 1
  returning last_no into v_no;
  return p_prefix || '-' || v_period || '-' || lpad(v_no::text, 4, '0');
end $$;

-- ---------------------------------------------------------------------
-- Periode akuntansi & aturan bagi hasil
-- ---------------------------------------------------------------------
create table public.profit_sharing_rules (
  id                  uuid primary key default gen_random_uuid(),
  effective_from      date not null,
  reserve_pct         numeric(5,2) not null check (reserve_pct between 0 and 100),
  investor_pct        numeric(5,2) not null check (investor_pct between 0 and 100),
  owner_pct           numeric(5,2) not null check (owner_pct between 0 and 100),
  agreement_notes     text,
  loss_policy         text,
  loss_policy_agreed  boolean not null default false,
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  check (investor_pct + owner_pct = 100)
);
comment on column public.profit_sharing_rules.investor_pct is 'Persentase investor dari laba SETELAH cadangan';

insert into public.profit_sharing_rules (effective_from, reserve_pct, investor_pct, owner_pct, agreement_notes, loss_policy, loss_policy_agreed)
values ('2026-01-01', 10, 50, 50,
  'Rencana awal: 10% laba bersih untuk cadangan usaha, sisa 90% dibagi 50:50 (setara 45% investor, 45% pemilik). Modal awal investor Rp55.000.000.',
  null, false);

-- Riwayat aturan: aturan lama tidak diubah, buat aturan baru dengan tanggal berlaku baru.
create trigger profit_sharing_rules_no_update before update or delete on public.profit_sharing_rules
  for each row execute function public.forbid_delete();
create trigger profit_sharing_rules_audit after insert on public.profit_sharing_rules
  for each row execute function public.audit_trigger();

create table public.accounting_periods (
  period            date primary key check (extract(day from period) = 1),
  status            text not null default 'open' check (status in ('open', 'closed')),
  pnl               jsonb,
  net_profit        numeric(18,2),
  reserve_amount    numeric(18,2),
  investor_amount   numeric(18,2),
  owner_amount      numeric(18,2),
  rule_id           uuid references public.profit_sharing_rules(id),
  notes             text,
  closed_at         timestamptz,
  closed_by         uuid
);
create trigger accounting_periods_audit after insert or update or delete on public.accounting_periods
  for each row execute function public.audit_trigger();

create or replace function public.is_period_closed(p_date date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.accounting_periods
                 where period = date_trunc('month', p_date)::date and status = 'closed')
$$;

-- Dipasang di tabel transaksi: TG_ARGV[0] = nama kolom tanggal.
create or replace function public.guard_closed_period()
returns trigger language plpgsql as $$
declare v_col text := tg_argv[0]; v_new date; v_old date;
begin
  if tg_op in ('INSERT', 'UPDATE') then v_new := (to_jsonb(new)->>v_col)::date; end if;
  if tg_op in ('UPDATE', 'DELETE') then v_old := (to_jsonb(old)->>v_col)::date; end if;
  if (v_new is not null and public.is_period_closed(v_new))
     or (v_old is not null and public.is_period_closed(v_old)) then
    raise exception 'Periode % sudah ditutup. Catat penyesuaian di periode yang masih terbuka.',
      to_char(coalesce(v_new, v_old), 'MM/YYYY') using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;

-- ---------------------------------------------------------------------
-- Pihak terkait
-- ---------------------------------------------------------------------
create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  contact     text,
  phone       text,
  address     text,
  notes       text,
  is_active   boolean not null default true,
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now()
);

create table public.suppliers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  phone       text,
  address     text,
  notes       text,
  is_active   boolean not null default true,
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Keuangan: akun, kategori, transaksi kas
-- ---------------------------------------------------------------------
create table public.cash_accounts (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique check (length(trim(name)) > 0),
  kind          text not null check (kind in ('kas', 'bank', 'ewallet')),
  account_info  text,
  is_active     boolean not null default true,
  is_demo       boolean not null default false,
  created_at    timestamptz not null default now()
);
create trigger cash_accounts_audit after insert or update or delete on public.cash_accounts
  for each row execute function public.audit_trigger();

-- report_group menentukan apakah transaksi masuk laporan laba-rugi.
--   Masuk L/R: pendapatan_lain, beban_operasional.
--   Tidak masuk L/R (dicatat lewat modul lain atau bukan laba): sisanya.
create table public.transaction_categories (
  id            uuid primary key default gen_random_uuid(),
  code          text unique,
  name          text not null,
  direction     text not null check (direction in ('in', 'out')),
  report_group  text not null check (report_group in (
                  'pendapatan_lain', 'beban_operasional', 'saldo_awal', 'modal', 'penerimaan_pelanggan',
                  'pembelian_persediaan', 'pembelian_aset', 'upah', 'komisi', 'bagi_hasil',
                  'transfer', 'pinjaman', 'lainnya_non_lr')),
  description   text,
  is_system     boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (name, direction)
);

insert into public.transaction_categories (code, name, direction, report_group, is_system, description) values
  ('saldo_awal_in',      'Saldo awal',                     'in',  'saldo_awal',           true,  'Saldo saat sistem mulai dipakai'),
  ('modal_investor',     'Setoran modal investor',         'in',  'modal',                true,  'Modal usaha, bukan pendapatan'),
  ('modal_owner',        'Setoran modal pemilik',          'in',  'modal',                true,  null),
  ('penerimaan_pesanan', 'Pembayaran pelanggan',           'in',  'penerimaan_pelanggan', true,  'DP/pelunasan pesanan — omzet diakui dari pesanan, bukan dari pembayaran'),
  ('refund_pesanan',     'Pengembalian dana pelanggan',    'out', 'penerimaan_pelanggan', true,  null),
  ('transfer_in',        'Transfer masuk antar akun',      'in',  'transfer',             true,  null),
  ('transfer_out',       'Transfer keluar antar akun',     'out', 'transfer',             true,  null),
  ('bayar_pemasok',      'Pembayaran pembelian persediaan','out', 'pembelian_persediaan', true,  'Biaya masuk ke HPP saat barang dipakai/dikirim'),
  ('beli_aset',          'Pembelian aset',                 'out', 'pembelian_aset',       true,  'Dikapitalisasi; beban lewat depresiasi'),
  ('bayar_upah',         'Pembayaran upah harian',         'out', 'upah',                 true,  'Beban upah diakui dari kehadiran'),
  ('bayar_komisi',       'Pembayaran komisi marketing',    'out', 'komisi',               true,  'Beban komisi diakui dari pesanan'),
  ('bayar_bagi_hasil',   'Pembayaran bagi hasil',          'out', 'bagi_hasil',           true,  'Distribusi laba, bukan beban'),
  ('pinjaman_in',        'Penerimaan pinjaman',            'in',  'pinjaman',             true,  null),
  ('pinjaman_out',       'Pembayaran pokok pinjaman',      'out', 'pinjaman',             true,  null),
  (null, 'Pendapatan lain-lain',     'in',  'pendapatan_lain',   false, null),
  (null, 'Listrik & air',            'out', 'beban_operasional', false, null),
  (null, 'Sewa tempat',              'out', 'beban_operasional', false, null),
  (null, 'Transportasi & ongkir',    'out', 'beban_operasional', false, null),
  (null, 'Internet & pulsa',         'out', 'beban_operasional', false, null),
  (null, 'Perawatan mesin',          'out', 'beban_operasional', false, null),
  (null, 'Promosi',                  'out', 'beban_operasional', false, null),
  (null, 'Konsumsi',                 'out', 'beban_operasional', false, null),
  (null, 'Biaya admin bank',         'out', 'beban_operasional', false, null),
  (null, 'Beban lain-lain',          'out', 'beban_operasional', false, null);

create table public.cash_transactions (
  id               uuid primary key default gen_random_uuid(),
  trx_no           text unique,
  trx_date         date not null,
  due_date         date,
  direction        text not null check (direction in ('in', 'out')),
  account_id       uuid not null references public.cash_accounts(id),
  category_id      uuid not null references public.transaction_categories(id),
  amount           numeric(18,2) not null check (amount > 0),
  payment_method   text not null check (payment_method in ('tunai', 'transfer')),
  description      text not null check (length(trim(description)) > 0),
  reference_no     text,
  customer_id      uuid references public.customers(id),
  supplier_id      uuid references public.suppliers(id),
  attachment_path  text,
  source_type      text,
  source_id        uuid,
  client_ref       uuid unique,
  status           text not null default 'posted' check (status in ('posted', 'void')),
  void_reason      text,
  voided_at        timestamptz,
  voided_by        uuid,
  is_demo          boolean not null default false,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  check (status = 'posted' or length(trim(coalesce(void_reason, ''))) >= 5)
);
-- Satu dokumen sumber (pembayaran upah, pembayaran pesanan, dst.) hanya boleh punya satu transaksi kas aktif.
create unique index cash_transactions_source_uniq on public.cash_transactions (source_type, source_id)
  where source_type is not null and status = 'posted';
create index cash_transactions_date_idx on public.cash_transactions (trx_date);
create index cash_transactions_account_idx on public.cash_transactions (account_id);

create or replace function public.cash_tx_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cat public.transaction_categories; v_acc public.cash_accounts;
begin
  if tg_op = 'INSERT' then
    select * into v_cat from public.transaction_categories where id = new.category_id;
    if v_cat.direction <> new.direction then
      raise exception 'Kategori "%" tidak cocok untuk transaksi %.', v_cat.name,
        case new.direction when 'in' then 'masuk' else 'keluar' end;
    end if;
    select * into v_acc from public.cash_accounts where id = new.account_id;
    if not v_acc.is_active then raise exception 'Akun % sudah nonaktif.', v_acc.name; end if;
    new.status := 'posted';
    new.void_reason := null; new.voided_at := null; new.voided_by := null;
    new.trx_no := public.next_doc_no('TRX', new.trx_date);
    return new;
  end if;
  -- UPDATE: hanya boleh pembatalan, isi lain tidak boleh berubah.
  if old.status = 'void' then raise exception 'Transaksi % sudah dibatalkan.', old.trx_no; end if;
  if new.status <> 'void'
     or (to_jsonb(new) - array['status','void_reason','voided_at','voided_by','attachment_path'])
        is distinct from (to_jsonb(old) - array['status','void_reason','voided_at','voided_by','attachment_path']) then
    raise exception 'Transaksi yang sudah diposting tidak bisa diubah. Batalkan lalu catat ulang.';
  end if;
  new.voided_at := now(); new.voided_by := auth.uid();
  return new;
end $$;

create trigger cash_tx_before before insert or update on public.cash_transactions
  for each row execute function public.cash_tx_before();
create trigger cash_tx_period before insert or update or delete on public.cash_transactions
  for each row execute function public.guard_closed_period('trx_date');
create trigger cash_tx_no_delete before delete on public.cash_transactions
  for each row execute function public.forbid_delete();
create trigger cash_tx_audit after insert or update on public.cash_transactions
  for each row execute function public.audit_trigger();

-- Helper internal untuk modul lain (dipanggil dari fungsi SECURITY DEFINER).
create or replace function public._post_cash(
  p_date date, p_direction text, p_account uuid, p_category_code text, p_amount numeric,
  p_method text, p_description text, p_source_type text, p_source_id uuid,
  p_reference text default null, p_customer uuid default null, p_supplier uuid default null,
  p_attachment text default null, p_is_demo boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_cat uuid;
begin
  select id into v_cat from public.transaction_categories where code = p_category_code;
  if v_cat is null then raise exception 'Kategori sistem % tidak ditemukan.', p_category_code; end if;
  insert into public.cash_transactions (trx_date, direction, account_id, category_id, amount, payment_method,
    description, reference_no, customer_id, supplier_id, attachment_path, source_type, source_id, is_demo)
  values (p_date, p_direction, p_account, v_cat, p_amount, p_method, p_description, p_reference,
    p_customer, p_supplier, p_attachment, p_source_type, p_source_id, p_is_demo)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public._void_cash(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.cash_transactions set status = 'void', void_reason = p_reason
  where id = p_id and status = 'posted';
end $$;

-- Transaksi manual (pemasukan/pengeluaran umum). client_ref mencegah dobel klik.
create or replace function public.record_cash_transaction(
  p_date date, p_direction text, p_account uuid, p_category uuid, p_amount numeric,
  p_method text, p_description text, p_reference text default null, p_due_date date default null,
  p_customer uuid default null, p_supplier uuid default null, p_attachment text default null,
  p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_cat public.transaction_categories;
begin
  perform public.assert_owner();
  if p_client_ref is not null then
    select id into v_id from public.cash_transactions where client_ref = p_client_ref;
    if v_id is not null then return v_id; end if;
  end if;
  select * into v_cat from public.transaction_categories where id = p_category;
  if v_cat.code is not null and v_cat.code not in ('saldo_awal_in','modal_investor','modal_owner','pinjaman_in','pinjaman_out','beli_aset') then
    raise exception 'Kategori "%" dicatat otomatis dari modulnya, bukan dari input manual.', v_cat.name;
  end if;
  insert into public.cash_transactions (trx_date, due_date, direction, account_id, category_id, amount,
    payment_method, description, reference_no, customer_id, supplier_id, attachment_path, client_ref, source_type)
  values (p_date, p_due_date, p_direction, p_account, p_category, p_amount, p_method, p_description,
    p_reference, p_customer, p_supplier, p_attachment, p_client_ref, null)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.void_cash_transaction(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_tx public.cash_transactions;
begin
  perform public.assert_owner();
  select * into v_tx from public.cash_transactions where id = p_id for update;
  if v_tx.id is null then raise exception 'Transaksi tidak ditemukan.'; end if;
  if v_tx.source_type is not null and v_tx.source_type not in ('transfer') then
    raise exception 'Transaksi ini dibuat dari modul lain (%). Batalkan dari modul asalnya.', v_tx.source_type;
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Alasan pembatalan minimal 5 karakter.'; end if;
  if v_tx.source_type = 'transfer' then
    -- Transfer dibatalkan sepasang.
    update public.cash_transactions set status = 'void', void_reason = p_reason
    where source_type = 'transfer' and reference_no = v_tx.reference_no and status = 'posted';
  else
    perform public._void_cash(p_id, p_reason);
  end if;
end $$;

create or replace function public.transfer_between_accounts(
  p_date date, p_from uuid, p_to uuid, p_amount numeric, p_method text, p_note text, p_client_ref uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_ref text; v_in uuid := gen_random_uuid();
begin
  perform public.assert_owner();
  if p_from = p_to then raise exception 'Akun asal dan tujuan harus berbeda.'; end if;
  if p_client_ref is not null and exists (select 1 from public.cash_transactions where client_ref = p_client_ref) then
    select reference_no into v_ref from public.cash_transactions where client_ref = p_client_ref; return v_ref;
  end if;
  v_ref := public.next_doc_no('TRF', p_date);
  insert into public.cash_transactions (trx_date, direction, account_id, category_id, amount, payment_method,
    description, reference_no, source_type, source_id, client_ref)
  values (p_date, 'out', p_from, (select id from public.transaction_categories where code = 'transfer_out'),
    p_amount, p_method, coalesce(p_note, 'Transfer antar akun'), v_ref, 'transfer', gen_random_uuid(), p_client_ref);
  insert into public.cash_transactions (trx_date, direction, account_id, category_id, amount, payment_method,
    description, reference_no, source_type, source_id)
  values (p_date, 'in', p_to, (select id from public.transaction_categories where code = 'transfer_in'),
    p_amount, p_method, coalesce(p_note, 'Transfer antar akun'), v_ref, 'transfer', v_in);
  return v_ref;
end $$;

create or replace function public.account_balance(p_account uuid, p_as_of date default null)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when direction = 'in' then amount else -amount end), 0)
  from public.cash_transactions
  where account_id = p_account and status = 'posted' and (p_as_of is null or trx_date <= p_as_of)
$$;

create or replace view public.v_account_balances with (security_invoker = true) as
select a.id, a.name, a.kind, a.account_info, a.is_active,
  coalesce(sum(case when t.direction = 'in' then t.amount else -t.amount end) filter (where t.status = 'posted'), 0)::numeric(18,2) as balance
from public.cash_accounts a
left join public.cash_transactions t on t.account_id = a.id
group by a.id;

-- Rekonsiliasi: bandingkan saldo sistem dengan saldo rekening koran / hitung fisik.
create table public.reconciliations (
  id                 uuid primary key default gen_random_uuid(),
  account_id         uuid not null references public.cash_accounts(id),
  as_of              date not null,
  statement_balance  numeric(18,2) not null,
  system_balance     numeric(18,2) not null,
  difference         numeric(18,2) generated always as (statement_balance - system_balance) stored,
  notes              text,
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now()
);
create trigger reconciliations_no_delete before update or delete on public.reconciliations
  for each row execute function public.forbid_delete();

create or replace function public.record_reconciliation(p_account uuid, p_as_of date, p_statement numeric, p_notes text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.assert_owner();
  insert into public.reconciliations (account_id, as_of, statement_balance, system_balance, notes)
  values (p_account, p_as_of, p_statement, public.account_balance(p_account, p_as_of), p_notes)
  returning id into v_id;
  return v_id;
end $$;

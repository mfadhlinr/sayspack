import Link from "next/link";
import { getSession } from "@/lib/auth";
import { periodFromParam, shiftMonth, tanggal } from "@/lib/format";
import { Badge, Card, EmptyState, Flash, Money, PageHeader, PeriodNav, btn, input } from "@/components/ui";
import { VoidButton } from "./void-button";

export const metadata = { title: "Transaksi" };
const PAGE = 50;

const SOURCE_LABEL: Record<string, string> = {
  order_payment: "Pesanan", wage_payment: "Upah", commission_payment: "Komisi", purchase_payment: "Pembelian",
  profit_payout: "Bagi hasil", transfer: "Transfer",
};

type Tx = {
  id: string; trx_no: string; trx_date: string; due_date: string | null; direction: "in" | "out"; amount: number;
  payment_method: string; description: string; reference_no: string | null; attachment_path: string | null;
  source_type: string | null; status: "posted" | "void"; void_reason: string | null;
  cash_accounts: { name: string } | null; transaction_categories: { name: string } | null;
};

export default async function TransactionsPage({ searchParams }: {
  searchParams: Promise<{ bulan?: string; arah?: string; akun?: string; q?: string; status?: string; hal?: string; ok?: string }>;
}) {
  const sp = await searchParams;
  const { supabase, role } = await getSession();
  const period = periodFromParam(sp.bulan);
  const page = Math.max(1, Number(sp.hal) || 1);

  let query = supabase.from("cash_transactions")
    .select("id, trx_no, trx_date, due_date, direction, amount, payment_method, description, reference_no, attachment_path, source_type, status, void_reason, cash_accounts(name), transaction_categories(name)", { count: "exact" })
    .gte("trx_date", period.from).lte("trx_date", period.to)
    .order("trx_date", { ascending: false }).order("created_at", { ascending: false })
    .range((page - 1) * PAGE, page * PAGE - 1);
  if (sp.arah === "in" || sp.arah === "out") query = query.eq("direction", sp.arah);
  if (sp.akun) query = query.eq("account_id", sp.akun);
  if (sp.status !== "semua") query = query.eq("status", "posted");
  if (sp.q) {
    const q = sp.q.replace(/[%,()]/g, " ").trim();
    if (q) query = query.or(`description.ilike.%${q}%,reference_no.ilike.%${q}%,trx_no.ilike.%${q}%`);
  }

  const [{ data, count, error }, { data: accounts }] = await Promise.all([
    query, supabase.from("cash_accounts").select("id, name").order("name"),
  ]);
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as unknown as Tx[];
  const posted = rows.filter((r) => r.status === "posted");
  const totalIn = posted.filter((r) => r.direction === "in").reduce((a, r) => a + Number(r.amount), 0);
  const totalOut = posted.filter((r) => r.direction === "out").reduce((a, r) => a + Number(r.amount), 0);
  const extra = (o: Record<string, string | undefined>) =>
    Object.entries({ arah: sp.arah, akun: sp.akun, q: sp.q, status: sp.status, ...o }).filter(([, v]) => v).map(([k, v]) => `&${k}=${encodeURIComponent(v!)}`).join("");

  return (
    <>
      <PageHeader title="Transaksi kas" subtitle="Semua uang masuk dan keluar. Transaksi tidak bisa dihapus, hanya dibatalkan dengan alasan."
        action={role === "owner" ? <Link href="/keuangan/baru" className={btn.primary}>Catat transaksi</Link> : undefined} />
      <Flash ok={sp.ok} />

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <PeriodNav ym={period.ym} prev={shiftMonth(period.ym, -1)} next={shiftMonth(period.ym, 1)} isCurrent={period.isCurrent} basePath="/keuangan" extra={extra({})} />
        <form className="flex flex-1 flex-wrap gap-2" role="search">
          <input type="hidden" name="bulan" value={period.ym} />
          <input name="q" defaultValue={sp.q} placeholder="Cari keterangan / nomor" className={`${input} min-w-40 flex-1`} aria-label="Cari transaksi" />
          <select name="arah" defaultValue={sp.arah ?? ""} className={`${input} w-auto`} aria-label="Jenis">
            <option value="">Masuk & keluar</option><option value="in">Masuk</option><option value="out">Keluar</option>
          </select>
          <select name="akun" defaultValue={sp.akun ?? ""} className={`${input} w-auto`} aria-label="Akun">
            <option value="">Semua akun</option>
            {(accounts ?? []).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select>
          <select name="status" defaultValue={sp.status ?? ""} className={`${input} w-auto`} aria-label="Status">
            <option value="">Aktif saja</option><option value="semua">Termasuk dibatalkan</option>
          </select>
          <button className={btn.secondary}>Terapkan</button>
        </form>
      </div>

      <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Card><p className="text-xs text-ink-soft">Masuk (halaman ini)</p><Money value={totalIn} className="text-lg font-bold text-plus" /></Card>
        <Card><p className="text-xs text-ink-soft">Keluar (halaman ini)</p><Money value={totalOut} className="text-lg font-bold text-minus" /></Card>
        <Card className="col-span-2 sm:col-span-1"><p className="text-xs text-ink-soft">Jumlah transaksi</p><p className="text-lg font-bold num">{count ?? 0}</p></Card>
      </div>

      {rows.length === 0 ? (
        <EmptyState title="Belum ada transaksi di periode ini"
          body="Mulai dengan mencatat saldo awal setiap akun, lalu setoran modal investor saat dana diterima."
          action={role === "owner" ? <Link href="/keuangan/baru" className={btn.primary}>Catat transaksi</Link> : undefined} />
      ) : (
        <Card className="overflow-hidden p-0 sm:p-0">
          <ul className="divide-y divide-line">
            {rows.map((r) => (
              <li key={r.id} className={`grid gap-1 px-4 py-3 sm:grid-cols-[6.5rem_1fr_auto] sm:items-center sm:gap-4 ${r.status === "void" ? "bg-paper/70 opacity-70" : ""}`}>
                <div className="text-xs text-ink-soft">
                  <p className="font-medium text-ink">{tanggal(r.trx_date)}</p>
                  <p className="num">{r.trx_no}</p>
                </div>
                <div className="min-w-0">
                  <p className={`truncate font-medium ${r.status === "void" ? "line-through" : ""}`}>{r.description}</p>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-ink-soft">
                    <Badge>{r.transaction_categories?.name}</Badge>
                    <span>{r.cash_accounts?.name} · {r.payment_method}</span>
                    {r.reference_no && <span>Ref {r.reference_no}</span>}
                    {r.source_type && <Badge tone="info">Dari {SOURCE_LABEL[r.source_type] ?? r.source_type}</Badge>}
                    {r.due_date && <span>Jatuh tempo {tanggal(r.due_date)}</span>}
                    {r.status === "void" && <Badge tone="bad">Dibatalkan: {r.void_reason}</Badge>}
                    {r.attachment_path
                      ? <a href={`/bukti?path=${encodeURIComponent(r.attachment_path)}`} target="_blank" rel="noopener" className="font-semibold text-teal">Lihat bukti</a>
                      : !r.source_type && r.status === "posted" && <Badge tone="warn">Belum ada bukti</Badge>}
                  </div>
                </div>
                <div className="flex items-center justify-between gap-4 sm:flex-col sm:items-end sm:gap-1">
                  <Money value={r.direction === "in" ? r.amount : -r.amount} signed className="font-semibold" />
                  {role === "owner" && r.status === "posted" && (!r.source_type || r.source_type === "transfer") && (
                    <VoidButton id={r.id} trxNo={r.trx_no} description={r.description} />
                  )}
                </div>
              </li>
            ))}
          </ul>
        </Card>
      )}

      {(count ?? 0) > PAGE && (
        <div className="mt-4 flex justify-between text-sm">
          {page > 1 ? <Link className={btn.link} href={`/keuangan?bulan=${period.ym}${extra({ hal: String(page - 1) })}`}>‹ Sebelumnya</Link> : <span />}
          {page * PAGE < (count ?? 0) && <Link className={btn.link} href={`/keuangan?bulan=${period.ym}${extra({ hal: String(page + 1) })}`}>Berikutnya ›</Link>}
        </div>
      )}
    </>
  );
}

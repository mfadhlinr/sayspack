import Link from "next/link";
import { getSession } from "@/lib/auth";
import { bulan, periodFromParam, shiftMonth } from "@/lib/format";
import { Badge, Card, Hint, Money, PageHeader, PeriodNav } from "@/components/ui";

export const metadata = { title: "Dashboard" };

type Pnl = {
  revenue: number; cogs_materials: number; labor: number; gross_profit: number; commission: number;
  opex: number; other_income: number; inventory_adjustments: number; depreciation: number; net_profit: number; orders_recognized: number;
};
type Summary = {
  cash_total: number; accounts: { id: string; name: string; kind: string; balance: number }[];
  pnl: Pnl; cash_in: number; cash_out: number; capital_in: number; initial_capital: number;
  orders_by_status: Record<string, number>; active_orders: number; receivables: number;
  inventory_value: number; low_stock: { sku: string; name: string; qty: number; min: number; unit: string }[];
  unpaid_wages: number; unpaid_commissions: number; assets_cost: number; assets_book_value: number;
  last_closed: { period: string; net_profit: number; reserve: number; investor: number; owner: number } | null;
  reserve_total: number;
  profit_simulation: { reserve: number; investor: number; owner: number; is_loss: boolean; reserve_pct: number; investor_pct: number; owner_pct: number };
};

const STATUS_LABEL: Record<string, string> = {
  prospek: "Prospek", penawaran: "Penawaran", dikonfirmasi: "Dikonfirmasi", menunggu_bahan: "Menunggu bahan",
  produksi: "Produksi", qc: "QC", siap_dikirim: "Siap dikirim", terkirim: "Terkirim",
};

function Row({ label, value, strong = false, minus = false, hint }: { label: string; value: number; strong?: boolean; minus?: boolean; hint?: string }) {
  return (
    <div className={`flex items-baseline justify-between gap-3 py-1.5 ${strong ? "border-t border-line pt-2.5 font-semibold" : ""}`}>
      <span className="text-sm" title={hint}>{label}</span>
      <Money value={minus ? -value : value} className={strong ? "text-base" : "text-sm"} signed={strong} />
    </div>
  );
}

export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ bulan?: string }> }) {
  const sp = await searchParams;
  const { supabase, role } = await getSession();
  const period = periodFromParam(sp.bulan);
  const { data, error } = await supabase.rpc("dashboard_summary", { p_from: period.from, p_to: period.to });
  if (error) throw new Error(error.message);
  const s = data as Summary;
  const { data: periodRow } = await supabase.from("accounting_periods").select("status").eq("period", period.from).maybeSingle();
  const closed = periodRow?.status === "closed";
  const pnl = s.pnl;

  return (
    <>
      <PageHeader title="Dashboard" subtitle={role === "investor" ? "Tampilan baca-saja untuk investor" : undefined}
        action={<PeriodNav ym={period.ym} prev={shiftMonth(period.ym, -1)} next={shiftMonth(period.ym, 1)} isCurrent={period.isCurrent} basePath="/" />} />

      {/* Inti dashboard: uang yang ada ≠ hasil usaha. */}
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <div className="flex items-baseline justify-between">
            <h2 className="font-semibold">Uang yang ada sekarang</h2>
            <Badge tone="info">Saldo aktual</Badge>
          </div>
          <p className="mt-2 text-3xl font-bold"><Money value={s.cash_total} /></p>
          <Hint>Jumlah saldo semua akun kas & bank dari transaksi yang benar-benar terjadi. Saldo kas bukan laba — di dalamnya ada modal, DP pelanggan, dan uang yang belum dipakai.</Hint>
          <ul className="mt-3 divide-y divide-line text-sm">
            {s.accounts.map((a) => (
              <li key={a.id} className="flex justify-between py-1.5"><span>{a.name}</span><Money value={a.balance} signed={a.balance < 0} /></li>
            ))}
            {s.accounts.length === 0 && <li className="py-2 text-ink-soft">Belum ada akun. {role === "owner" && <Link href="/akun" className="font-semibold text-teal">Tambah akun kas</Link>}</li>}
          </ul>
          <div className="mt-3 grid grid-cols-2 gap-2 rounded-lg bg-paper p-3 text-sm">
            <div><p className="text-ink-soft">Masuk {bulan(period.from)}</p><Money value={s.cash_in} className="font-semibold" /></div>
            <div><p className="text-ink-soft">Keluar</p><Money value={s.cash_out} className="font-semibold" /></div>
          </div>
        </Card>

        <Card>
          <div className="flex items-baseline justify-between">
            <h2 className="font-semibold">Hasil usaha {bulan(period.from)}</h2>
            {closed ? <Badge tone="good">Sudah ditutup</Badge> : <Badge tone="warn">Sementara</Badge>}
          </div>
          <div className="mt-2">
            <Row label={`Omzet (${pnl.orders_recognized} pesanan diakui)`} value={pnl.revenue} hint="Pesanan yang sudah mencapai status pengakuan penjualan" />
            <Row label="HPP cup & bahan" value={pnl.cogs_materials} minus />
            <Row label="Upah produksi" value={pnl.labor} minus />
            <Row label="Komisi marketing" value={pnl.commission} minus />
            <Row label="Beban operasional" value={pnl.opex} minus />
            {Number(pnl.other_income) !== 0 && <Row label="Pendapatan lain" value={pnl.other_income} />}
            {Number(pnl.inventory_adjustments) !== 0 && <Row label="Selisih/kerusakan stok" value={pnl.inventory_adjustments} minus />}
            <Row label="Depresiasi aset" value={pnl.depreciation} minus />
            <Row label={closed ? "Laba/rugi bersih" : "Laba/rugi sementara"} value={pnl.net_profit} strong />
          </div>
          {!closed && <Hint>Angka sementara: depresiasi bulan ini baru tercatat saat tutup buku, dan transaksi masih bisa bertambah.</Hint>}
        </Card>
      </div>

      <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card>
          <p className="text-sm text-ink-soft">Pesanan aktif</p>
          <p className="text-2xl font-bold num">{s.active_orders}</p>
          <ul className="mt-2 space-y-0.5 text-xs text-ink-soft">
            {Object.entries(s.orders_by_status).map(([k, v]) => <li key={k} className="flex justify-between"><span>{STATUS_LABEL[k] ?? k}</span><span className="num">{v}</span></li>)}
          </ul>
        </Card>
        <Card>
          <p className="text-sm text-ink-soft">Piutang pelanggan</p>
          <p className="text-2xl font-bold"><Money value={s.receivables} /></p>
          <Hint>Sisa tagihan pesanan terkonfirmasi yang belum dibayar.</Hint>
        </Card>
        <Card>
          <p className="text-sm text-ink-soft">Upah belum dibayar</p>
          <p className={`text-2xl font-bold ${s.unpaid_wages > 0 ? "text-warn" : ""}`}><Money value={s.unpaid_wages} /></p>
          <Hint>Kewajiban ke pekerja harian. Kas berkurang saat tombol Bayar Upah dikonfirmasi.</Hint>
        </Card>
        <Card>
          <p className="text-sm text-ink-soft">Komisi terutang</p>
          <p className="text-2xl font-bold"><Money value={s.unpaid_commissions} /></p>
          <Hint>Komisi marketing yang sudah memenuhi syarat tetapi belum dibayar.</Hint>
        </Card>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Card>
          <h2 className="font-semibold">Persediaan</h2>
          <p className="mt-1 text-2xl font-bold"><Money value={s.inventory_value} /></p>
          <Hint>Nilai stok dengan biaya rata-rata. Ini aset, bukan uang tunai.</Hint>
          {s.low_stock.length > 0 ? (
            <ul className="mt-3 space-y-1 text-sm">
              {s.low_stock.slice(0, 5).map((p) => (
                <li key={p.sku} className="flex justify-between gap-2"><span className="truncate">{p.name}</span><Badge tone="warn">{p.qty} / min {p.min} {p.unit}</Badge></li>
              ))}
            </ul>
          ) : <p className="mt-3 text-sm text-ink-soft">Tidak ada stok di bawah minimum.</p>}
        </Card>
        <Card>
          <h2 className="font-semibold">Aset & modal</h2>
          <Row label="Harga perolehan aset" value={s.assets_cost} />
          <Row label="Nilai buku aset" value={s.assets_book_value} hint="Harga perolehan dikurangi akumulasi depresiasi" />
          <Row label="Modal yang sudah disetor" value={s.capital_in} />
          <Row label="Modal awal sesuai perjanjian" value={s.initial_capital} />
          {s.capital_in < s.initial_capital && <Hint>Setoran modal yang tercatat belum sama dengan perjanjian. Catat transaksi &quot;Setoran modal investor&quot; saat dana diterima.</Hint>}
        </Card>
        <Card>
          <div className="flex items-baseline justify-between">
            <h2 className="font-semibold">Bagi hasil</h2>
            <Badge tone="warn">Simulasi</Badge>
          </div>
          {s.profit_simulation.is_loss || pnl.net_profit <= 0 ? (
            <p className="mt-2 text-sm text-ink-soft">Laba sementara bulan ini belum positif, jadi tidak ada yang dibagi. Kebijakan saat rugi mengikuti kesepakatan.</p>
          ) : (
            <div className="mt-1">
              <Row label={`Cadangan usaha (${s.profit_simulation.reserve_pct}%)`} value={s.profit_simulation.reserve} />
              <Row label="Investor" value={s.profit_simulation.investor} />
              <Row label="Pemilik" value={s.profit_simulation.owner} />
            </div>
          )}
          <Hint>Dihitung dari laba sementara. Pembagian resmi hanya setelah bulan ditutup.</Hint>
          {s.last_closed && (
            <p className="mt-3 rounded-lg bg-paper p-3 text-sm">
              Tutup buku terakhir {bulan(s.last_closed.period)}: laba <Money value={s.last_closed.net_profit} />, cadangan terkumpul <Money value={s.reserve_total} />.
            </p>
          )}
        </Card>
      </div>
    </>
  );
}

import Link from "next/link";
import { getSession } from "@/lib/auth";
import { bulan, periodFromParam, shiftMonth, tanggal } from "@/lib/format";
import { Badge, Card, Hint, Money, PageHeader, PeriodNav, btn } from "@/components/ui";
import { GROUP_LABEL, loadReports, pnlLines } from "./data";

export const metadata = { title: "Laporan" };

export default async function ReportsPage({ searchParams }: { searchParams: Promise<{ bulan?: string }> }) {
  const sp = await searchParams;
  const { supabase } = await getSession();
  const period = periodFromParam(sp.bulan);
  const { pnl, cashFlow, period: per, closed } = await loadReports(supabase, period.from, period.to);
  const inflow = cashFlow.lines.filter((l) => l.direction === "in");
  const outflow = cashFlow.lines.filter((l) => l.direction === "out");

  return (
    <>
      <PageHeader title="Laporan" subtitle="Laba-rugi menunjukkan hasil usaha; arus kas menunjukkan pergerakan uang. Keduanya berbeda."
        action={<Link href={`/laporan/csv?bulan=${period.ym}`} className={btn.secondary}>Unduh CSV</Link>} />
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <PeriodNav ym={period.ym} prev={shiftMonth(period.ym, -1)} next={shiftMonth(period.ym, 1)} isCurrent={period.isCurrent} basePath="/laporan" />
        {closed ? <Badge tone="good">Ditutup {per?.closed_at ? tanggal(per.closed_at) : ""} · terkunci</Badge> : <Badge tone="warn">Belum ditutup · angka sementara</Badge>}
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <h2 className="mb-2 font-semibold">Laba-rugi {bulan(period.from)}</h2>
          <table className="w-full text-sm">
            <tbody>
              {pnlLines(pnl).filter(([, v, k]) => k === "total" || Number(v) !== 0).map(([name, v, kind]) => (
                <tr key={name} className={kind === "total" ? "border-t border-line font-semibold" : ""}>
                  <td className={`py-1.5 ${kind === "minus" ? "pl-3 text-ink-soft" : ""}`}>{name}</td>
                  <td className="py-1.5 text-right"><Money value={kind === "minus" ? -v : v} signed={kind === "total"} /></td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="mt-3"><Hint>Omzet diakui dari pesanan yang mencapai status pengakuan (bukan dari DP). Upah diakui saat kerja, komisi saat penjualan diakui, aset lewat depresiasi.</Hint></div>
          {closed && per && (
            <div className="mt-3 rounded-lg bg-paper p-3 text-sm">
              <p className="font-semibold">Alokasi laba saat tutup buku</p>
              <div className="mt-1 flex justify-between"><span>Cadangan usaha</span><Money value={per.reserve_amount} /></div>
              <div className="flex justify-between"><span>Bagian investor</span><Money value={per.investor_amount} /></div>
              <div className="flex justify-between"><span>Bagian pemilik</span><Money value={per.owner_amount} /></div>
              <Hint>Alokasi bukan berarti sudah ditransfer. Pembayaran aktual dicatat terpisah.</Hint>
            </div>
          )}
        </Card>

        <Card>
          <h2 className="mb-2 font-semibold">Arus kas {bulan(period.from)}</h2>
          <table className="w-full text-sm">
            <tbody>
              <tr className="font-semibold"><td className="py-1.5">Saldo awal bulan</td><td className="text-right"><Money value={cashFlow.opening} /></td></tr>
              {inflow.map((l) => (
                <tr key={`in-${l.category}`}><td className="py-1 pl-3 text-ink-soft">{l.category} <span className="text-xs">({GROUP_LABEL[l.group] ?? l.group})</span></td><td className="text-right"><Money value={l.amount} signed /></td></tr>
              ))}
              {outflow.map((l) => (
                <tr key={`out-${l.category}`}><td className="py-1 pl-3 text-ink-soft">{l.category} <span className="text-xs">({GROUP_LABEL[l.group] ?? l.group})</span></td><td className="text-right"><Money value={-l.amount} signed /></td></tr>
              ))}
              {cashFlow.lines.length === 0 && <tr><td colSpan={2} className="py-2 text-ink-soft">Tidak ada pergerakan kas.</td></tr>}
              <tr className="border-t border-line font-semibold"><td className="py-1.5">Saldo akhir bulan</td><td className="text-right"><Money value={cashFlow.closing} /></td></tr>
            </tbody>
          </table>
          <div className="mt-3"><Hint>Transfer antar akun tidak ditampilkan karena tidak mengubah total kas.</Hint></div>
        </Card>
      </div>
    </>
  );
}

import { type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { periodFromParam } from "@/lib/format";
import { GROUP_LABEL, loadReports, pnlLines } from "../data";

const cell = (v: string | number) => {
  const s = String(v);
  return /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

// CSV memakai pemisah titik koma agar langsung terbaca rapi di Excel versi Indonesia.
export async function GET(request: NextRequest) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response("Silakan masuk dulu.", { status: 401 });
  const period = periodFromParam(request.nextUrl.searchParams.get("bulan") ?? undefined);
  const { pnl, cashFlow, closed } = await loadReports(supabase, period.from, period.to);

  const rows: (string | number)[][] = [
    ["Sayspack Management System"], ["Periode", period.ym, closed ? "Ditutup" : "Sementara"], [],
    ["LABA-RUGI", "Nominal (Rp)"], ...pnlLines(pnl).map(([n, v, k]) => [n, k === "minus" ? -v : v]), [],
    ["ARUS KAS", "Kelompok", "Nominal (Rp)"], ["Saldo awal", "", cashFlow.opening],
    ...cashFlow.lines.map((l) => [l.category, GROUP_LABEL[l.group] ?? l.group, l.direction === "in" ? l.amount : -l.amount]),
    ["Saldo akhir", "", cashFlow.closing],
  ];
  const body = "\uFEFF" + rows.map((r) => r.map(cell).join(";")).join("\r\n");
  return new Response(body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="sayspack-laporan-${period.ym}.csv"`,
    },
  });
}

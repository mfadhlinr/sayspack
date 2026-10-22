import type { SupabaseClient } from "@supabase/supabase-js";

export type Pnl = {
  revenue: number; cogs_materials: number; labor: number; gross_profit: number; commission: number; opex: number;
  opex_detail: { category: string; amount: number }[]; other_income: number; inventory_adjustments: number;
  depreciation: number; net_profit: number; orders_recognized: number;
};
export type CashFlow = { opening: number; closing: number; lines: { group: string; direction: "in" | "out"; category: string; amount: number }[] };

export async function loadReports(supabase: SupabaseClient, from: string, to: string) {
  const [pnl, cf, per] = await Promise.all([
    supabase.rpc("profit_and_loss", { p_from: from, p_to: to }),
    supabase.rpc("cash_flow", { p_from: from, p_to: to }),
    supabase.from("accounting_periods").select("status, net_profit, reserve_amount, investor_amount, owner_amount, closed_at, pnl").eq("period", from).maybeSingle(),
  ]);
  if (pnl.error) throw new Error(pnl.error.message);
  if (cf.error) throw new Error(cf.error.message);
  const closed = per.data?.status === "closed";
  // Periode tertutup: tampilkan angka snapshot saat ditutup (tidak berubah diam-diam).
  return { pnl: (closed && per.data?.pnl ? per.data.pnl : pnl.data) as Pnl, cashFlow: cf.data as CashFlow, period: per.data, closed };
}

export function pnlLines(p: Pnl): [string, number, "plus" | "minus" | "total"][] {
  return [
    ["Omzet penjualan", p.revenue, "plus"],
    ["HPP cup & bahan sablon", p.cogs_materials, "minus"],
    ["Upah produksi", p.labor, "minus"],
    ["Laba kotor", p.gross_profit, "total"],
    ["Komisi marketing", p.commission, "minus"],
    ...p.opex_detail.map((o) => [`Beban: ${o.category}`, o.amount, "minus"] as [string, number, "minus"]),
    ["Pendapatan lain", p.other_income, "plus"],
    ["Selisih/kerusakan stok", p.inventory_adjustments, "minus"],
    ["Depresiasi aset", p.depreciation, "minus"],
    ["Laba/rugi bersih", p.net_profit, "total"],
  ];
}

export const GROUP_LABEL: Record<string, string> = {
  penerimaan_pelanggan: "Penerimaan/refund pelanggan", modal: "Modal", saldo_awal: "Saldo awal", pendapatan_lain: "Pendapatan lain",
  beban_operasional: "Beban operasional", pembelian_persediaan: "Pembelian persediaan", pembelian_aset: "Pembelian aset",
  upah: "Upah", komisi: "Komisi", bagi_hasil: "Bagi hasil", pinjaman: "Pinjaman", lainnya_non_lr: "Lainnya",
};

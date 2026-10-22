import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import { todayJakarta } from "@/lib/format";
import { PageHeader } from "@/components/ui";
import { TransactionForm, type Category } from "./transaction-form";

export const metadata = { title: "Catat transaksi" };

// Kategori yang dicatat otomatis oleh modulnya (pesanan, upah, komisi, dst.) tidak ditampilkan di sini.
const MANUAL_SYSTEM = ["saldo_awal_in", "modal_investor", "modal_owner", "pinjaman_in", "pinjaman_out", "beli_aset"];

export default async function NewTransactionPage() {
  const { supabase, role } = await getSession();
  if (role !== "owner") redirect("/keuangan");
  const [{ data: accounts }, { data: cats }] = await Promise.all([
    supabase.from("cash_accounts").select("id, name").eq("is_active", true).order("name"),
    supabase.from("transaction_categories").select("id, code, name, direction, report_group, description").eq("is_active", true).order("name"),
  ]);
  const categories = ((cats ?? []) as (Category & { code: string | null })[])
    .filter((c) => !c.code || MANUAL_SYSTEM.includes(c.code));

  return (
    <>
      <PageHeader title="Catat transaksi" subtitle="Untuk uang masuk/keluar umum. Pembayaran pesanan, upah, dan komisi dicatat dari modul masing-masing agar tidak dobel." />
      <TransactionForm accounts={accounts ?? []} categories={categories} today={todayJakarta()} clientRef={crypto.randomUUID()} />
    </>
  );
}

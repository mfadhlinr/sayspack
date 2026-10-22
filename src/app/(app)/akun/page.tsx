import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import { tanggal, todayJakarta } from "@/lib/format";
import { Badge, Card, Flash, Money, PageHeader } from "@/components/ui";
import { NewAccountForm, ReconcileForm, TransferForm } from "./forms";
import { toggleAccount } from "./actions";

export const metadata = { title: "Akun kas" };

export default async function AccountsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const { supabase, role } = await getSession();
  if (role !== "owner") redirect("/");
  const [{ data: balances }, { data: recs }] = await Promise.all([
    supabase.from("v_account_balances").select("id, name, kind, account_info, is_active, balance").order("name"),
    supabase.from("reconciliations").select("id, as_of, statement_balance, system_balance, difference, notes, cash_accounts(name)").order("created_at", { ascending: false }).limit(10),
  ]);
  const accounts = balances ?? [];
  const active = accounts.filter((a) => a.is_active).map((a) => ({ id: a.id, name: a.name }));
  const today = todayJakarta();

  return (
    <>
      <PageHeader title="Akun kas & bank" subtitle="Saldo dihitung dari transaksi, tidak bisa diketik manual." />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <Card className="p-0 sm:p-0">
          <ul className="divide-y divide-line">
            {accounts.length === 0 && <li className="p-5 text-sm text-ink-soft">Belum ada akun. Tambahkan akun pertama di samping.</li>}
            {accounts.map((a) => (
              <li key={a.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <div className="min-w-0">
                  <p className="font-medium">{a.name} {!a.is_active && <Badge>Nonaktif</Badge>}</p>
                  <p className="text-xs text-ink-soft">{a.kind === "kas" ? "Kas tunai" : a.kind === "bank" ? "Bank" : "E-wallet"}{a.account_info ? ` · ${a.account_info}` : ""}</p>
                </div>
                <div className="text-right">
                  <Money value={a.balance} signed={Number(a.balance) < 0} className="font-semibold" />
                  <form action={toggleAccount}>
                    <input type="hidden" name="id" value={a.id} /><input type="hidden" name="active" value={String(a.is_active)} />
                    <button className="text-xs font-semibold text-ink-soft hover:text-ink">{a.is_active ? "Nonaktifkan" : "Aktifkan"}</button>
                  </form>
                </div>
              </li>
            ))}
          </ul>
        </Card>
        <Card><h2 className="mb-3 font-semibold">Tambah akun</h2><NewAccountForm /></Card>
      </div>

      {active.length >= 2 && (
        <Card className="mt-4"><h2 className="mb-3 font-semibold">Transfer antar akun</h2><TransferForm accounts={active} today={today} clientRef={crypto.randomUUID()} /></Card>
      )}

      {active.length > 0 && (
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <Card><h2 className="mb-3 font-semibold">Rekonsiliasi saldo</h2><ReconcileForm accounts={active} today={today} /></Card>
          <Card>
            <h2 className="mb-3 font-semibold">Riwayat rekonsiliasi</h2>
            {(recs ?? []).length === 0 ? <p className="text-sm text-ink-soft">Belum ada. Lakukan minimal setiap akhir bulan sebelum tutup buku.</p> : (
              <ul className="divide-y divide-line text-sm">
                {(recs ?? []).map((r) => {
                  const acc = r.cash_accounts as unknown as { name: string } | null;
                  return (
                    <li key={r.id} className="py-2">
                      <div className="flex justify-between"><span className="font-medium">{acc?.name}</span><span className="text-ink-soft">{tanggal(r.as_of)}</span></div>
                      <div className="flex flex-wrap justify-between gap-2 text-xs text-ink-soft">
                        <span>Bank/fisik <Money value={r.statement_balance} /> · Sistem <Money value={r.system_balance} /></span>
                        {Number(r.difference) === 0 ? <Badge tone="good">Cocok</Badge> : <Badge tone="bad">Selisih <Money value={r.difference} /></Badge>}
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>
        </div>
      )}
    </>
  );
}

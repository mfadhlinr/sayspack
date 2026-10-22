"use client";
import Link from "next/link";
import { useActionState, useMemo, useState } from "react";
import { createTransaction } from "../actions";
import { SubmitButton } from "@/components/submit-button";
import { Card, Hint, btn, input, label } from "@/components/ui";

export type Category = { id: string; name: string; direction: "in" | "out"; report_group: string; description: string | null };

const GROUP_HINT: Record<string, string> = {
  beban_operasional: "Masuk laporan laba-rugi sebagai beban operasional.",
  pendapatan_lain: "Masuk laporan laba-rugi sebagai pendapatan lain.",
  modal: "Modal usaha — menambah kas, bukan pendapatan atau laba.",
  saldo_awal: "Saldo saat mulai memakai sistem — bukan pendapatan.",
  pembelian_aset: "Aset dicatat terpisah di modul Aset; bebannya lewat depresiasi bulanan, bukan sekaligus.",
  pinjaman: "Pinjaman bukan pendapatan; pelunasan pokok bukan beban.",
};

function formatThousands(v: string) {
  const digits = v.replace(/\D/g, "").replace(/^0+(?=\d)/, "");
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

export function TransactionForm({ accounts, categories, today, clientRef }: {
  accounts: { id: string; name: string }[]; categories: Category[]; today: string; clientRef: string;
}) {
  const [state, action] = useActionState(createTransaction, undefined);
  const [direction, setDirection] = useState<"in" | "out">("out");
  const [categoryId, setCategoryId] = useState("");
  const [amount, setAmount] = useState("");
  const options = useMemo(() => categories.filter((c) => c.direction === direction), [categories, direction]);
  const chosen = categories.find((c) => c.id === categoryId);
  const fe = state?.fieldErrors ?? {};
  const err = (k: string) => fe[k] && <p className="mt-1 text-xs text-minus">{fe[k]}</p>;

  if (accounts.length === 0) {
    return (
      <Card>
        <p className="font-semibold">Belum ada akun kas atau bank</p>
        <p className="mt-1 text-sm text-ink-soft">Buat minimal satu akun (misalnya Kas Tunai) sebelum mencatat transaksi.</p>
        <Link href="/akun" className={`${btn.primary} mt-4`}>Tambah akun</Link>
      </Card>
    );
  }

  return (
    <form action={action} className="max-w-2xl space-y-4" noValidate>
      <input type="hidden" name="client_ref" value={clientRef} />
      <input type="hidden" name="direction" value={direction} />
      <Card className="space-y-4">
        <fieldset>
          <legend className={label}>Jenis transaksi</legend>
          <div className="grid grid-cols-2 gap-2">
            {(["in", "out"] as const).map((d) => (
              <button key={d} type="button" onClick={() => { setDirection(d); setCategoryId(""); }} aria-pressed={direction === d}
                className={`rounded-lg border px-3 py-2.5 text-sm font-semibold ${direction === d ? (d === "in" ? "border-plus bg-green-50 text-plus" : "border-minus bg-red-50 text-minus") : "border-line bg-white text-ink-soft"}`}>
                {d === "in" ? "Uang masuk" : "Uang keluar"}
              </button>
            ))}
          </div>
        </fieldset>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="date" className={label}>Tanggal transaksi</label>
            <input id="date" name="date" type="date" defaultValue={today} max={today} required className={input} />
            {err("date")}
          </div>
          <div>
            <label htmlFor="amount" className={label}>Nominal (Rp)</label>
            <input id="amount" name="amount" inputMode="numeric" autoComplete="off" required placeholder="0" value={amount}
              onChange={(e) => setAmount(formatThousands(e.target.value))} className={`${input} num text-right font-semibold`} />
            {err("amount")}
          </div>
        </div>

        <div>
          <label htmlFor="category" className={label}>Kategori</label>
          <select id="category" name="category" required value={categoryId} onChange={(e) => setCategoryId(e.target.value)} className={input}>
            <option value="">Pilih kategori…</option>
            {options.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          {err("category")}
          {chosen && <div className="mt-1"><Hint>{chosen.description ?? GROUP_HINT[chosen.report_group] ?? ""}</Hint></div>}
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="account" className={label}>{direction === "in" ? "Masuk ke akun" : "Keluar dari akun"}</label>
            <select id="account" name="account" required defaultValue="" className={input}>
              <option value="" disabled>Pilih akun…</option>
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select>
            {err("account")}
          </div>
          <div>
            <label htmlFor="method" className={label}>Metode</label>
            <select id="method" name="method" defaultValue="transfer" className={input}>
              <option value="transfer">Transfer</option><option value="tunai">Tunai</option>
            </select>
          </div>
        </div>

        <div>
          <label htmlFor="description" className={label}>Keterangan</label>
          <input id="description" name="description" required maxLength={300} placeholder="Contoh: Token listrik workshop" className={input} />
          {err("description")}
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="reference" className={label}>No. referensi <span className="font-normal text-ink-soft">(opsional)</span></label>
            <input id="reference" name="reference" maxLength={100} placeholder="No. nota / bukti transfer" className={input} />
          </div>
          <div>
            <label htmlFor="due_date" className={label}>Jatuh tempo <span className="font-normal text-ink-soft">(opsional)</span></label>
            <input id="due_date" name="due_date" type="date" className={input} />
          </div>
        </div>

        <div>
          <label htmlFor="proof" className={label}>Bukti transaksi <span className="font-normal text-ink-soft">(foto/PDF, maks 5 MB)</span></label>
          <input id="proof" name="proof" type="file" accept="image/jpeg,image/png,image/webp,application/pdf"
            className="block w-full text-sm file:mr-3 file:rounded-lg file:border-0 file:bg-paper file:px-3 file:py-2 file:font-semibold" />
          <Hint>Bukti dibutuhkan saat tutup buku. Boleh menyusul, tetapi transaksi akan ditandai “Belum ada bukti”.</Hint>
        </div>
      </Card>

      {state?.error && <p role="alert" className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-minus">{state.error}</p>}
      <div className="flex gap-2">
        <SubmitButton className={btn.primary}>Simpan transaksi</SubmitButton>
        <Link href="/keuangan" className={btn.secondary}>Batal</Link>
      </div>
    </form>
  );
}

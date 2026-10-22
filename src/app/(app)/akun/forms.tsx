"use client";
import { useActionState, useState } from "react";
import { createAccount, reconcile, transfer, type FormState } from "./actions";
import { SubmitButton } from "@/components/submit-button";
import { Hint, btn, input, label } from "@/components/ui";

type Acc = { id: string; name: string };
const Err = ({ s }: { s: FormState }) => (s?.error ? <p role="alert" className="text-sm text-minus">{s.error}</p> : null);

function MoneyInput({ name, id, allowNegative = false }: { name: string; id: string; allowNegative?: boolean }) {
  const [v, setV] = useState("");
  return (
    <input id={id} name={name} inputMode="numeric" required value={v} placeholder="0" className={`${input} num text-right`}
      onChange={(e) => {
        const neg = allowNegative && e.target.value.trim().startsWith("-");
        const d = e.target.value.replace(/\D/g, "").replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
        setV((neg ? "-" : "") + d);
      }} />
  );
}

export function NewAccountForm() {
  const [s, a] = useActionState(createAccount, undefined);
  return (
    <form action={a} className="space-y-3">
      <div><label htmlFor="acc-name" className={label}>Nama akun</label><input id="acc-name" name="name" required placeholder="Contoh: Bank BCA Usaha" className={input} /></div>
      <div className="grid grid-cols-2 gap-3">
        <div><label htmlFor="acc-kind" className={label}>Jenis</label>
          <select id="acc-kind" name="kind" className={input}><option value="kas">Kas tunai</option><option value="bank">Bank</option><option value="ewallet">E-wallet</option></select></div>
        <div><label htmlFor="acc-info" className={label}>No. rekening <span className="font-normal text-ink-soft">(opsional)</span></label><input id="acc-info" name="info" className={input} /></div>
      </div>
      <Err s={s} />
      <SubmitButton className={btn.primary}>Tambah akun</SubmitButton>
    </form>
  );
}

export function TransferForm({ accounts, today, clientRef }: { accounts: Acc[]; today: string; clientRef: string }) {
  const [s, a] = useActionState(transfer, undefined);
  return (
    <form action={a} className="space-y-3">
      <input type="hidden" name="client_ref" value={clientRef} />
      <div className="grid grid-cols-2 gap-3">
        <div><label htmlFor="tf-from" className={label}>Dari</label>
          <select id="tf-from" name="from" required defaultValue="" className={input}><option value="" disabled>Pilih…</option>{accounts.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div>
        <div><label htmlFor="tf-to" className={label}>Ke</label>
          <select id="tf-to" name="to" required defaultValue="" className={input}><option value="" disabled>Pilih…</option>{accounts.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div><label htmlFor="tf-date" className={label}>Tanggal</label><input id="tf-date" name="date" type="date" defaultValue={today} max={today} className={input} /></div>
        <div><label htmlFor="tf-amount" className={label}>Nominal (Rp)</label><MoneyInput id="tf-amount" name="amount" /></div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div><label htmlFor="tf-method" className={label}>Metode</label>
          <select id="tf-method" name="method" className={input}><option value="transfer">Transfer</option><option value="tunai">Tunai</option></select></div>
        <div><label htmlFor="tf-note" className={label}>Catatan</label><input id="tf-note" name="note" placeholder="Ambil kas kecil" className={input} /></div>
      </div>
      <Err s={s} />
      <SubmitButton className={btn.primary}>Catat transfer</SubmitButton>
    </form>
  );
}

export function ReconcileForm({ accounts, today }: { accounts: Acc[]; today: string }) {
  const [s, a] = useActionState(reconcile, undefined);
  return (
    <form action={a} className="space-y-3">
      <Hint>Masukkan saldo menurut rekening koran/mutasi bank, atau hasil hitung uang fisik untuk kas tunai. Sistem membandingkannya dengan saldo tercatat.</Hint>
      <div className="grid grid-cols-2 gap-3">
        <div><label htmlFor="rc-acc" className={label}>Akun</label>
          <select id="rc-acc" name="account" required defaultValue="" className={input}><option value="" disabled>Pilih…</option>{accounts.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div>
        <div><label htmlFor="rc-date" className={label}>Per tanggal</label><input id="rc-date" name="as_of" type="date" defaultValue={today} max={today} className={input} /></div>
      </div>
      <div><label htmlFor="rc-bal" className={label}>Saldo menurut bank / hitung fisik (Rp)</label><MoneyInput id="rc-bal" name="statement" allowNegative /></div>
      <div><label htmlFor="rc-notes" className={label}>Catatan</label><input id="rc-notes" name="notes" className={input} /></div>
      <Err s={s} />
      <SubmitButton className={btn.primary}>Simpan rekonsiliasi</SubmitButton>
    </form>
  );
}

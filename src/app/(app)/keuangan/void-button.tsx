"use client";
import { useActionState, useEffect, useRef } from "react";
import { voidTransaction } from "./actions";
import { SubmitButton } from "@/components/submit-button";
import { btn, input, label } from "@/components/ui";

export function VoidButton({ id, trxNo, description }: { id: string; trxNo: string; description: string }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [state, action] = useActionState(voidTransaction, undefined);
  useEffect(() => { if (state && !state.error) ref.current?.close(); }, [state]);

  return (
    <>
      <button type="button" onClick={() => ref.current?.showModal()} className="text-xs font-semibold text-minus hover:underline">Batalkan</button>
      <dialog ref={ref} className="m-auto w-[min(28rem,calc(100vw-2rem))] rounded-xl p-0 backdrop:bg-ink/40">
        <form action={action} className="space-y-4 p-5">
          <h2 className="text-lg font-bold">Batalkan {trxNo}?</h2>
          <p className="text-sm text-ink-soft">“{description}” akan ditandai batal dan tidak lagi dihitung di saldo. Datanya tetap tersimpan sebagai jejak. Jika ada yang salah, catat ulang transaksi yang benar.</p>
          <input type="hidden" name="id" value={id} />
          <div>
            <label htmlFor={`reason-${id}`} className={label}>Alasan pembatalan</label>
            <input id={`reason-${id}`} name="reason" required minLength={5} className={input} placeholder="Contoh: nominal salah ketik" />
          </div>
          {state?.error && <p role="alert" className="text-sm text-minus">{state.error}</p>}
          <div className="flex justify-end gap-2">
            <button type="button" onClick={() => ref.current?.close()} className={btn.secondary}>Kembali</button>
            <SubmitButton className={btn.danger} pendingText="Membatalkan…">Ya, batalkan</SubmitButton>
          </div>
        </form>
      </dialog>
    </>
  );
}

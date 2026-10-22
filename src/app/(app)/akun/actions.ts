"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireOwner } from "@/lib/auth";
import { dbError, parseRupiahInput } from "@/lib/format";

export type FormState = { error?: string; ok?: string } | undefined;
const done = (msg: string) => { revalidatePath("/", "layout"); redirect(`/akun?ok=${encodeURIComponent(msg)}`); };

export async function createAccount(_p: FormState, fd: FormData): Promise<FormState> {
  const { supabase } = await requireOwner();
  const v = z.object({
    name: z.string().trim().min(2, "Nama akun minimal 2 karakter.").max(60),
    kind: z.enum(["kas", "bank", "ewallet"]),
    info: z.string().trim().max(120).optional(),
  }).safeParse({ name: fd.get("name"), kind: fd.get("kind"), info: fd.get("info") || undefined });
  if (!v.success) return { error: v.error.issues[0].message };
  const { error } = await supabase.from("cash_accounts").insert({ name: v.data.name, kind: v.data.kind, account_info: v.data.info ?? null });
  if (error) return { error: error.code === "23505" ? "Nama akun sudah dipakai." : dbError(error) };
  done(`Akun ${v.data.name} dibuat. Catat saldo awalnya lewat menu Transaksi (kategori Saldo awal).`);
}

export async function transfer(_p: FormState, fd: FormData): Promise<FormState> {
  const { supabase } = await requireOwner();
  const v = z.object({
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Tanggal wajib diisi."),
    from: z.string().uuid("Pilih akun asal."), to: z.string().uuid("Pilih akun tujuan."),
    amount: z.number().positive("Nominal harus lebih dari 0."),
    method: z.enum(["tunai", "transfer"]), note: z.string().trim().max(200).optional(), clientRef: z.string().uuid(),
  }).safeParse({ date: fd.get("date"), from: fd.get("from"), to: fd.get("to"), amount: parseRupiahInput(fd.get("amount")),
    method: fd.get("method"), note: fd.get("note") || undefined, clientRef: fd.get("client_ref") });
  if (!v.success) return { error: v.error.issues[0].message };
  if (v.data.from === v.data.to) return { error: "Akun asal dan tujuan harus berbeda." };
  const { error } = await supabase.rpc("transfer_between_accounts", {
    p_date: v.data.date, p_from: v.data.from, p_to: v.data.to, p_amount: v.data.amount, p_method: v.data.method,
    p_note: v.data.note ?? null, p_client_ref: v.data.clientRef });
  if (error) return { error: dbError(error) };
  done("Transfer antar akun tercatat. Total kas tidak berubah.");
}

export async function reconcile(_p: FormState, fd: FormData): Promise<FormState> {
  const { supabase } = await requireOwner();
  const v = z.object({
    account: z.string().uuid("Pilih akun."), asOf: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Tanggal wajib diisi."),
    statement: z.number({ message: "Saldo tidak valid." }), notes: z.string().trim().max(300).optional(),
  }).safeParse({ account: fd.get("account"), asOf: fd.get("as_of"), statement: parseRupiahInput(fd.get("statement")), notes: fd.get("notes") || undefined });
  if (!v.success) return { error: v.error.issues[0].message };
  const { error } = await supabase.rpc("record_reconciliation", {
    p_account: v.data.account, p_as_of: v.data.asOf, p_statement: v.data.statement, p_notes: v.data.notes ?? null });
  if (error) return { error: dbError(error) };
  done("Rekonsiliasi tersimpan.");
}

export async function toggleAccount(fd: FormData) {
  const { supabase } = await requireOwner();
  const id = String(fd.get("id")); const active = fd.get("active") === "true";
  const { error } = await supabase.from("cash_accounts").update({ is_active: !active }).eq("id", id);
  if (error) redirect(`/akun?err=${encodeURIComponent(dbError(error))}`);
  done(active ? "Akun dinonaktifkan. Riwayat transaksinya tetap ada." : "Akun diaktifkan kembali.");
}

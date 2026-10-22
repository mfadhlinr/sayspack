"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireOwner } from "@/lib/auth";
import { dbError, parseRupiahInput } from "@/lib/format";
import { uploadProof } from "@/lib/upload";

export type FormState = { error?: string; fieldErrors?: Record<string, string> } | undefined;

const txSchema = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Tanggal wajib diisi."),
  direction: z.enum(["in", "out"], { message: "Pilih jenis transaksi." }),
  account: z.string().uuid("Pilih akun kas/bank."),
  category: z.string().uuid("Pilih kategori."),
  amount: z.number({ message: "Nominal tidak valid." }).positive("Nominal harus lebih dari 0.").max(1e13, "Nominal terlalu besar."),
  method: z.enum(["tunai", "transfer"], { message: "Pilih metode pembayaran." }),
  description: z.string().trim().min(3, "Keterangan minimal 3 karakter.").max(300),
  reference: z.string().trim().max(100).optional(),
  dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  clientRef: z.string().uuid(),
});

const opt = (v: FormDataEntryValue | null) => (typeof v === "string" && v.trim() !== "" ? v.trim() : undefined);

export async function createTransaction(_prev: FormState, fd: FormData): Promise<FormState> {
  const { supabase } = await requireOwner();
  const parsed = txSchema.safeParse({
    date: fd.get("date"), direction: fd.get("direction"), account: fd.get("account"), category: fd.get("category"),
    amount: parseRupiahInput(fd.get("amount")), method: fd.get("method"), description: fd.get("description"),
    reference: opt(fd.get("reference")), dueDate: opt(fd.get("due_date")), clientRef: fd.get("client_ref"),
  });
  if (!parsed.success) {
    const fieldErrors: Record<string, string> = {};
    parsed.error.issues.forEach((i) => { fieldErrors[String(i.path[0])] ??= i.message; });
    return { error: "Periksa kembali isian yang ditandai.", fieldErrors };
  }
  const v = parsed.data;
  const up = await uploadProof(supabase, fd.get("proof"), `transaksi/${v.date.slice(0, 7)}`);
  if ("error" in up) return { error: up.error };

  const { error } = await supabase.rpc("record_cash_transaction", {
    p_date: v.date, p_direction: v.direction, p_account: v.account, p_category: v.category, p_amount: v.amount,
    p_method: v.method, p_description: v.description, p_reference: v.reference ?? null, p_due_date: v.dueDate ?? null,
    p_customer: null, p_supplier: null, p_attachment: up.path, p_client_ref: v.clientRef,
  });
  if (error) {
    if (up.path) await supabase.storage.from("bukti").remove([up.path]);
    return { error: dbError(error) };
  }
  revalidatePath("/", "layout");
  redirect(`/keuangan?bulan=${v.date.slice(0, 7)}&ok=${encodeURIComponent("Transaksi tersimpan.")}`);
}

export async function voidTransaction(_prev: FormState, fd: FormData): Promise<FormState> {
  const { supabase } = await requireOwner();
  const id = String(fd.get("id") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (reason.length < 5) return { error: "Tulis alasan pembatalan minimal 5 karakter." };
  const { error } = await supabase.rpc("void_cash_transaction", { p_id: id, p_reason: reason });
  if (error) return { error: dbError(error) };
  revalidatePath("/", "layout");
  return {};
}

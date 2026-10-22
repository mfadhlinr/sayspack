"use server";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const schema = z.object({
  email: z.string().trim().email("Format email tidak valid."),
  password: z.string().min(6, "Kata sandi minimal 6 karakter."),
});

export async function signIn(_prev: { error?: string; email?: string } | undefined, formData: FormData) {
  const email = String(formData.get("email") ?? "");
  const parsed = schema.safeParse({ email: formData.get("email"), password: formData.get("password") });
  if (!parsed.success) return { error: parsed.error.issues[0].message, email };
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  if (error) {
    if (error.message === "Invalid login credentials") return { error: "Email atau kata sandi salah.", email };
    if (/fetch failed|network/i.test(error.message)) return { error: "Tidak bisa terhubung ke server. Periksa koneksi internet atau konfigurasi Supabase.", email };
    return { error: error.message, email };
  }
  redirect("/");
}

import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";

export type Role = "owner" | "investor" | "staff" | "pending";

export async function getSession() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/masuk");
  const { data: profile } = await supabase.from("profiles").select("full_name, role").eq("id", user.id).single();
  return { supabase, user, role: (profile?.role ?? "pending") as Role, name: profile?.full_name ?? user.email ?? "" };
}

/** Untuk Server Action: pastikan owner. Database tetap memeriksa ulang lewat RLS/RPC. */
export async function requireOwner() {
  const s = await getSession();
  if (s.role !== "owner") throw new Error("Hanya owner yang boleh melakukan aksi ini.");
  return s;
}

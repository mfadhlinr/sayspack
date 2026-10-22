import type { SupabaseClient } from "@supabase/supabase-js";

const ALLOWED = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX_BYTES = 5 * 1024 * 1024;

/** Unggah bukti ke bucket privat "bukti". Mengembalikan path, null jika tidak ada file. */
export async function uploadProof(supabase: SupabaseClient, file: FormDataEntryValue | null, folder: string) {
  if (!(file instanceof File) || file.size === 0) return { path: null as string | null };
  if (!ALLOWED.includes(file.type)) return { error: "Bukti harus berupa foto (JPG/PNG/WEBP) atau PDF." };
  if (file.size > MAX_BYTES) return { error: "Ukuran bukti maksimal 5 MB." };
  const safe = file.name.toLowerCase().replace(/[^a-z0-9.]+/g, "-").slice(-60);
  const path = `${folder}/${crypto.randomUUID()}-${safe}`;
  const { error } = await supabase.storage.from("bukti").upload(path, file, { contentType: file.type, upsert: false });
  if (error) return { error: `Bukti gagal diunggah: ${error.message}` };
  return { path };
}

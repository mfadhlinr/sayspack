import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Membuka bukti transaksi lewat signed URL berumur pendek. Akses tetap dicek oleh kebijakan Storage.
export async function GET(request: NextRequest) {
  const path = request.nextUrl.searchParams.get("path");
  if (!path) return NextResponse.json({ error: "Path bukti kosong." }, { status: 400 });
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("bukti").createSignedUrl(path, 60);
  if (error || !data) return NextResponse.json({ error: "Bukti tidak ditemukan atau Anda tidak punya akses." }, { status: 404 });
  return NextResponse.redirect(data.signedUrl);
}

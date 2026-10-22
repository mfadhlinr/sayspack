import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

export function supabaseEnv() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY belum diisi. Lihat .env.example.");
  }
  return { url, key };
}

/** Client Supabase dengan sesi user (RLS berlaku). Dipakai di Server Component & Server Action. */
export async function createClient() {
  const { url, key } = supabaseEnv();
  const cookieStore = await cookies();
  return createServerClient(url, key, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // Dipanggil dari Server Component: penyegaran cookie ditangani middleware.
        }
      },
    },
  });
}

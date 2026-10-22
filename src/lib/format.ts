const rupiahFmt = new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 });
const numFmt = new Intl.NumberFormat("id-ID", { maximumFractionDigits: 2 });
const dateFmt = new Intl.DateTimeFormat("id-ID", { day: "numeric", month: "short", year: "numeric", timeZone: "Asia/Jakarta" });
const monthFmt = new Intl.DateTimeFormat("id-ID", { month: "long", year: "numeric", timeZone: "Asia/Jakarta" });

export const rupiah = (v: number | string | null | undefined) => rupiahFmt.format(Number(v ?? 0));
export const angka = (v: number | string | null | undefined) => numFmt.format(Number(v ?? 0));
/** Tanggal "YYYY-MM-DD" dari database → "5 Sep 2026". */
export const tanggal = (v: string | null | undefined) => (v ? dateFmt.format(new Date(`${v.slice(0, 10)}T00:00:00+07:00`)) : "–");
export const bulan = (v: string) => monthFmt.format(new Date(`${v.slice(0, 10)}T00:00:00+07:00`));

/** Tanggal hari ini di zona Asia/Jakarta, format YYYY-MM-DD. */
export function todayJakarta() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jakarta" }).format(new Date());
}

/** Rentang periode dari query ?bulan=YYYY-MM (default bulan ini). */
export function periodFromParam(param?: string) {
  const today = todayJakarta();
  const ym = param && /^\d{4}-\d{2}$/.test(param) ? param : today.slice(0, 7);
  const [y, m] = ym.split("-").map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { ym, from: `${ym}-01`, to: `${ym}-${String(last).padStart(2, "0")}`, isCurrent: ym === today.slice(0, 7) };
}

export function shiftMonth(ym: string, delta: number) {
  const [y, m] = ym.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

/** Ubah input "1.250.000" / "1250000" jadi angka. */
export function parseRupiahInput(v: FormDataEntryValue | null) {
  const raw = String(v ?? "").trim();
  if (!/\d/.test(raw)) return NaN;
  const n = Number(raw.replace(/[^\d,]/g, "").replace(",", "."));
  return Number.isFinite(n) ? (raw.startsWith("-") ? -n : n) : NaN;
}

/** Pesan error dari Postgres/Supabase yang aman ditampilkan. */
export function dbError(e: { message?: string; code?: string } | null | undefined) {
  if (!e) return "Terjadi kesalahan.";
  if (e.code === "23505") return "Data yang sama sudah ada.";
  if (e.code === "42501") return e.message?.includes("row-level") ? "Anda tidak punya izin untuk aksi ini." : e.message ?? "Tidak punya izin.";
  return e.message ?? "Terjadi kesalahan.";
}

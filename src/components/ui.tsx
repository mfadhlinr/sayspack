import Link from "next/link";
import { rupiah } from "@/lib/format";

export function PageHeader({ title, subtitle, action }: { title: string; subtitle?: string; action?: React.ReactNode }) {
  return (
    <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-ink-soft">{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}

export function Card({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <section className={`rounded-xl border border-line bg-white p-4 sm:p-5 ${className}`}>{children}</section>;
}

export function Money({ value, signed = false, className = "" }: { value: number | string | null | undefined; signed?: boolean; className?: string }) {
  const n = Number(value ?? 0);
  const color = signed ? (n < 0 ? "text-minus" : n > 0 ? "text-plus" : "") : "";
  return <span className={`num whitespace-nowrap ${color} ${className}`}>{rupiah(n)}</span>;
}

export function Badge({ tone = "neutral", children }: { tone?: "neutral" | "good" | "bad" | "warn" | "info"; children: React.ReactNode }) {
  const tones = {
    neutral: "bg-paper text-ink-soft border-line",
    good: "bg-green-50 text-plus border-green-200",
    bad: "bg-red-50 text-minus border-red-200",
    warn: "bg-warn-soft text-warn border-amber-200",
    info: "bg-teal-soft text-teal border-teal/20",
  } as const;
  return <span className={`inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium ${tones[tone]}`}>{children}</span>;
}

export function EmptyState({ title, body, action }: { title: string; body?: string; action?: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-dashed border-line bg-white px-6 py-10 text-center">
      <p className="font-semibold">{title}</p>
      {body && <p className="mx-auto mt-1 max-w-md text-sm text-ink-soft">{body}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function Flash({ ok, err }: { ok?: string; err?: string }) {
  if (!ok && !err) return null;
  return (
    <div role="status" className={`mb-4 rounded-lg border px-4 py-3 text-sm ${err ? "border-red-200 bg-red-50 text-minus" : "border-green-200 bg-green-50 text-plus"}`}>
      {err ?? ok}
    </div>
  );
}

export function Hint({ children }: { children: React.ReactNode }) {
  return <p className="text-xs leading-relaxed text-ink-soft">{children}</p>;
}

export const btn = {
  primary: "inline-flex items-center justify-center gap-2 rounded-lg bg-ink px-4 py-2.5 text-sm font-semibold text-white hover:bg-ink/90 disabled:opacity-60",
  secondary: "inline-flex items-center justify-center gap-2 rounded-lg border border-line bg-white px-4 py-2.5 text-sm font-semibold text-ink hover:bg-paper disabled:opacity-60",
  danger: "inline-flex items-center justify-center gap-2 rounded-lg bg-minus px-4 py-2.5 text-sm font-semibold text-white hover:bg-minus/90 disabled:opacity-60",
  link: "text-sm font-semibold text-teal hover:underline",
};
export const input = "w-full rounded-lg border border-line bg-white px-3 py-2.5 text-sm placeholder:text-ink-soft/60 focus:border-teal focus:outline-none";
export const label = "mb-1 block text-sm font-medium";

export function PeriodNav({ ym, prev, next, isCurrent, basePath, extra = "" }: { ym: string; prev: string; next: string; isCurrent: boolean; basePath: string; extra?: string }) {
  const [y, m] = ym.split("-").map(Number);
  const name = new Intl.DateTimeFormat("id-ID", { month: "long", year: "numeric" }).format(new Date(y, m - 1, 1));
  return (
    <nav aria-label="Pilih periode" className="inline-flex items-center rounded-lg border border-line bg-white text-sm">
      <Link href={`${basePath}?bulan=${prev}${extra}`} className="px-3 py-2 hover:bg-paper" aria-label="Bulan sebelumnya">‹</Link>
      <span className="min-w-36 border-x border-line px-3 py-2 text-center font-semibold">{name}</span>
      {isCurrent ? (
        <span className="px-3 py-2 text-ink-soft/40" aria-hidden>›</span>
      ) : (
        <Link href={`${basePath}?bulan=${next}${extra}`} className="px-3 py-2 hover:bg-paper" aria-label="Bulan berikutnya">›</Link>
      )}
    </nav>
  );
}

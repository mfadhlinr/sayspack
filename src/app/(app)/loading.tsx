export default function Loading() {
  return (
    <div aria-busy="true" aria-live="polite" className="space-y-4">
      <div className="h-8 w-48 animate-pulse rounded bg-line" />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {[0, 1, 2].map((i) => <div key={i} className="h-28 animate-pulse rounded-xl bg-white" />)}
      </div>
      <span className="sr-only">Memuat data…</span>
    </div>
  );
}

"use client";

export default function ErrorPage({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="rounded-xl border border-red-200 bg-red-50 p-6">
      <h2 className="font-bold text-minus">Data gagal dimuat</h2>
      <p className="mt-1 text-sm text-minus/90">{error.message || "Periksa koneksi internet lalu coba lagi."}</p>
      <button onClick={reset} className="mt-4 rounded-lg bg-ink px-4 py-2 text-sm font-semibold text-white">Coba lagi</button>
    </div>
  );
}

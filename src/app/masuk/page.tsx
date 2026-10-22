import { LoginForm } from "./login-form";

export const metadata = { title: "Masuk" };

export default function LoginPage() {
  return (
    <main className="grid min-h-dvh place-items-center bg-ink px-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 text-white">
          <p className="text-3xl font-bold tracking-tight">Sayspack</p>
          <p className="text-sm text-white/70">Management System</p>
        </div>
        <div className="rounded-xl bg-white p-6">
          <h1 className="mb-4 text-lg font-bold">Masuk ke akun Anda</h1>
          <LoginForm />
        </div>
        <p className="mt-4 text-xs text-white/60">Akun dibuat oleh owner. Belum punya akses? Hubungi pemilik usaha.</p>
      </div>
    </main>
  );
}

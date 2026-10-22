import { getSession } from "@/lib/auth";
import { BottomNav, SideNav, type NavItem } from "@/components/nav";

const OWNER_NAV: NavItem[] = [
  { href: "/", label: "Dashboard" },
  { href: "/keuangan", label: "Transaksi" },
  { href: "/akun", label: "Akun kas" },
  { href: "/laporan", label: "Laporan" },
];
const INVESTOR_NAV: NavItem[] = [
  { href: "/", label: "Dashboard" },
  { href: "/laporan", label: "Laporan" },
];

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { role, name } = await getSession();

  if (role === "pending" || role === "staff") {
    return (
      <main className="grid min-h-dvh place-items-center px-4">
        <div className="max-w-sm text-center">
          <h1 className="text-xl font-bold">Akun menunggu akses</h1>
          <p className="mt-2 text-sm text-ink-soft">Akun {name} sudah terdaftar, tetapi owner belum memberi peran. Hubungi pemilik usaha.</p>
          <form action="/keluar" method="post" className="mt-4"><button className="text-sm font-semibold text-teal">Keluar</button></form>
        </div>
      </main>
    );
  }

  const nav = role === "owner" ? OWNER_NAV : INVESTOR_NAV;
  return (
    <div className="lg:grid lg:grid-cols-[15rem_1fr]">
      <aside className="sticky top-0 hidden h-dvh flex-col justify-between bg-ink p-4 lg:flex">
        <div>
          <p className="px-3 pb-6 pt-2 text-lg font-bold text-white">Sayspack</p>
          <SideNav items={nav} />
        </div>
        <div className="border-t border-white/10 px-3 pt-4 text-sm text-white/70">
          <p className="truncate font-medium text-white">{name}</p>
          <p className="text-xs">{role === "owner" ? "Owner" : "Investor · baca saja"}</p>
          <form action="/keluar" method="post"><button className="mt-2 text-xs font-semibold text-white/80 hover:text-white">Keluar</button></form>
        </div>
      </aside>
      <div className="min-w-0">
        <header className="sticky top-0 z-10 flex items-center justify-between border-b border-line bg-white/95 px-4 py-3 backdrop-blur lg:hidden">
          <span className="font-bold">Sayspack</span>
          <form action="/keluar" method="post"><button className="text-sm font-semibold text-ink-soft">Keluar</button></form>
        </header>
        <main className="mx-auto max-w-6xl px-4 pb-28 pt-5 sm:px-6 lg:pb-10 lg:pt-8">{children}</main>
      </div>
      <BottomNav items={nav} />
    </div>
  );
}

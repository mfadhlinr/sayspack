"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

export type NavItem = { href: string; label: string };

function isActive(pathname: string, href: string) {
  return href === "/" ? pathname === "/" : pathname.startsWith(href);
}

export function SideNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Menu utama" className="flex flex-col gap-1">
      {items.map((it) => (
        <Link key={it.href} href={it.href} aria-current={isActive(pathname, it.href) ? "page" : undefined}
          className={`rounded-lg px-3 py-2 text-sm font-medium ${isActive(pathname, it.href) ? "bg-white/12 text-white" : "text-white/70 hover:bg-white/8 hover:text-white"}`}>
          {it.label}
        </Link>
      ))}
    </nav>
  );
}

export function BottomNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Menu utama" className="fixed inset-x-0 bottom-0 z-20 grid border-t border-line bg-white pb-[env(safe-area-inset-bottom)] lg:hidden"
      style={{ gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` }}>
      {items.map((it) => (
        <Link key={it.href} href={it.href} aria-current={isActive(pathname, it.href) ? "page" : undefined}
          className={`px-1 py-3 text-center text-xs font-semibold ${isActive(pathname, it.href) ? "text-teal" : "text-ink-soft"}`}>
          {it.label}
        </Link>
      ))}
    </nav>
  );
}

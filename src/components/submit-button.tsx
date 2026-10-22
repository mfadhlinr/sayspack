"use client";
import { useFormStatus } from "react-dom";

export function SubmitButton({ children, pendingText = "Menyimpan…", className }: { children: React.ReactNode; pendingText?: string; className: string }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending} aria-disabled={pending} className={className}>
      {pending ? pendingText : children}
    </button>
  );
}

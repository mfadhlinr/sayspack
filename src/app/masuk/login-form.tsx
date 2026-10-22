"use client";
import { useActionState } from "react";
import { signIn } from "./actions";
import { SubmitButton } from "@/components/submit-button";
import { btn, input, label } from "@/components/ui";

export function LoginForm() {
  const [state, action] = useActionState(signIn, undefined);
  return (
    <form action={action} className="space-y-4">
      <div>
        <label htmlFor="email" className={label}>Email</label>
        <input id="email" name="email" type="email" autoComplete="email" required defaultValue={state?.email} key={state?.email} className={input} />
      </div>
      <div>
        <label htmlFor="password" className={label}>Kata sandi</label>
        <input id="password" name="password" type="password" autoComplete="current-password" required className={input} />
      </div>
      {state?.error && <p role="alert" className="text-sm text-minus">{state.error}</p>}
      <SubmitButton className={`${btn.primary} w-full`} pendingText="Memeriksa…">Masuk</SubmitButton>
    </form>
  );
}

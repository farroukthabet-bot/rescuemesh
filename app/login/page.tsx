"use client";

import Link from "next/link";
import { useState } from "react";
import Logo from "../components/Logo";
import { btn, card, heading, input } from "../components/ui";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const res = await fetch("/api/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : "Sign-in failed");
      window.location.assign("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-in failed");
      setBusy(false);
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-[#0D0C16] px-5 py-10 text-[#ECEAF8]">
      <div className="w-full max-w-sm">
        <div className="flex items-center gap-3">
          <Logo size={46} />
          <div>
            <h1 className={`${heading} text-2xl font-semibold tracking-tight`}>RescueMesh</h1>
            <p className="text-sm text-[#ECEAF8]/60">Rescue the surplus. Prove the rescue.</p>
          </div>
        </div>

        <form onSubmit={submit} className={`${card} mt-8 space-y-4`}>
          <h2 className={`${heading} text-xl font-semibold`}>Sign in</h2>
          <label className="block text-sm">Email
            <input className={`${input} mt-1`} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label className="block text-sm">Password
            <input className={`${input} mt-1`} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
          </label>
          {error && <p role="alert" className="rounded-lg border border-[#FB7185]/50 bg-[#FB7185]/10 px-3 py-2 text-sm">{error}</p>}
          <button className={`${btn} w-full`} disabled={busy}>{busy ? "Signing in\u2026" : "Sign in"}</button>
        </form>

        <p className="mt-5 text-sm text-[#ECEAF8]/65">
          Want to help as a volunteer? <Link href="/join" className="text-[#C9BEFF] underline underline-offset-2">Apply here</Link>.
          Donors and NGOs are added by the administrator: please contact them directly.
        </p>
      </div>
    </main>
  );
}
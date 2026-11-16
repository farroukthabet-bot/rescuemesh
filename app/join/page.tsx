"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import CityMap from "../components/CityMap";
import Logo from "../components/Logo";
import { btn, card, heading, input } from "../components/ui";

const VEHICLE_CAPACITY: Record<string, number> = { Bike: 10, Scooter: 20, Car: 60, Van: 150 };

export default function JoinPage() {
  const [signedIn, setSignedIn] = useState<{ name: string } | null>(null);
  const [checked, setChecked] = useState(false);
  const [f, setF] = useState({ name: "", email: "", password: "", vehicle: "Car", capacityKg: "60", cold: false });
  const [home, setHome] = useState<{ lat: number; lng: number } | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch("/api/me")
      .then((r) => (r.ok ? r.json() : null))
      .then((me) => { if (me) { setSignedIn({ name: me.user.name }); setF((x) => ({ ...x, name: me.user.name })); } })
      .finally(() => setChecked(true));
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!home) { setError("Click the map to set your home position"); return; }
    setBusy(true);
    setError("");
    try {
      const payload = { name: f.name.trim(), transportType: f.vehicle, capacityKg: Number(f.capacityKg), coldStorage: f.cold, latitude: home.lat, longitude: home.lng };
      const res = await fetch(signedIn ? "/api/volunteer-requests" : "/api/auth/signup", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(signedIn ? payload : { ...payload, email: f.email, password: f.password }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : "Could not send your application");
      window.location.assign("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send your application");
      setBusy(false);
    }
  }

  return (
    <main className="min-h-screen bg-[#0D0C16] px-5 py-8 text-[#ECEAF8]">
      <div className="mx-auto max-w-5xl">
        <Link href={signedIn ? "/" : "/login"} className="inline-flex items-center gap-2.5 text-sm text-[#C9BEFF] underline underline-offset-2">
          <Logo size={30} />{signedIn ? "Back to the dashboard" : "Back to sign in"}
        </Link>
        <h1 className={`${heading} mt-5 text-3xl font-semibold tracking-tight`}>Become a volunteer</h1>
        <p className="mt-1 max-w-xl text-sm text-[#ECEAF8]/65">
          Tell us about your vehicle and where you start from. An administrator reviews every application. You can sign in right away, and your missions appear once you are approved.
        </p>

        <div className="mt-8 grid gap-8 lg:grid-cols-[22rem_minmax(0,1fr)]">
          <form onSubmit={submit} className={`${card} space-y-4`}>
            <label className="block text-sm">Name
              <input className={`${input} mt-1`} required minLength={2} maxLength={40} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
            </label>
            {checked && !signedIn && (
              <>
                <label className="block text-sm">Email
                  <input className={`${input} mt-1`} type="email" autoComplete="username" required value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
                </label>
                <label className="block text-sm">Password (8 characters or more)
                  <input className={`${input} mt-1`} type="password" autoComplete="new-password" required minLength={8} value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
                </label>
              </>
            )}
            {signedIn && <p className="text-sm text-[#ECEAF8]/65">You are signed in as {signedIn.name}. This adds the volunteer role to your account.</p>}
            <div className="grid grid-cols-2 gap-3">
              <label className="block text-sm">Vehicle
                <select className={`${input} mt-1`} value={f.vehicle} onChange={(e) => setF({ ...f, vehicle: e.target.value, capacityKg: String(VEHICLE_CAPACITY[e.target.value] ?? f.capacityKg) })}>
                  {Object.keys(VEHICLE_CAPACITY).map((v) => <option key={v} value={v}>{v}</option>)}
                </select>
              </label>
              <label className="block text-sm">Capacity (kg)
                <input className={`${input} mt-1`} type="number" min={1} max={1000} required value={f.capacityKg} onChange={(e) => setF({ ...f, capacityKg: e.target.value })} />
              </label>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={f.cold} onChange={(e) => setF({ ...f, cold: e.target.checked })} />
              Refrigerated transport
            </label>
            <p className="text-sm">{home ? `Home position set (${home.lat.toFixed(4)}, ${home.lng.toFixed(4)}).` : "Click the map to set your home position."}</p>
            {error && <p role="alert" className="rounded-lg border border-[#FB7185]/50 bg-[#FB7185]/10 px-3 py-2 text-sm">{error}</p>}
            <button className={`${btn} w-full`} disabled={busy}>{busy ? "Sending\u2026" : "Send my application"}</button>
          </form>

          <div className="overflow-hidden rounded-2xl border border-[#ECEAF8]/10 bg-[#1D1B42]">
            <CityMap donors={[]} ngos={[]} volunteers={[]} selectedDonorId="" routes={[]} preview={null} onSelectDonor={() => {}}
              pick={{ active: true, point: home, onPick: (lat, lng) => setHome({ lat, lng }) }} />
          </div>
        </div>
      </div>
    </main>
  );
}
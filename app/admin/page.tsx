"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import CityMap from "../components/CityMap";
import Logo from "../components/Logo";
import { btn, btnGhost, card, heading, input } from "../components/ui";

type Org = { id: string; name: string; type: string; latitude: number; longitude: number };
type Vol = { id: string; name: string; latitude: number; longitude: number; available: boolean };
type Req = { id: number; name: string; email: string; transport_type: string; transport_capacity_kg: number; has_cold_storage: boolean; latitude: number; longitude: number };
type Acct = { userId: string; email: string; name: string; memberships: { role: string; status: string; actorId: string | null }[] };
type Overview = { requests: Req[]; accounts: Acct[]; donors: Org[]; ngos: Org[]; volunteers: Vol[] };

async function call(path: string, method = "GET", body?: unknown) {
  const res = await fetch(path, { method, headers: body ? { "Content-Type": "application/json" } : undefined, body: body ? JSON.stringify(body) : undefined });
  if (res.status === 401) { window.location.assign("/login"); throw new Error("Please sign in"); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : "Something went wrong");
  return data;
}

export default function AdminPage() {
  const [ov, setOv] = useState<Overview | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [place, setPlace] = useState({ kind: "DONOR", name: "", contact: "", capacity: "100", cold: true, demand: "medium" });
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(null);
  const [acct, setAcct] = useState({ email: "", name: "", password: "", role: "DONOR", actorId: "" });

  const load = useCallback(async () => { setOv(await call("/api/admin/overview")); }, []);

  useEffect(() => {
    call("/api/me")
      .then((me) => { if (!me.isAdmin) window.location.assign("/"); else return load(); })
      .catch((e) => setNotice({ ok: false, text: e.message }));
  }, [load]);

  async function run(key: string, fn: () => Promise<string>) {
    setBusy(key); setNotice(null);
    try { setNotice({ ok: true, text: await fn() }); await load(); }
    catch (e) { setNotice({ ok: false, text: e instanceof Error ? e.message : "Something went wrong" }); }
    finally { setBusy(null); }
  }
  async function signOut() { await fetch("/api/auth/logout", { method: "POST" }); window.location.assign("/login"); }

  if (!ov) {
    return <main className="min-h-screen bg-[#0D0C16] p-8 text-[#ECEAF8]">{notice ? <p role="alert" className="text-sm text-[#FB7185]">{notice.text}</p> : <p className="text-sm text-[#ECEAF8]/60">Loading&hellip;</p>}</main>;
  }

  const actorChoices = acct.role === "DONOR" ? ov.donors : acct.role === "NGO" ? ov.ngos : acct.role === "VOLUNTEER" ? ov.volunteers : [];

  return (
    <main className="min-h-screen bg-[#0D0C16] px-5 py-8 text-[#ECEAF8]">
      <div className="mx-auto max-w-6xl">
        <header className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Logo size={40} />
            <div>
              <h1 className={`${heading} text-2xl font-semibold tracking-tight`}>Admin console</h1>
              <p className="text-sm text-[#ECEAF8]/60">Places, volunteer applications and accounts.</p>
            </div>
          </div>
          <div className="flex gap-3">
            <Link href="/" className={btnGhost}>Dashboard</Link>
            <button className={btnGhost} onClick={signOut}>Sign out</button>
          </div>
        </header>

        {notice && (
          <p role="status" className={`mt-5 rounded-xl border px-4 py-2.5 text-sm ${notice.ok ? "border-[#34D3A0]/40 bg-[#34D3A0]/10" : "border-[#FB7185]/50 bg-[#FB7185]/10"}`}>{notice.text}</p>
        )}

        {/* ---------------------------------------------------------- volunteer applications */}
        <section aria-label="Volunteer applications" className="mt-8">
          <h2 className={`${heading} text-xl font-semibold`}>Volunteer applications ({ov.requests.length})</h2>
          {ov.requests.length === 0 ? (
            <p className="mt-2 text-sm text-[#ECEAF8]/60">No application is waiting.</p>
          ) : (
            <ul className="mt-3 grid gap-3 md:grid-cols-2">
              {ov.requests.map((r) => (
                <li key={r.id} className={card}>
                  <p className={`${heading} text-lg font-semibold`}>{r.name}</p>
                  <p className="text-sm text-[#ECEAF8]/65">{r.email}</p>
                  <p className="mt-2 text-sm">{r.transport_type}, {r.transport_capacity_kg} kg{r.has_cold_storage ? ", refrigerated" : ""}. Home at {Number(r.latitude).toFixed(4)}, {Number(r.longitude).toFixed(4)}.</p>
                  <div className="mt-4 flex gap-3">
                    <button className={btn} disabled={busy !== null} onClick={() => run(`ok-${r.id}`, async () => {
                      const d = await call(`/api/admin/requests/${r.id}`, "POST", { decision: "approve" });
                      return `${r.name} is now ${d.volunteerId}, with Hedera account ${d.hederaAccountId}.${d.warning ? " " + d.warning : ""}`;
                    })}>{busy === `ok-${r.id}` ? "Creating the Hedera account\u2026" : "Approve"}</button>
                    <button className={btnGhost} disabled={busy !== null} onClick={() => run(`no-${r.id}`, async () => { await call(`/api/admin/requests/${r.id}`, "POST", { decision: "reject" }); return `${r.name}'s application was rejected.`; })}>Reject</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>

        {/* ---------------------------------------------------------- add a donor or an NGO */}
        <section aria-label="Add a place" className="mt-12">
          <h2 className={`${heading} text-xl font-semibold`}>Add a donor or an NGO</h2>
          <p className="mt-1 text-sm text-[#ECEAF8]/60">Donors and NGOs contact you directly. Add the place here, then give them a login below.</p>
          <div className="mt-4 grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)]">
            <div className={`${card} space-y-4`}>
              <div role="group" aria-label="Type" className="flex gap-2">
                {["DONOR", "NGO"].map((k) => (
                  <button key={k} type="button" aria-pressed={place.kind === k} onClick={() => setPlace({ ...place, kind: k })}
                    className={`rounded-lg px-4 py-2 text-sm font-medium ${place.kind === k ? "bg-[#8B7CF6] text-[#0D0C16]" : "border border-[#ECEAF8]/20 text-[#ECEAF8]/75"}`}>{k === "DONOR" ? "Donor" : "NGO"}</button>
                ))}
              </div>
              <label className="block text-sm">Name
                <input className={`${input} mt-1`} value={place.name} maxLength={60} onChange={(e) => setPlace({ ...place, name: e.target.value })} />
              </label>
              <label className="block text-sm">Contact person (optional)
                <input className={`${input} mt-1`} value={place.contact} maxLength={60} onChange={(e) => setPlace({ ...place, contact: e.target.value })} />
              </label>
              {place.kind === "NGO" && (
                <>
                  <div className="grid grid-cols-2 gap-3">
                    <label className="block text-sm">Storage (kg)
                      <input className={`${input} mt-1`} type="number" min={1} value={place.capacity} onChange={(e) => setPlace({ ...place, capacity: e.target.value })} />
                    </label>
                    <label className="block text-sm">Demand
                      <select className={`${input} mt-1`} value={place.demand} onChange={(e) => setPlace({ ...place, demand: e.target.value })}>
                        <option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option>
                      </select>
                    </label>
                  </div>
                  <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" checked={place.cold} onChange={(e) => setPlace({ ...place, cold: e.target.checked })} /> Cold storage
                  </label>
                </>
              )}
              <p className="text-sm">{pin ? `Position set (${pin.lat.toFixed(4)}, ${pin.lng.toFixed(4)}).` : "Click the map to place it."}</p>
              <button className={`${btn} w-full`} disabled={busy !== null || place.name.trim().length < 2 || !pin} onClick={() => run("place", async () => {
                const d = await call("/api/admin/places", "POST", {
                  kind: place.kind, name: place.name.trim(), contactName: place.contact.trim() || undefined, latitude: pin!.lat, longitude: pin!.lng,
                  ...(place.kind === "NGO" ? { capacityKg: Number(place.capacity), coldStorage: place.cold, demand: place.demand } : {}),
                });
                setPlace({ ...place, name: "", contact: "" }); setPin(null);
                return `${place.name.trim()} was added as ${d.id}, with Hedera account ${d.hederaAccountId}.${d.warning ? " " + d.warning : ""}`;
              })}>{busy === "place" ? "Creating the Hedera account\u2026" : "Add this place"}</button>
            </div>
            <div className="overflow-hidden rounded-2xl border border-[#ECEAF8]/10 bg-[#1D1B42]">
              <CityMap donors={ov.donors} ngos={ov.ngos} volunteers={ov.volunteers} selectedDonorId="" routes={[]} preview={null} onSelectDonor={() => {}}
                pick={{ active: true, point: pin, onPick: (lat, lng) => setPin({ lat, lng }) }} />
            </div>
          </div>
        </section>

        {/* ---------------------------------------------------------- maintenance */}
        <section aria-label="Maintenance" className="mt-12">
          <h2 className={`${heading} text-xl font-semibold`}>Maintenance</h2>
          <div className="mt-3 flex flex-wrap gap-3">
            <button className={btnGhost} disabled={busy !== null} onClick={() => run("retry", async () => {
              const d = await call("/api/hedera/retry", "POST");
              return `${d.confirmed} event(s) recorded on Hedera${d.stillPending ? `, ${d.stillPending} still pending` : ""}.`;
            })}>Retry pending Hedera events</button>
            <button className={btnGhost} disabled={busy !== null} onClick={() => {
              if (!window.confirm("Hide every current donation and mission from the dashboard? Hedera records stay on the ledger and old Verify links keep working.")) return;
              run("reset", async () => { const d = await call("/api/demo/reset", "POST"); return `${d.archived} donation(s) archived. The dashboard is clean.`; });
            }}>Archive demo data</button>
          </div>
        </section>

        {/* ---------------------------------------------------------- accounts and roles */}
        <section aria-label="Accounts and roles" className="mt-12 pb-16">
          <h2 className={`${heading} text-xl font-semibold`}>Accounts and roles</h2>
          <p className="mt-1 text-sm text-[#ECEAF8]/60">One login can hold several roles (donor, NGO and volunteer at once). Use the same email to add a role to an existing login.</p>
          <div className="mt-4 grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)]">
            <div className={`${card} space-y-4`}>
              <label className="block text-sm">Email
                <input className={`${input} mt-1`} type="email" value={acct.email} onChange={(e) => setAcct({ ...acct, email: e.target.value })} />
              </label>
              <label className="block text-sm">Name (only for a new login)
                <input className={`${input} mt-1`} value={acct.name} maxLength={60} onChange={(e) => setAcct({ ...acct, name: e.target.value })} />
              </label>
              <label className="block text-sm">Temporary password (only for a new login)
                <input className={`${input} mt-1`} type="password" autoComplete="new-password" value={acct.password} onChange={(e) => setAcct({ ...acct, password: e.target.value })} />
              </label>
              <div className="grid grid-cols-2 gap-3">
                <label className="block text-sm">Role
                  <select className={`${input} mt-1`} value={acct.role} onChange={(e) => setAcct({ ...acct, role: e.target.value, actorId: "" })}>
                    <option value="DONOR">Donor</option><option value="NGO">NGO</option><option value="VOLUNTEER">Volunteer</option><option value="ADMIN">Administrator</option>
                  </select>
                </label>
                {acct.role !== "ADMIN" && (
                  <label className="block text-sm">For
                    <select className={`${input} mt-1`} value={acct.actorId} onChange={(e) => setAcct({ ...acct, actorId: e.target.value })}>
                      <option value="">Choose</option>
                      {actorChoices.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                    </select>
                  </label>
                )}
              </div>
              <button className={`${btn} w-full`} disabled={busy !== null || !acct.email.includes("@") || (acct.role !== "ADMIN" && !acct.actorId)} onClick={() => run("acct", async () => {
                const d = await call("/api/admin/accounts", "POST", {
                  email: acct.email, role: acct.role, actorId: acct.actorId || undefined,
                  name: acct.name.trim() || undefined, password: acct.password || undefined,
                });
                setAcct({ ...acct, email: "", name: "", password: "" });
                return d.createdLogin ? `A new login was created for ${d.email} and the role was given.` : `The role was added to ${d.email}.`;
              })}>{busy === "acct" ? "Saving\u2026" : "Give this role"}</button>
            </div>

            <div className="overflow-x-auto rounded-2xl border border-[#ECEAF8]/10">
              <table className="w-full min-w-[520px] text-left text-sm">
                <thead className="bg-[#16152A] text-[#ECEAF8]/60">
                  <tr><th className="px-4 py-2.5 font-medium">Person</th><th className="px-4 py-2.5 font-medium">Roles</th></tr>
                </thead>
                <tbody className="divide-y divide-[#ECEAF8]/10">
                  {ov.accounts.map((a) => (
                    <tr key={a.userId}>
                      <td className="px-4 py-2.5"><p className="font-medium">{a.name}</p><p className="text-xs text-[#ECEAF8]/55">{a.email}</p></td>
                      <td className="px-4 py-2.5">
                        {a.memberships.length === 0 ? <span className="text-[#ECEAF8]/45">none</span> : a.memberships.map((m) => (
                          <span key={m.role} className="mr-2 inline-block rounded-full bg-[#8B7CF6]/20 px-2.5 py-0.5 text-xs text-[#D2C9FF]">
                            {m.role.toLowerCase()}{m.actorId ? ` ${m.actorId}` : ""}{m.status !== "ACTIVE" ? ` (${m.status.toLowerCase()})` : ""}
                          </span>
                        ))}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
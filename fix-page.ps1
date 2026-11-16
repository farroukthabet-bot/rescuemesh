# RescueMesh: rewrites app\page.tsx (ASCII-only, fixes garbled characters).
# From the project root:  powershell -ExecutionPolicy Bypass -File .\fix-page.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$full = [System.IO.Path]::Combine($root, "app\page.tsx")
$content = @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string };
type Named = { id: string; name: string };
type EventRow = { event_type: string; status: string; hedera_sequence_number: string | null };
type Recommendation = {
  ngoId: string; ngoName: string; ngoDistanceKm: number; volunteerId: string; volunteerName: string;
  estimatedPickupMinutes: number; estimatedDeliveryMinutes: number; riskLevel: string; matchScore: number;
  reason: string[]; explanation: string; source: string;
};
type MatchResult = {
  matched: boolean; recommendation?: Recommendation;
  rejected?: { name: string; reasons: string[] }[];
};

const DONORS: Record<string, string> = { "DONOR-01": "FreshMart" };
const KG_PER_MEAL = 0.5; // estimate used for "meal equivalents"

const btn =
  "rounded-md bg-[#1F4D3A] px-4 py-2 text-sm font-medium text-white hover:bg-[#173B2C] disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#1F5FBF]";
const btnGhost =
  "rounded-md border border-[#1F4D3A]/40 px-4 py-2 text-sm font-medium text-[#1F4D3A] hover:bg-[#1F4D3A]/5 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#1F5FBF]";
const input =
  "w-full rounded-md border border-[#16231C]/25 bg-white px-3 py-2 text-sm focus-visible:outline-2 focus-visible:outline-[#1F5FBF]";

const human = (s: string) => (s.charAt(0) + s.slice(1).toLowerCase()).replace(/_/g, " ");
const EVENT_LABEL: Record<string, string> = {
  DONATION_CREATED: "Donation created",
  NGO_MATCHED: "NGO matched",
  VOLUNTEER_ASSIGNED: "Volunteer assigned",
  PICKUP_CONFIRMED: "Pickup confirmed",
  DELIVERY_CONFIRMED: "Delivery confirmed",
};

async function api(path: string, method = "GET", body?: unknown) {
  const res = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : JSON.stringify(data.error ?? data));
  return data;
}

function Badge({ status }: { status: string }) {
  const tone =
    status === "COMPLETED" ? "bg-[#1F4D3A] text-white"
    : status === "AVAILABLE" ? "bg-[#DDEBD9] text-[#1F4D3A]"
    : status === "PICKED_UP" ? "bg-[#DCE7F8] text-[#1F5FBF]"
    : "bg-[#F6E4BF] text-[#8A5606]";
  return <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${tone}`}>{human(status)}</span>;
}

export default function Home() {
  const [role, setRole] = useState<Role>("Donor");
  const [donations, setDonations] = useState<Donation[]>([]);
  const [missions, setMissions] = useState<Mission[]>([]);
  const [ngos, setNgos] = useState<Named[]>([]);
  const [vols, setVols] = useState<Named[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [events, setEvents] = useState<EventRow[]>([]);
  const [match, setMatch] = useState<MatchResult | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, setPending] = useState(0);
  const [received, setReceived] = useState<Record<string, string>>({});
  const [form, setForm] = useState({ foodType: "Prepared meals", quantityKg: "50", storage: "refrigerated", minutes: "120" });

  const load = useCallback(async () => {
    const [d, m, n, v, p] = await Promise.all([
      api("/api/donations"), api("/api/missions"), api("/api/ngos"), api("/api/volunteers"), api("/api/hedera/retry"),
    ]);
    setDonations(d); setMissions(m); setNgos(n); setVols(v); setPending(p.pending);
  }, []);

  useEffect(() => { load().catch((e) => setNotice({ ok: false, text: e.message })); }, [load]);

  useEffect(() => {
    if (!selectedId) { setEvents([]); return; }
    api(`/api/donations/${selectedId}`).then((r) => setEvents(r.events ?? [])).catch(() => setEvents([]));
  }, [selectedId, donations]);

  async function run(key: string, fn: () => Promise<string | void>) {
    setBusy(key); setNotice(null);
    try {
      const text = await fn();
      if (text) setNotice({ ok: true, text });
      await load();
    } catch (e) {
      setNotice({ ok: false, text: e instanceof Error ? e.message : "Something went wrong" });
    } finally { setBusy(null); }
  }

  async function resetDemo() {
    if (!window.confirm("Reset the demo? Donations and missions disappear from the dashboard. Hedera records stay on the public ledger.")) return;
    await run("reset", async () => {
      await api("/api/demo/reset", "POST");
      setSelectedId(null); setMatch(null); setEvents([]);
      return "Demo reset. Earlier donations stay verifiable through their verify links.";
    });
  }

  const selected = donations.find((d) => d.id === selectedId) ?? null;
  const nameOf = (list: Named[], id: string) => list.find((x) => x.id === id)?.name ?? id;
  const donationOf = (id: string) => donations.find((d) => d.id === id);
  const done = donations.filter((d) => d.status === "COMPLETED");
  const stats = [
    { label: "Active donations", value: donations.filter((d) => d.status === "AVAILABLE").length },
    { label: "Active missions", value: missions.filter((m) => m.status !== "COMPLETED").length },
    { label: "Food rescued (kg)", value: done.reduce((s, d) => s + Number(d.quantity_kg), 0) },
    { label: "Verified deliveries", value: done.length },
  ];

  const hederaText = (h: { status?: string } | undefined) =>
    h?.status === "CONFIRMED" ? "Recorded on Hedera." : "Saved. Hedera verification is pending.";

  return (
    <main className="min-h-screen bg-[#F2F4EF] text-[#16231C]">
      <div className="mx-auto max-w-6xl px-5 py-8">
        <header className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="font-serif text-4xl font-semibold tracking-tight">RescueMesh</h1>
            <p className="mt-1 max-w-md text-sm text-[#16231C]/70">
              AI decides who should act. Hedera proves what actually happened.
            </p>
          </div>
          <div className="flex items-center gap-3">
          <button className={btnGhost} disabled={busy !== null} onClick={resetDemo}>{busy === "reset" ? "Resetting\u2026" : "Reset demo"}</button>
          <div role="group" aria-label="Switch role" className="flex rounded-lg border border-[#16231C]/20 bg-white p-1">
            {(["Donor", "Volunteer", "NGO"] as Role[]).map((r) => (
              <button key={r} aria-pressed={role === r} onClick={() => setRole(r)}
                className={`rounded-md px-4 py-1.5 text-sm font-medium focus-visible:outline-2 focus-visible:outline-[#1F5FBF] ${role === r ? "bg-[#1F4D3A] text-white" : "text-[#16231C]/70 hover:bg-[#16231C]/5"}`}>
                {r}
              </button>
            ))}
          </div>
          </div>
        </header>

        <section className="mt-8 grid grid-cols-2 divide-x divide-[#16231C]/15 border-y border-[#16231C]/15 sm:grid-cols-4">
          {stats.map((s) => (
            <div key={s.label} className="px-4 py-4 first:pl-0">
              <div className="font-serif text-3xl font-semibold tabular-nums">{s.value}</div>
              <div className="text-sm text-[#16231C]/65">{s.label}</div>
            </div>
          ))}
        </section>

        {notice && (
          <p role="status" className={`mt-5 border-l-4 px-4 py-2 text-sm ${notice.ok ? "border-[#1F4D3A] bg-[#DDEBD9]" : "border-[#B3261E] bg-[#F9DEDC]"}`}>
            {notice.text}
          </p>
        )}

        {pending > 0 && (
          <p className="mt-5 flex flex-wrap items-center gap-3 border-l-4 border-[#C77D0A] bg-[#F6E4BF] px-4 py-2 text-sm">
            {pending} {pending === 1 ? "event is" : "events are"} waiting for Hedera verification. The app keeps working.
            <button className={btnGhost} disabled={busy !== null} onClick={() => run("retry", async () => {
              const r = await api("/api/hedera/retry", "POST");
              return `${r.confirmed} ${r.confirmed === 1 ? "event" : "events"} recorded on Hedera${r.stillPending ? `, ${r.stillPending} still pending` : ""}.`;
            })}>
              {busy === "retry" ? "Retrying\u2026" : "Retry now"}
            </button>
          </p>
        )}

        <div className="mt-8 grid gap-10 lg:grid-cols-[26rem_1fr]">
          {/* ------------------------------------------------ role panel */}
          <section aria-label={`${role} actions`}>
            {role === "Donor" && (
              <>
                <h2 className="font-serif text-xl font-semibold">Report surplus food</h2>
                <p className="mb-4 text-sm text-[#16231C]/65">Donating as FreshMart, Tunis Centre.</p>
                <div className="space-y-3">
                  <label className="block text-sm">Food type
                    <input className={`${input} mt-1`} value={form.foodType} onChange={(e) => setForm({ ...form, foodType: e.target.value })} />
                  </label>
                  <div className="grid grid-cols-2 gap-3">
                    <label className="block text-sm">Quantity (kg)
                      <input type="number" min={1} className={`${input} mt-1`} value={form.quantityKg} onChange={(e) => setForm({ ...form, quantityKg: e.target.value })} />
                    </label>
                    <label className="block text-sm">Expires in (min)
                      <input type="number" min={1} className={`${input} mt-1`} value={form.minutes} onChange={(e) => setForm({ ...form, minutes: e.target.value })} />
                    </label>
                  </div>
                  <label className="block text-sm">Storage
                    <select className={`${input} mt-1`} value={form.storage} onChange={(e) => setForm({ ...form, storage: e.target.value })}>
                      <option value="refrigerated">Refrigerated</option>
                      <option value="ambient">Ambient</option>
                    </select>
                  </label>
                  <button className={btn} disabled={busy !== null} onClick={() => run("create", async () => {
                    const r = await api("/api/donations", "POST", {
                      donorId: "DONOR-01", foodType: form.foodType, quantityKg: Number(form.quantityKg),
                      storageRequirement: form.storage, expiresInMinutes: Number(form.minutes),
                    });
                    setSelectedId(r.donation.id); setMatch(null);
                    return `Donation ${r.donation.id} created. ${hederaText(r.hedera)}`;
                  })}>
                    {busy === "create" ? "Recording on Hedera\u2026" : "Create donation"}
                  </button>
                </div>

                {selected?.status === "AVAILABLE" && (
                  <div className="mt-8 border-t border-[#16231C]/15 pt-6">
                    <h2 className="font-serif text-xl font-semibold">Rescue match for {selected.id}</h2>
                    {!match && (
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run("match", async () => {
                        setMatch(await api(`/api/donations/${selected.id}/match`, "POST"));
                      })}>
                        {busy === "match" ? "AI Coordinator is working\u2026" : "Find rescue match"}
                      </button>
                    )}
                    {busy === "match" && (
                      <ul className="mt-3 animate-pulse space-y-1 text-sm text-[#16231C]/70">
                        <li>Checking NGO capacity and cold storage</li>
                        <li>Checking volunteer availability and transport</li>
                        <li>Checking the expiration window</li>
                      </ul>
                    )}
                    {match && !match.matched && (
                      <div className="mt-3 text-sm">
                        <p className="font-medium text-[#B3261E]">No safe match found.</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5 text-[#16231C]/75">
                          {match.rejected?.map((r) => <li key={r.name}>{r.name}: {r.reasons.join("; ")}</li>)}
                        </ul>
                        <button className={`${btnGhost} mt-3`} onClick={() => setMatch(null)}>Try again</button>
                      </div>
                    )}
                    {match?.matched && match.recommendation && (
                      <div className="mt-3 text-sm">
                        <p className="font-serif text-lg font-semibold">
                          {match.recommendation.ngoName} + {match.recommendation.volunteerName}
                        </p>
                        <p className="text-[#16231C]/70">
                          Pickup in about {match.recommendation.estimatedPickupMinutes} min, delivery in about {match.recommendation.estimatedDeliveryMinutes} min.
                          Risk: {match.recommendation.riskLevel.toLowerCase()}. NGO is {match.recommendation.ngoDistanceKm} km away.
                        </p>
                        <p className="mt-3">{match.recommendation.explanation}</p>
                        <ul className="mt-3 list-disc space-y-1 pl-5 text-[#16231C]/75">
                          {match.recommendation.reason.map((r) => <li key={r}>{r}</li>)}
                        </ul>
                        <p className="mt-2 text-xs text-[#16231C]/55">
                          {match.recommendation.source === "llm" ? "Explained by the local AI model. All numbers come from the database." : "AI model unavailable. Deterministic fallback used."}
                        </p>
                        <div className="mt-4 flex gap-3">
                          <button className={btn} disabled={busy !== null} onClick={() => run("accept", async () => {
                            const rec = match.recommendation!;
                            await api(`/api/donations/${selected.id}/accept`, "POST", { ngoId: rec.ngoId, volunteerId: rec.volunteerId });
                            setMatch(null);
                            return `Mission accepted. Matching and assignment recorded on Hedera. Switch to Volunteer to confirm pickup.`;
                          })}>
                            {busy === "accept" ? "Recording on Hedera\u2026" : "Accept mission"}
                          </button>
                          <button className={btnGhost} disabled={busy !== null} onClick={() => setMatch(null)}>Discard</button>
                        </div>
                      </div>
                    )}
                  </div>
                )}
              </>
            )}

            {role === "Volunteer" && (
              <>
                <h2 className="font-serif text-xl font-semibold">Missions to pick up</h2>
                {missions.filter((m) => m.status === "PICKUP_PENDING").length === 0 && (
                  <p className="mt-3 text-sm text-[#16231C]/65">No missions waiting. As a donor, create a donation and accept a match first.</p>
                )}
                {missions.filter((m) => m.status === "PICKUP_PENDING").map((m) => {
                  const d = donationOf(m.donation_id);
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#C77D0A] pl-4">
                      <p className="font-serif text-lg font-semibold">Mission {m.donation_id}</p>
                      <p className="text-sm text-[#16231C]/70">
                        {d && DONORS[d.donor_id]}: {d?.quantity_kg} kg of {d?.food_type.toLowerCase()}. Driver: {nameOf(vols, m.volunteer_id)}. Pickup pending.
                      </p>
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`pickup-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/pickup`, "POST", { volunteerId: m.volunteer_id });
                        setSelectedId(m.donation_id);
                        return `Pickup confirmed. ${hederaText(r.hedera)}`;
                      })}>
                        {busy === `pickup-${m.id}` ? "Recording on Hedera\u2026" : "Confirm pickup"}
                      </button>
                    </div>
                  );
                })}
              </>
            )}

            {role === "NGO" && (
              <>
                <h2 className="font-serif text-xl font-semibold">Incoming donations</h2>
                {missions.filter((m) => m.status === "PICKED_UP").length === 0 && (
                  <p className="mt-3 text-sm text-[#16231C]/65">Nothing on the way yet. Deliveries appear here once a volunteer confirms pickup.</p>
                )}
                {missions.filter((m) => m.status === "PICKED_UP").map((m) => {
                  const d = donationOf(m.donation_id);
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#1F5FBF] pl-4">
                      <p className="font-serif text-lg font-semibold">{nameOf(ngos, m.ngo_id)} receives {m.donation_id}</p>
                      <p className="text-sm text-[#16231C]/70">
                        {d && DONORS[d.donor_id]}, {d?.quantity_kg} kg, carried by {nameOf(vols, m.volunteer_id)}.
                      </p>
                      <label className="mt-3 block text-sm">Quantity received (kg)
                        <input type="number" min={1} className={`${input} mt-1 max-w-40`}
                          value={received[m.id] ?? String(d?.quantity_kg ?? "")}
                          onChange={(e) => setReceived({ ...received, [m.id]: e.target.value })} />
                      </label>
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`deliver-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/deliver`, "POST", {
                          ngoId: m.ngo_id, quantityReceivedKg: Number(received[m.id] ?? d?.quantity_kg),
                        });
                        setSelectedId(m.donation_id);
                        return `Delivery confirmed. ${hederaText(r.hedera)}`;
                      })}>
                        {busy === `deliver-${m.id}` ? "Recording on Hedera\u2026" : "Confirm delivery"}
                      </button>
                    </div>
                  );
                })}
              </>
            )}
          </section>

          {/* ------------------------------------------------ donations + receipt */}
          <section aria-label="Donations">
            <h2 className="font-serif text-xl font-semibold">Donations</h2>
            {donations.length === 0 ? (
              <p className="mt-3 text-sm text-[#16231C]/65">No donations yet. Report surplus food as a donor to start.</p>
            ) : (
              <ul className="mt-3 divide-y divide-[#16231C]/15 border-y border-[#16231C]/15">
                {donations.map((d) => (
                  <li key={d.id}>
                    <button onClick={() => { setSelectedId(d.id); setMatch(null); }} aria-current={selectedId === d.id}
                      className={`flex w-full items-center justify-between gap-3 px-3 py-3 text-left hover:bg-white focus-visible:outline-2 focus-visible:outline-[#1F5FBF] ${selectedId === d.id ? "bg-white" : ""}`}>
                      <span>
                        <span className="font-medium">{d.id}</span>
                        <span className="ml-2 text-sm text-[#16231C]/65">{d.quantity_kg} kg, {d.food_type.toLowerCase()}, {d.storage_requirement}</span>
                      </span>
                      <Badge status={d.status} />
                    </button>
                  </li>
                ))}
              </ul>
            )}

            {selected && (
              <div className="mt-8">
                <h3 className="font-serif text-lg font-semibold">Hedera record for {selected.id}</h3>
                {events.length === 0 ? (
                  <p className="mt-2 text-sm text-[#16231C]/65">No events yet.</p>
                ) : (
                  <ol className="mt-2 space-y-1 text-sm">
                    {events.map((e) => (
                      <li key={e.event_type} className="flex gap-2">
                        <span aria-hidden>{e.status === "CONFIRMED" ? "\u2713" : "\u2026"}</span>
                        <span>{EVENT_LABEL[e.event_type] ?? e.event_type}</span>
                        <span className="text-[#16231C]/55">
                          {e.status === "CONFIRMED" ? `sequence ${e.hedera_sequence_number}` : "pending verification"}
                        </span>
                      </li>
                    ))}
                  </ol>
                )}

                {selected.status === "COMPLETED" && (
                  <div className="mt-6 max-w-sm border-2 border-dashed border-[#1F4D3A]/50 bg-white p-5">
                    <p className="font-serif text-xl font-semibold">Impact receipt</p>
                    <dl className="mt-3 space-y-1 text-sm">
                      <div className="flex justify-between"><dt>Donation</dt><dd>{selected.id}</dd></div>
                      <div className="flex justify-between"><dt>Food rescued</dt><dd>{selected.quantity_kg} kg</dd></div>
                      <div className="flex justify-between"><dt>Meal equivalents (estimate)</dt><dd>&asymp; {Math.round(Number(selected.quantity_kg) / KG_PER_MEAL)}</dd></div>
                      <div className="flex justify-between"><dt>Hedera events recorded</dt><dd>{events.filter((e) => e.status === "CONFIRMED").length}</dd></div>
                    </dl>
                    <p className="mt-3 text-xs text-[#16231C]/55">Meals are estimated at {KG_PER_MEAL} kg per meal. This is an estimate, not a measurement.</p>
                    <Link href={`/verify/${selected.id}`} className={`${btn} mt-4 inline-block`}>Verify on Hedera</Link>
                  </div>
                )}
              </div>
            )}
          </section>
        </div>
      </div>
    </main>
  );
}
'@
[System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote app\page.tsx"

# RescueMesh: Start pickup button on the volunteer page, safer delivery, no more blocked volunteers.
# 1) Run supabase\phase11.sql in Supabase FIRST.
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase11.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}




Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import CodeStep from "./components/CodeStep";
import QrCode from "./components/QrCode";
import CityMap, { type MapPreview, type MapRoute } from "./components/CityMap";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string; pickup_latitude: number; pickup_longitude: number };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string; received_kg: number | null };
type Named = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Rep = { id: string; name: string; count: number; kg: number };
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

// Typical surplus per donor (form defaults when you click a donor on the map).
const DONOR_PRESETS: Record<string, { foodType: string; quantityKg: string; storage: string }> = {
  "DONOR-01": { foodType: "Fresh groceries", quantityKg: "60", storage: "refrigerated" },
  "DONOR-02": { foodType: "Bakery goods", quantityKg: "25", storage: "ambient" },
  "DONOR-03": { foodType: "Fresh produce", quantityKg: "40", storage: "refrigerated" },
  "DONOR-04": { foodType: "Prepared meals", quantityKg: "50", storage: "refrigerated" },
};
const KG_PER_MEAL = 0.5; // estimate used for "meal equivalents"

const btn =
  "rounded-md bg-[#2A3EB1] px-4 py-2 text-sm font-medium text-white hover:bg-[#1F2F8C] disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2A3EB1]";
const btnGhost =
  "rounded-md border border-[#2A3EB1]/40 px-4 py-2 text-sm font-medium text-[#2A3EB1] hover:bg-[#2A3EB1]/5 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#2A3EB1]";
const input =
  "w-full rounded-md border border-[#0E2237]/25 bg-white px-3 py-2 text-sm focus-visible:outline-2 focus-visible:outline-[#2A3EB1]";

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
  const raw = await res.text();
  let data;
  try { data = JSON.parse(raw); } catch {
    throw new Error(`${method} ${path} returned HTTP ${res.status} (not JSON). Look at the npm run dev terminal for the real error.`);
  }
  if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : JSON.stringify(data.error ?? data));
  return data;
}

function Badge({ status }: { status: string }) {
  const tone =
    status === "COMPLETED" ? "bg-[#0F7B6C] text-white"
    : status === "AVAILABLE" ? "bg-[#E6EAFB] text-[#2A3EB1]"
    : status === "PICKED_UP" ? "bg-[#D9F0EC] text-[#0B5E52]"
    : "bg-[#FDEFC4] text-[#7A5200]";
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
  const [donors, setDonors] = useState<Named[]>([]);
  const [donorId, setDonorId] = useState("DONOR-04");
  const [mounted, setMounted] = useState(false);
  const [rep, setRep] = useState<{ donors: Rep[]; ngos: Rep[]; volunteers: Rep[] }>({ donors: [], ngos: [], volunteers: [] });
  const [codes, setCodes] = useState<Record<string, string>>({});
  const [received, setReceived] = useState<Record<string, string>>({});
  const [form, setForm] = useState({ foodType: "Prepared meals", quantityKg: "50", storage: "refrigerated", minutes: "120" });

  const load = useCallback(async () => {
    const [d, m, n, v, p, r, dn] = await Promise.all([
      api("/api/donations"), api("/api/missions"), api("/api/ngos"), api("/api/volunteers"), api("/api/hedera/retry"), api("/api/reputation"), api("/api/donors"),
    ]);
    setDonations(d); setMissions(m); setNgos(n); setVols(v); setPending(p.pending); setRep(r); setDonors(dn);
  }, []);

  useEffect(() => setMounted(true), []);
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

  const donorName = (id: string) => donors.find((x) => x.id === id)?.name ?? id;
  function selectDonor(id: string) {
    setRole("Donor"); setDonorId(id); setSelectedId(null); setMatch(null);
    const preset = DONOR_PRESETS[id];
    if (preset) setForm((f) => ({ ...f, ...preset }));
  }

  const selected = donations.find((d) => d.id === selectedId) ?? null;

  const selMission = selected ? missions.find((m) => m.donation_id === selected.id) : undefined;
  const rescuedKg = Number(selMission?.received_kg ?? selected?.quantity_kg ?? 0);

  // Mission status as the user should see it: if the donation is completed, the mission is too.
  const ms = (m: Mission) => (donations.find((d) => d.id === m.donation_id)?.status === "COMPLETED" ? "COMPLETED" : m.status);

  // Map: one entry per volunteer, decided by that volunteer's latest mission (the API lists newest first),
  // so several missions can run side by side and selecting a donation never moves anybody.
  const volRoutes: MapRoute[] = vols.flatMap((v) => {
    const mine = missions.filter((m) => m.volunteer_id === v.id);
    const current = mine.find((m) => ms(m) !== "COMPLETED") ?? mine[0];
    const dn = current && donations.find((d) => d.id === current.donation_id);
    if (!current || !dn) return [];
    return [{
      volunteerId: v.id, donorId: dn.donor_id, ngoId: current.ngo_id,
      stage: (ms(current) === "PICKUP_PENDING" ? "assigned" : ms(current) === "EN_ROUTE" ? "donor" : ms(current) === "PICKED_UP" ? "ngo" : "back") as MapRoute["stage"],
      highlight: current.donation_id === selected?.id,
    }];
  });
  const selRec = selected?.status === "AVAILABLE" ? match?.recommendation : undefined;
  const preview: MapPreview | null = selected && selRec
    ? { volunteerId: selRec.volunteerId, donorId: selected.donor_id, ngoId: selRec.ngoId } : null;

  // Quantity check for the NGO: what was sent versus what was received.
  function receivedState(m: Mission) {
    const sent = Number(donations.find((d) => d.id === m.donation_id)?.quantity_kg ?? 0);
    const got = Number(received[m.id] ?? sent);
    return { sent, got, valid: got > 0 && got <= sent };
  }
  const nameOf = (list: Named[], id: string) => list.find((x) => x.id === id)?.name ?? id;
  const donationOf = (id: string) => donations.find((d) => d.id === id);
  const done = donations.filter((d) => d.status === "COMPLETED");
  const stats = [
    { label: "Active donations", value: donations.filter((d) => d.status === "AVAILABLE").length },
    { label: "Active missions", value: missions.filter((m) => ms(m) !== "COMPLETED").length },
    { label: "Food rescued (kg)", value: missions.filter((m) => ms(m) === "COMPLETED").reduce((s, m) => s + Number(m.received_kg ?? donationOf(m.donation_id)?.quantity_kg ?? 0), 0) },
    { label: "Verified deliveries", value: done.length },
  ];

  if (!mounted) return <main className="min-h-screen bg-[#F4F7FB]" />; // render the UI only in the browser: extensions inject attributes into server HTML

  const hederaText = (h: { status?: string } | undefined) =>
    h?.status === "CONFIRMED" ? "Recorded on Hedera." : "Saved. Hedera verification is pending.";

  return (
    <main className="min-h-screen bg-[#F4F7FB] text-[#0E2237]">
      <div className="mx-auto max-w-6xl px-5 py-8">
        <header className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="font-[family-name:var(--font-heading)] text-4xl font-semibold tracking-tight">RescueMesh</h1>
            <p className="mt-1 max-w-md text-sm text-[#0E2237]/70">
              Rescue the surplus. Prove the rescue.
            </p>
          </div>
          <div className="flex items-center gap-3">
          <div role="group" aria-label="Switch role" className="flex rounded-lg border border-[#0E2237]/20 bg-white p-1">
            {(["Donor", "Volunteer", "NGO"] as Role[]).map((r) => (
              <button key={r} aria-pressed={role === r} onClick={() => setRole(r)}
                className={`rounded-md px-4 py-1.5 text-sm font-medium focus-visible:outline-2 focus-visible:outline-[#2A3EB1] ${role === r ? "bg-[#2A3EB1] text-white" : "text-[#0E2237]/70 hover:bg-[#0E2237]/5"}`}>
                {r}
              </button>
            ))}
          </div>
          </div>
        </header>

        <section className="mt-8 grid grid-cols-2 divide-x divide-[#0E2237]/15 border-y border-[#0E2237]/15 sm:grid-cols-4">
          {stats.map((s) => (
            <div key={s.label} className="px-4 py-4 first:pl-0">
              <div className="font-[family-name:var(--font-heading)] text-3xl font-semibold tabular-nums">{s.value}</div>
              <div className="text-sm text-[#0E2237]/65">{s.label}</div>
            </div>
          ))}
        </section>

        {notice && (
          <p role="status" className={`mt-5 border-l-4 px-4 py-2 text-sm ${notice.ok ? "border-[#0F7B6C] bg-[#D9F0EC]" : "border-[#C0392B] bg-[#FBE3DF]"}`}>
            {notice.text}
          </p>
        )}

        {pending > 0 && (
          <p className="mt-5 flex flex-wrap items-center gap-3 border-l-4 border-[#E8A200] bg-[#FDEFC4] px-4 py-2 text-sm">
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
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Report surplus food</h2>
                <p className="mb-4 text-sm text-[#0E2237]/65">Donating as <strong>{donorName(donorId)}</strong>. Click a donor on the map to switch.</p>
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
                      donorId, foodType: form.foodType, quantityKg: Number(form.quantityKg),
                      storageRequirement: form.storage, expiresInMinutes: Number(form.minutes),
                    });
                    setSelectedId(r.donation.id); setMatch(null);
                    return `Donation ${r.donation.id} created. ${hederaText(r.hedera)}`;
                  })}>
                    {busy === "create" ? "Recording on Hedera\u2026" : "Create donation"}
                  </button>
                </div>

                {selected?.status === "AVAILABLE" && (
                  <div className="mt-8 border-t border-[#0E2237]/15 pt-6">
                    <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Rescue match for {selected.id}</h2>
                    {!match && (
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run("match", async () => {
                        setMatch(await api(`/api/donations/${selected.id}/match`, "POST"));
                      })}>
                        {busy === "match" ? "AI Coordinator is working\u2026" : "Find rescue match"}
                      </button>
                    )}
                    {busy === "match" && (
                      <ul className="mt-3 animate-pulse space-y-1 text-sm text-[#0E2237]/70">
                        <li>Checking NGO capacity and cold storage</li>
                        <li>Checking volunteer availability and transport</li>
                        <li>Checking the expiration window</li>
                      </ul>
                    )}
                    {match && !match.matched && (
                      <div className="mt-3 text-sm">
                        <p className="font-medium text-[#C0392B]">No safe match found.</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5 text-[#0E2237]/75">
                          {match.rejected?.map((r) => <li key={r.name}>{r.name}: {r.reasons.join("; ")}</li>)}
                        </ul>
                        <button className={`${btnGhost} mt-3`} onClick={() => setMatch(null)}>Try again</button>
                      </div>
                    )}
                    {match?.matched && match.recommendation && (
                      <div className="mt-3 text-sm">
                        <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">
                          {match.recommendation.ngoName} + {match.recommendation.volunteerName}
                        </p>
                        <p className="text-[#0E2237]/70">
                          Pickup in about {match.recommendation.estimatedPickupMinutes} min, delivery in about {match.recommendation.estimatedDeliveryMinutes} min.
                          Risk: {match.recommendation.riskLevel.toLowerCase()}. NGO is {match.recommendation.ngoDistanceKm} km away.
                        </p>
                        <p className="mt-3">{match.recommendation.explanation}</p>
                        <ul className="mt-3 list-disc space-y-1 pl-5 text-[#0E2237]/75">
                          {match.recommendation.reason.map((r) => <li key={r}>{r}</li>)}
                        </ul>
                        {match.recommendation.source !== "llm" && (
                          <p className="mt-2 text-xs text-[#0E2237]/55">AI model unavailable. Deterministic fallback used.</p>
                        )}
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
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Missions to pick up</h2>
                {missions.filter((m) => ["PICKUP_PENDING", "EN_ROUTE"].includes(ms(m))).length === 0 && (
                  <p className="mt-3 text-sm text-[#0E2237]/65">No missions waiting. As a donor, create a donation and accept a match first.</p>
                )}
                {missions.filter((m) => ["PICKUP_PENDING", "EN_ROUTE"].includes(ms(m))).map((m) => {
                  const d = donationOf(m.donation_id);
                  const started = ms(m) === "EN_ROUTE";
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#E8A200] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">Mission {m.donation_id}</p>
                      <p className="text-sm text-[#0E2237]/70">
                        {d && donorName(d.donor_id)}: {d?.quantity_kg} kg of {d?.food_type.toLowerCase()}. Driver: {nameOf(vols, m.volunteer_id)}. {started ? "On the way to the donor." : "Ready to start."}
                      </p>
                      {!started ? (
                        <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`start-${m.id}`, async () => {
                          await api(`/api/donations/${m.donation_id}/start`, "POST", { volunteerId: m.volunteer_id });
                          setSelectedId(m.donation_id);
                          return `${nameOf(vols, m.volunteer_id)} is on the way to ${d ? donorName(d.donor_id) : "the donor"}. Confirm the pickup on arrival.`;
                        })}>
                          {busy === `start-${m.id}` ? "Starting\u2026" : "Start pickup"}
                        </button>
                      ) : (
                        <>
                          <CodeStep value={codes["p-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["p-" + m.id]: v })} />
                          <button className={`${btn} mt-3`} disabled={busy !== null || !(codes["p-" + m.id] ?? "").trim()} onClick={() => run(`pickup-${m.id}`, async () => {
                            const r = await api(`/api/donations/${m.donation_id}/pickup`, "POST", { volunteerId: m.volunteer_id, code: codes["p-" + m.id] });
                            setSelectedId(m.donation_id);
                            return `Pickup confirmed. ${hederaText(r.hedera)}`;
                          })}>
                            {busy === `pickup-${m.id}` ? "Recording on Hedera\u2026" : "Confirm pickup"}
                          </button>
                        </>
                      )}
                    </div>
                  );
                })}
              </>
            )}

            {role === "NGO" && (
              <>
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Incoming donations</h2>
                {missions.filter((m) => ms(m) === "PICKED_UP").length === 0 && (
                  <p className="mt-3 text-sm text-[#0E2237]/65">Nothing on the way yet. Deliveries appear here once a volunteer confirms pickup.</p>
                )}
                {missions.filter((m) => ms(m) === "PICKED_UP").map((m) => {
                  const d = donationOf(m.donation_id);
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#0F7B6C] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{nameOf(ngos, m.ngo_id)} receives {m.donation_id}</p>
                      <p className="text-sm text-[#0E2237]/70">
                        {d && donorName(d.donor_id)}, {d?.quantity_kg} kg, carried by {nameOf(vols, m.volunteer_id)}.
                      </p>
                      <label className="mt-3 block text-sm">Quantity received (kg)
                        <input type="number" min={1} className={`${input} mt-1 max-w-40`}
                          value={received[m.id] ?? String(d?.quantity_kg ?? "")}
                          onChange={(e) => setReceived({ ...received, [m.id]: e.target.value })} />
                      </label>
                      <CodeStep value={codes["d-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["d-" + m.id]: v })} />
                      {(() => {
                        const rs = receivedState(m);
                        if (!(rs.got > 0)) return <p className="mt-2 text-sm text-[#C0392B]">Enter the quantity received.</p>;
                        if (rs.got > rs.sent) return <p className="mt-2 text-sm text-[#C0392B]">The donor sent {rs.sent} kg. You cannot receive more than that.</p>;
                        if (rs.got < rs.sent) return <p className="mt-2 text-sm text-[#7A5200]">Only {rs.got} of {rs.sent} kg received. The {rs.sent - rs.got} kg difference will be recorded.</p>;
                        return null;
                      })()}
                      <button className={`${btn} mt-3`} disabled={busy !== null || !receivedState(m).valid || !(codes["d-" + m.id] ?? "").trim()} onClick={() => run(`deliver-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/deliver`, "POST", {
                          ngoId: m.ngo_id, quantityReceivedKg: Number(received[m.id] ?? d?.quantity_kg), code: codes["d-" + m.id],
                        });
                        setSelectedId(m.donation_id);
                        const rs = receivedState(m);
                        return rs.got < rs.sent
                          ? `Delivery confirmed: ${rs.got} of ${rs.sent} kg received, ${rs.sent - rs.got} kg difference recorded. ${hederaText(r.hedera)}`
                          : `Delivery confirmed. ${hederaText(r.hedera)}`;
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
          <section aria-label="Map and donations">
            <CityMap donors={donors} ngos={ngos} volunteers={vols} selectedDonorId={donorId} routes={volRoutes} preview={preview} onSelectDonor={selectDonor} />

            <h2 className="mt-10 font-[family-name:var(--font-heading)] text-xl font-semibold">Donations</h2>
            {donations.length === 0 ? (
              <p className="mt-3 text-sm text-[#0E2237]/65">No donations yet. Report surplus food as a donor to start.</p>
            ) : (
              <ul className="mt-3 divide-y divide-[#0E2237]/15 border-y border-[#0E2237]/15">
                {donations.map((d) => (
                  <li key={d.id}>
                    <button onClick={() => { setSelectedId(d.id); setMatch(null); }} aria-current={selectedId === d.id}
                      className={`flex w-full items-center justify-between gap-3 px-3 py-3 text-left hover:bg-white focus-visible:outline-2 focus-visible:outline-[#2A3EB1] ${selectedId === d.id ? "bg-white" : ""}`}>
                      <span>
                        <span className="font-medium">{d.id}</span>
                        <span className="ml-2 text-sm text-[#0E2237]/65">{d.quantity_kg} kg, {d.food_type.toLowerCase()}, {d.storage_requirement}</span>
                      </span>
                      <Badge status={d.status} />
                    </button>
                  </li>
                ))}
              </ul>
            )}

            {selected && (
              <div className="mt-8">
                <div className="mb-8 flex items-center gap-4">
                  <QrCode value={selected.id} />
                  <p className="max-w-xs text-sm text-[#0E2237]/70">
                    <span className="font-medium text-[#0E2237]">Donation label {selected.id}</span><br />
                    Put this QR code on the package. The volunteer scans it at pickup and the NGO scans it on arrival.
                  </p>
                </div>
                <h3 className="font-[family-name:var(--font-heading)] text-lg font-semibold">Hedera record for {selected.id}</h3>
                {events.length === 0 ? (
                  <p className="mt-2 text-sm text-[#0E2237]/65">No events yet.</p>
                ) : (
                  <ol className="mt-2 space-y-1 text-sm">
                    {events.map((e) => (
                      <li key={e.event_type} className="flex gap-2">
                        <span aria-hidden>{e.status === "CONFIRMED" ? "\u2713" : "\u2026"}</span>
                        <span>{EVENT_LABEL[e.event_type] ?? e.event_type}</span>
                        {e.status !== "CONFIRMED" && <span className="text-[#0E2237]/55">pending verification</span>}
                      </li>
                    ))}
                  </ol>
                )}

                {selected.status === "COMPLETED" && (
                  <div className="mt-6 max-w-sm border-2 border-dashed border-[#0F7B6C]/60 bg-white p-5">
                    <p className="font-[family-name:var(--font-heading)] text-xl font-semibold">Impact receipt</p>
                    <dl className="mt-3 space-y-1 text-sm">
                      <div className="flex justify-between"><dt>Donation</dt><dd>{selected.id}</dd></div>
                      <div className="flex justify-between"><dt>Food rescued</dt><dd>{rescuedKg} kg</dd></div>
                      {rescuedKg < Number(selected.quantity_kg) && (
                        <div className="flex justify-between text-[#7A5200]"><dt>Sent by donor</dt><dd>{selected.quantity_kg} kg ({Number(selected.quantity_kg) - rescuedKg} kg difference)</dd></div>
                      )}
                      <div className="flex justify-between"><dt>Meal equivalents (estimate)</dt><dd>&asymp; {Math.round(rescuedKg / KG_PER_MEAL)}</dd></div>
                      <div className="flex justify-between"><dt>Hedera events recorded</dt><dd>{events.filter((e) => e.status === "CONFIRMED").length}</dd></div>
                    </dl>
                    <p className="mt-3 text-xs text-[#0E2237]/55">Meals are estimated at {KG_PER_MEAL} kg per meal. This is an estimate, not a measurement.</p>
                    <Link href={`/verify/${selected.id}`} className={`${btn} mt-4 inline-block`}>Verify on Hedera</Link>
                  </div>
                )}
              </div>
            )}
          </section>
        </div>

        <section aria-label="Verified track record" className="mt-12 border-t border-[#0E2237]/15 pt-6">
          <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Verified track record</h2>
          <p className="text-sm text-[#0E2237]/65">Counted only from deliveries whose final event is confirmed on Hedera.</p>
          <div className="mt-4 grid gap-8 sm:grid-cols-3">
            {[
              { title: "Donors", list: rep.donors, unit: "verified donations", kg: true },
              { title: "NGOs", list: rep.ngos, unit: "successful deliveries", kg: false },
              { title: "Volunteers", list: rep.volunteers, unit: "successful pickups", kg: false },
            ].map((col) => (
              <div key={col.title}>
                <h3 className="text-sm font-medium">{col.title}</h3>
                {col.list.length === 0 ? (
                  <p className="mt-1 text-sm text-[#0E2237]/55">Nothing verified yet.</p>
                ) : (
                  <ul className="mt-1 space-y-1 text-sm">
                    {col.list.map((r) => (
                      <li key={r.id}><span className="font-medium">{r.name}</span>: {r.count} {col.unit}{col.kg ? `, ${r.kg} kg` : ""}</li>
                    ))}
                  </ul>
                )}
              </div>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}
'@

Write-File 'app/components/CityMap.tsx' @'
"use client";

import { useEffect, useRef, useState } from "react";
import { MAP, geoToPixel } from "@/lib/map/calibration";

type Actor = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Pt = { x: number; y: number };

// One entry per volunteer that has a mission. The stage says where that volunteer is heading.
export type MapRoute = { volunteerId: string; donorId: string; ngoId: string; stage: "assigned" | "donor" | "ngo" | "back"; highlight: boolean };
// AI recommendation shown before the mission is accepted (lines only, nobody moves yet).
export type MapPreview = { volunteerId: string; donorId: string; ngoId: string };

const COLOR = { donor: "#E4572E", ngo: "#0F7B6C", volunteer: "#2A3EB1" };
const R = 12;
const DURATION = 3500;
const halo = { paintOrder: "stroke" as const };

const pt = (a: Actor): Pt => geoToPixel(Number(a.latitude), Number(a.longitude));
const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

type Item = { r: MapRoute; v: Actor; home: Pt; donorP: Pt; ngoP: Pt; target: Pt };
type Anim = { from: Pt; to: Pt; t0: number; dur: number };

// Real map of Centre Urbain Nord. Dots come from database coordinates, so the map, the AI distances and the ETAs agree.
// Every volunteer is animated independently, so several missions can run at the same time.
export default function CityMap({
  donors, ngos, volunteers, selectedDonorId, routes, preview, onSelectDonor,
}: {
  donors: Actor[]; ngos: Actor[]; volunteers: Actor[]; selectedDonorId: string;
  routes: MapRoute[]; preview: MapPreview | null; onSelectDonor: (id: string) => void;
}) {
  const [focusId, setFocusId] = useState<string | null>(null);
  const [dots, setDots] = useState<Record<string, Pt>>({});
  const cur = useRef<Record<string, Pt>>({});
  const seenStage = useRef<Record<string, string>>({});
  const anims = useRef<Record<string, Anim>>({});
  const settled = useRef(false);
  const raf = useRef(0);

  const items: Item[] = routes.flatMap((r) => {
    const v = volunteers.find((x) => x.id === r.volunteerId);
    const d = donors.find((x) => x.id === r.donorId);
    const n = ngos.find((x) => x.id === r.ngoId);
    if (!v || !d || !n) return [];
    const home = pt(v), donorP = pt(d), ngoP = pt(n);
    return [{ r, v, home, donorP, ngoP, target: r.stage === "donor" ? donorP : r.stage === "ngo" ? ngoP : home }];
  });
  const dataReady = volunteers.length > 0 && donors.length > 0 && ngos.length > 0;
  const sig = `${dataReady}|` + items.map((i) => `${i.r.volunteerId}:${i.r.stage}:${Math.round(i.target.x)},${Math.round(i.target.y)}`).join(";");

  useEffect(() => {
    const now = performance.now();
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const alive = new Set<string>();

    for (const it of items) {
      const id = it.r.volunteerId;
      alive.add(id);
      const prev = seenStage.current[id];
      if (prev === undefined) {
        if (settled.current && it.r.stage === "donor") {
          // New mission accepted while the page is open: drive from home to the donor.
          cur.current[id] = it.home;
          anims.current[id] = { from: it.home, to: it.target, t0: now, dur: reduce ? 0 : DURATION };
        } else {
          cur.current[id] = it.target; // page just loaded: show the current situation without animation
          delete anims.current[id];
        }
      } else if (prev !== it.r.stage) {
        anims.current[id] = { from: cur.current[id] ?? it.home, to: it.target, t0: now, dur: reduce ? 0 : DURATION };
      }
      seenStage.current[id] = it.r.stage;
    }
    for (const id of Object.keys(seenStage.current)) {
      if (!alive.has(id)) { delete seenStage.current[id]; delete cur.current[id]; delete anims.current[id]; }
    }
    if (dataReady) settled.current = true;

    cancelAnimationFrame(raf.current);
    const tick = (t: number) => {
      let moving = false;
      for (const [id, a] of Object.entries(anims.current)) {
        const k = a.dur === 0 ? 1 : Math.min(1, (t - a.t0) / a.dur);
        const e = ease(k);
        cur.current[id] = { x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e };
        if (k >= 1) delete anims.current[id]; else moving = true;
      }
      setDots({ ...cur.current });
      if (moving) raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sig]);

  useEffect(() => () => cancelAnimationFrame(raf.current), []);

  const label = (p: Pt, text: string, side: "left" | "right", bold = false) => (
    <text x={p.x + (side === "right" ? R + 6 : -R - 6)} y={p.y + 6} textAnchor={side === "right" ? "start" : "end"}
      fontSize="20" fontWeight={bold ? 700 : 500} fill="#0E2237" stroke="#fff" strokeWidth="5" strokeLinejoin="round" style={halo}>
      {text}
    </text>
  );
  const tri = (p: Pt, r = R + 2) => `${p.x},${p.y - r} ${p.x + r},${p.y + r * 0.8} ${p.x - r},${p.y + r * 0.8}`;

  const pv = (() => {
    if (!preview) return null;
    const v = volunteers.find((x) => x.id === preview.volunteerId);
    const d = donors.find((x) => x.id === preview.donorId);
    const n = ngos.find((x) => x.id === preview.ngoId);
    return v && d && n ? { home: pt(v), donorP: pt(d), ngoP: pt(n), ngoId: n.id } : null;
  })();
  const routeByVol = new Map(items.map((i) => [i.r.volunteerId, i]));
  const hotNgos = new Set([...items.filter((i) => i.r.stage !== "back").map((i) => i.r.ngoId), ...(pv ? [pv.ngoId] : [])]);

  return (
    <figure>
      <svg viewBox={`0 0 ${MAP.width} ${MAP.height}`} className="w-full border border-[#0E2237]/15 bg-white"
        role="group" aria-label="Map of Centre Urbain Nord with donors, NGOs and volunteers">
        <image href={MAP.src} width={MAP.width} height={MAP.height} />

        {pv && (
          <g opacity="0.65">
            <line x1={pv.home.x} y1={pv.home.y} x2={pv.donorP.x} y2={pv.donorP.y} stroke={COLOR.volunteer} strokeWidth="4" strokeDasharray="10 8" />
            <line x1={pv.donorP.x} y1={pv.donorP.y} x2={pv.ngoP.x} y2={pv.ngoP.y} stroke={COLOR.ngo} strokeWidth="5" strokeDasharray="2 8" strokeLinecap="round" />
          </g>
        )}

        {items.filter((i) => i.r.stage !== "back").map((i) => (
          <g key={`line-${i.r.volunteerId}`} opacity={i.r.highlight ? 1 : 0.6}>
            {(i.r.stage === "assigned" || i.r.stage === "donor") && (
              <line x1={i.home.x} y1={i.home.y} x2={i.donorP.x} y2={i.donorP.y} stroke={COLOR.volunteer} strokeWidth="4" strokeDasharray="10 8" />
            )}
            <line x1={i.donorP.x} y1={i.donorP.y} x2={i.ngoP.x} y2={i.ngoP.y} stroke={COLOR.ngo} strokeWidth="5" />
          </g>
        ))}

        {ngos.map((n) => {
          const p = pt(n);
          const hot = hotNgos.has(n.id);
          return (
            <g key={n.id}>
              {hot && <rect x={p.x - R - 6} y={p.y - R - 6} width={2 * R + 12} height={2 * R + 12} fill="none" stroke={COLOR.ngo} strokeWidth="3" />}
              <rect x={p.x - R} y={p.y - R} width={2 * R} height={2 * R} fill={COLOR.ngo} stroke="#fff" strokeWidth="3" />
              {label(p, n.name, p.x > MAP.width * 0.78 ? "left" : "right", hot)}
            </g>
          );
        })}

        {volunteers.map((v) => {
          const it = routeByVol.get(v.id);
          const p = it ? (dots[v.id] ?? it.target) : pt(v);
          const off = !it && v.available === false;
          return (
            <g key={v.id}>
              <polygon points={tri(p, it ? R + 4 : R + 2)} fill={off ? "#fff" : COLOR.volunteer} stroke={off ? "#6B7280" : "#fff"} strokeWidth="3" />
              {label(p, off ? `${v.name} (unavailable)` : v.name, "left", !!it?.r.highlight)}
            </g>
          );
        })}

        {donors.map((d) => {
          const p = pt(d);
          const selected = d.id === selectedDonorId;
          return (
            <g key={d.id} role="button" tabIndex={0} aria-label={`Donate as ${d.name}`} aria-pressed={selected}
              className="cursor-pointer" style={{ outline: "none" }}
              onClick={() => onSelectDonor(d.id)}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onSelectDonor(d.id); } }}
              onFocus={() => setFocusId(d.id)} onBlur={() => setFocusId(null)}>
              <circle cx={p.x} cy={p.y} r="28" fill="transparent" />
              {selected && (
                <circle cx={p.x} cy={p.y} r={R + 6} fill="none" stroke={COLOR.donor} strokeWidth="3">
                  <animate attributeName="r" values={`${R + 5};${R + 11};${R + 5}`} dur="2s" repeatCount="indefinite" />
                </circle>
              )}
              {focusId === d.id && <circle cx={p.x} cy={p.y} r={R + 14} fill="none" stroke="#2A3EB1" strokeWidth="3" />}
              <circle cx={p.x} cy={p.y} r={R} fill={COLOR.donor} stroke="#fff" strokeWidth="3" />
              {label(p, d.name, "right", selected)}
            </g>
          );
        })}
      </svg>

      <figcaption className="mt-2 text-xs text-[#0E2237]/65">
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><circle cx="6" cy="6" r="5" fill={COLOR.donor} /></svg>Donor (click to donate)</span>
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><rect x="1" y="1" width="10" height="10" fill={COLOR.ngo} /></svg>NGO</span>
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><polygon points="6,1 11,10 1,10" fill={COLOR.volunteer} /></svg>Volunteer</span>
      </figcaption>
    </figure>
  );
}
'@

Write-File 'lib/missions.ts' @'
import { supabase } from "@/lib/db/supabase";
import { evaluate, type Donation, type Ngo, type Volunteer } from "@/lib/ai/scoring";
import { recordEvent } from "@/lib/hedera/events";
import { busyVolunteerIds } from "@/lib/busy";

async function nextMissionId(): Promise<string> {
  const { data } = await supabase.from("missions").select("id").order("id", { ascending: false }).limit(1);
  const last = data?.[0]?.id ? parseInt(data[0].id.replace("M-", ""), 10) : 0;
  return `M-${String(last + 1).padStart(3, "0")}`;
}

const getDonation = async (id: string) =>
  (await supabase.from("donations").select("*").eq("id", id).maybeSingle()).data;

const getMission = async (donationId: string) =>
  (await supabase.from("missions").select("*").eq("donation_id", donationId).maybeSingle()).data;

/** Atomic status change: only succeeds if the donation is still in the `from` status. */
async function moveStatus(id: string, from: string, to: string) {
  const { data } = await supabase.from("donations").update({ status: to }).eq("id", id).eq("status", from).select("id");
  return (data?.length ?? 0) === 1;
}

// ---------------------------------------------------------------- ACCEPT
export async function acceptMission(donationId: string, ngoId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  if (!donation) return { httpStatus: 404, error: "Donation not found" };
  if (donation.status !== "AVAILABLE")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected AVAILABLE` };

  // Never trust the client (or the AI): re-validate the pair against fresh database data.
  const [{ data: ngos }, { data: vols }] = await Promise.all([
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);
  const busy = await busyVolunteerIds();
  const crew = (vols ?? []).map((v) => (busy.has(v.id) ? { ...v, available: false, busy: true } : v)) as Volunteer[];
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], crew);
  const pair = ev.candidates.find((c) => c.ngo.id === ngoId && c.volunteer.id === volunteerId);
  if (!pair) return { httpStatus: 400, error: "This NGO + volunteer combination is not valid", rejected: ev.rejected };

  if (!(await moveStatus(donationId, "AVAILABLE", "PICKUP_PENDING")))
    return { httpStatus: 409, error: "Donation was just taken by another request" };

  const { data: mission, error } = await supabase
    .from("missions")
    .insert({
      id: await nextMissionId(),
      donation_id: donationId,
      ngo_id: ngoId,
      volunteer_id: volunteerId,
      match_score: pair.score,
      estimated_pickup_minutes: pair.estimatedPickupMinutes,
      estimated_delivery_minutes: pair.estimatedDeliveryMinutes,
      status: "PICKUP_PENDING",
      accepted_at: new Date().toISOString(),
    })
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "PICKUP_PENDING", "AVAILABLE"); // roll back
    return { httpStatus: 500, error: error.message };
  }

  // Sequential on purpose: keeps HCS sequence numbers in the same order as the workflow.
  const matched = await recordEvent(donationId, "NGO_MATCHED", { ngoId, volunteerId, matchScore: pair.score });
  const assigned = await recordEvent(donationId, "VOLUNTEER_ASSIGNED", { volunteerId });

  return { httpStatus: 201, mission, hedera: [matched, assigned] };
}

// ---------------------------------------------------------------- PICKUP
export async function confirmPickup(donationId: string, volunteerId: string, code: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKUP_PENDING")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKUP_PENDING` };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can confirm pickup" };
  if (mission.status !== "EN_ROUTE")
    return { httpStatus: 409, error: "Start the pickup first, then confirm it on arrival" };
  if (code.trim().toUpperCase() !== donationId)
    return { httpStatus: 400, error: "The scanned QR code does not match this donation" };

  if (!(await moveStatus(donationId, "PICKUP_PENDING", "PICKED_UP")))
    return { httpStatus: 409, error: "Pickup was already confirmed" };

  const { data: updated, error: upErr } = await supabase
    .from("missions")
    .update({ status: "PICKED_UP", pickup_at: new Date().toISOString() })
    .eq("id", mission.id)
    .select()
    .single();
  if (upErr) {
    await moveStatus(donationId, "PICKED_UP", "PICKUP_PENDING"); // undo, never leave donation and mission out of sync
    return { httpStatus: 500, error: `Could not update the mission: ${upErr.message}` };
  }

  const hedera = await recordEvent(donationId, "PICKUP_CONFIRMED", { confirmedBy: volunteerId, qrScanned: true });
  return { httpStatus: 200, mission: updated, hedera };
}

// ---------------------------------------------------------------- DELIVERY
export async function confirmDelivery(donationId: string, ngoId: string, quantityReceivedKg: number, code: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKED_UP")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKED_UP` };
  if (mission.ngo_id !== ngoId)
    return { httpStatus: 403, error: "Only the receiving NGO can confirm delivery" };
  if (code.trim().toUpperCase() !== donationId)
    return { httpStatus: 400, error: "The scanned QR code does not match this donation" };
  if (quantityReceivedKg > Number(donation.quantity_kg))
    return { httpStatus: 400, error: `Received quantity cannot exceed the donated ${donation.quantity_kg} kg` };

  if (!(await moveStatus(donationId, "PICKED_UP", "COMPLETED")))
    return { httpStatus: 409, error: "Delivery was already confirmed" };

  const { data: updated, error: upErr } = await supabase
    .from("missions")
    .update({ status: "COMPLETED", delivery_at: new Date().toISOString(), received_kg: quantityReceivedKg })
    .eq("id", mission.id)
    .select()
    .single();
  if (upErr) {
    await moveStatus(donationId, "COMPLETED", "PICKED_UP"); // undo, never leave donation and mission out of sync
    return { httpStatus: 500, error: `Could not update the mission: ${upErr.message}. Did you run supabase/phase10.sql?` };
  }

  const hedera = await recordEvent(donationId, "DELIVERY_CONFIRMED", { confirmedBy: ngoId, quantityReceivedKg, quantityDonatedKg: Number(donation.quantity_kg), qrScanned: true });
  return { httpStatus: 200, mission: updated, hedera };
}

// ---------------------------------------------------------------- START (the volunteer leaves for the donor)
export async function startPickup(donationId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKUP_PENDING" || mission.status !== "PICKUP_PENDING")
    return { httpStatus: 409, error: "This pickup was already started" };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can start the pickup" };

  const { data: updated, error } = await supabase
    .from("missions")
    .update({ status: "EN_ROUTE" })
    .eq("id", mission.id)
    .eq("status", "PICKUP_PENDING")
    .select()
    .single();
  if (error) return { httpStatus: 500, error: error.message };
  return { httpStatus: 200, mission: updated };
}
'@

Write-File 'lib/busy.ts' @'
import { supabase } from "@/lib/db/supabase";

/** Volunteers that have a mission in progress: the donation is accepted or picked up, and not archived. */
export async function busyVolunteerIds(): Promise<Set<string>> {
  const { data } = await supabase
    .from("missions")
    .select("volunteer_id, donations!inner(status, archived)")
    .in("donations.status", ["PICKUP_PENDING", "PICKED_UP"])
    .eq("donations.archived", false);
  return new Set((data ?? []).map((r) => r.volunteer_id as string));
}
'@

Write-File 'app/api/donations/[id]/start/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { startPickup } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ volunteerId: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await startPickup(id, body.data.volunteerId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'DEMO_SCRIPT.md' @'
# RescueMesh: 5-minute demo script

## Before you go on stage (2 minutes)
1. Start Ollama, then warm the model: `ollama run llama3.2:3b "hi"` (type /bye afterwards).
2. `npm run dev`, open http://localhost:3000. For a clean dashboard run: `Invoke-RestMethod -Method Post http://localhost:3000/api/demo/reset` then refresh.
3. Confirm the dashboard shows 0 / 0 / 0 / 0 and no "waiting for Hedera" banner.
4. Keep one browser tab on https://hashscan.io/testnet/topic/YOUR_TOPIC_ID as a backup.

## The story
| Time | Screen | Do | Say |
|---|---|---|---|
| 0:00 | Dashboard | Nothing | "Food surplus is not the problem. Coordinating it before it expires is." |
| 0:30 | Donor | Create donation (50 kg, refrigerated, 120 min) | "FreshMart reports surplus. The donation is recorded on Hedera." |
| 1:15 | Donor | Find rescue match | "The backend removes every NGO and volunteer that cannot do the job. The AI only chooses among safe options." |
| 2:00 | Donor | Read the reasons, click Accept mission | "Every number comes from the database. The AI writes the explanation, the backend validates the decision." |
| 2:30 | Volunteer | Start pickup, wait for arrival, enter the QR code, Confirm pickup | "Ahmed drives to the donor and picks it up. Next event on the ledger." |
| 3:15 | NGO | Confirm delivery (50 kg) | "Hope Kitchen confirms what it actually received." |
| 3:45 | Dashboard | Open the Impact receipt, click Verify on Hedera | "Now we don't ask you to trust our database." |
| 4:15 | Verify page | Point at the 5 checked steps | "Each row was read back from Hedera's public Mirror Node and its hash compared. AI decides who should act. Hedera proves what actually happened." |

## If something breaks
- **AI is slow or Ollama is down**: the match still appears and says "Deterministic fallback used". Say it out loud, it proves the backend is the authority.
- **Hedera is slow or down**: the app shows "Pending verification" and a Retry now button. Click it when the network is back.
- **Total failure**: open the HashScan tab and show the messages already on the topic.
- **Need a clean slate mid-demo**: run the reset command above in a second terminal, then refresh.

## Stretch features to point at
- **Route map** (right column, after the match): the volunteer to donor to NGO path from stored coordinates.
- **QR label** (right column): the volunteer and the NGO must enter or scan the code before Confirm is enabled. A wrong code is refused by the backend.
- **Verified track record** (bottom): donors, NGOs and volunteers ranked only by deliveries confirmed on Hedera. It survives a reset.
'@

# RescueMesh: writes the Phase 6 files to their exact paths.
# 1) Run supabase\phase6.sql in the Supabase SQL Editor FIRST.
# 2) Then, from the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase6.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}

Write-File 'lib/hedera/events.ts' @'
import { supabase } from "@/lib/db/supabase";
import { submitToTopic } from "./hcs";

export type EventType =
  | "DONATION_CREATED"
  | "NGO_MATCHED"
  | "VOLUNTEER_ASSIGNED"
  | "PICKUP_CONFIRMED"
  | "DELIVERY_CONFIRMED"
  | "IMPACT_VERIFIED";

/**
 * Records a critical event on Hedera (HCS) and logs the references in hedera_events.
 * - Idempotent: one event per (donationId, eventType). Already CONFIRMED -> returned as is.
 * - Never throws on Hedera failure: the row is saved as PENDING so the app keeps working.
 * - Only put non-personal data in `data` (it goes on a public ledger).
 */
export async function recordEvent(
  donationId: string,
  eventType: EventType,
  data: Record<string, unknown> = {}
) {
  const { data: existing } = await supabase
    .from("hedera_events")
    .select("*")
    .eq("donation_id", donationId)
    .eq("event_type", eventType)
    .maybeSingle();

  if (existing?.status === "CONFIRMED") return existing;

  const payload = {
    event: eventType,
    donationId,
    ...data,
    timestamp: new Date().toISOString(),
  };

  let row: Record<string, unknown>;
  try {
    const r = await submitToTopic(payload);
    row = {
      donation_id: donationId,
      event_type: eventType,
      hedera_topic_id: r.topicId,
      hedera_sequence_number: r.sequenceNumber,
      hedera_consensus_timestamp: r.consensusTimestamp,
      hedera_transaction_id: r.transactionId,
      payload_hash: r.payloadHash,
      payload,
      status: "CONFIRMED",
    };
  } catch (err) {
    console.error(`[hedera] ${eventType} failed for ${donationId}:`, err);
    // Keep the payload so the event can be re-sent later with its original content and time.
    row = { donation_id: donationId, event_type: eventType, payload, status: "PENDING" };
  }

  const { data: saved, error } = await supabase
    .from("hedera_events")
    .upsert(row, { onConflict: "donation_id,event_type" })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return saved;
}

export async function countPending() {
  const { count } = await supabase
    .from("hedera_events")
    .select("id", { count: "exact", head: true })
    .eq("status", "PENDING");
  return count ?? 0;
}

/** Re-sends every PENDING event, oldest first. Stops at the first failure (Hedera still down). */
export async function retryPending() {
  const { data: rows } = await supabase
    .from("hedera_events")
    .select("*")
    .eq("status", "PENDING")
    .order("id", { ascending: true });

  let confirmed = 0;
  for (const row of rows ?? []) {
    try {
      const payload = row.payload ?? { event: row.event_type, donationId: row.donation_id, timestamp: row.created_at };
      const r = await submitToTopic(payload);
      await supabase
        .from("hedera_events")
        .update({
          hedera_topic_id: r.topicId,
          hedera_sequence_number: r.sequenceNumber,
          hedera_consensus_timestamp: r.consensusTimestamp,
          hedera_transaction_id: r.transactionId,
          payload_hash: r.payloadHash,
          payload,
          status: "CONFIRMED",
        })
        .eq("id", row.id);
      confirmed++;
    } catch (err) {
      console.error(`[hedera] retry failed for event ${row.id}:`, err);
      break;
    }
  }
  const total = rows?.length ?? 0;
  return { retried: total, confirmed, stillPending: total - confirmed };
}
'@

Write-File 'lib/ai/match.ts' @'
import { supabase } from "@/lib/db/supabase";
import { evaluate, type Candidate, type Donation, type Ngo, type Volunteer } from "./scoring";
import { askCoordinator } from "./coordinator";

const MAX_LLM_ATTEMPTS = 2;

export async function findMatch(donationId: string) {
  const { data: donation } = await supabase.from("donations").select("*").eq("id", donationId).maybeSingle();
  if (!donation) return { error: "Donation not found", httpStatus: 404 as const };
  if (donation.status !== "AVAILABLE")
    return { error: `Donation is ${donation.status}, only AVAILABLE donations can be matched`, httpStatus: 409 as const };

  const [{ data: ngos }, { data: volunteers }] = await Promise.all([
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);

  // Everything the AI will see comes from the database + deterministic code.
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], (volunteers ?? []) as Volunteer[]);

  if (ev.candidates.length === 0) {
    return { httpStatus: 200 as const, matched: false, donationId, analysis: { ...ev.stats, minutesUntilExpiration: ev.minutesLeft }, rejected: ev.rejected };
  }

  const shortlist = ev.candidates.slice(0, 3);
  let chosen: Candidate = shortlist[0];
  let explanation = "";
  let source: "llm" | "deterministic-fallback" = "deterministic-fallback";

  for (let attempt = 0; attempt < MAX_LLM_ATTEMPTS; attempt++) {
    try {
      const d = await askCoordinator(
        {
          quantityKg: Number(donation.quantity_kg),
          foodType: donation.food_type,
          storageRequirement: donation.storage_requirement,
          minutesUntilExpiration: ev.minutesLeft,
        },
        shortlist
      );
      // Backend validation: the AI may only pick a pair that passed every hard constraint.
      const valid = shortlist.find((c) => c.ngo.id === d.ngoId && c.volunteer.id === d.volunteerId);
      if (!valid) throw new Error(`AI decision rejected: ${d.ngoId}+${d.volunteerId} is not a valid candidate`);
      chosen = valid;
      explanation = d.explanation;
      source = "llm";
      break;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[ai] attempt ${attempt + 1} failed:`, msg);
      // A second try only helps if the model answered badly. If Ollama is down or timed out, fall back now.
      const badAnswer = err instanceof SyntaxError || (err instanceof Error && err.name === "ZodError") || msg.startsWith("AI decision rejected");
      if (!badAnswer) break;
    }
  }

  if (source === "deterministic-fallback") {
    explanation =
      `I selected ${chosen.ngo.name} because it has enough capacity` +
      (donation.storage_requirement === "refrigerated" ? " and cold storage" : "") +
      `. ${chosen.volunteer.name} can transport the full donation and the estimated delivery is within the expiration window.`;
  }

  return {
    httpStatus: 200 as const,
    matched: true,
    donationId,
    recommendation: {
      ngoId: chosen.ngo.id,
      ngoName: chosen.ngo.name,
      ngoDistanceKm: chosen.donorToNgoKm,
      volunteerId: chosen.volunteer.id,
      volunteerName: chosen.volunteer.name,
      estimatedPickupMinutes: chosen.estimatedPickupMinutes,
      estimatedDeliveryMinutes: chosen.estimatedDeliveryMinutes,
      riskLevel: chosen.riskLevel,
      matchScore: chosen.score,
      reason: chosen.reason,
      explanation,
      source,
    },
    analysis: { ...ev.stats, minutesUntilExpiration: ev.minutesLeft },
    rejected: ev.rejected,
  };
}
'@

Write-File 'lib/ai/coordinator.ts' @'
import { z } from "zod";
import type { Candidate } from "./scoring";

const Decision = z.object({
  ngoId: z.string(),
  volunteerId: z.string(),
  explanation: z.string().min(1),
});

// Written by hand (works with any zod version) and sent to Ollama to force valid JSON.
const DECISION_SCHEMA = {
  type: "object",
  properties: {
    ngoId: { type: "string" },
    volunteerId: { type: "string" },
    explanation: { type: "string" },
  },
  required: ["ngoId", "volunteerId", "explanation"],
};

const SYSTEM_PROMPT = `You are RescueMesh Coordinator.
Your task is to select the safest and most efficient NGO and volunteer combination for a food rescue mission.

You MUST:
1. Only use the provided data.
2. Never invent availability, capacity, distance or times.
3. Choose ONLY one of the provided candidates: ngoId and volunteerId must belong to the same candidate.
4. Prioritize successful delivery before expiration.
5. Return JSON only, with keys ngoId, volunteerId, explanation.
6. explanation: at most 2 sentences, written in English, using only facts from the chosen candidate.
7. In the explanation, refer to the NGO and the volunteer by NAME (ngoName, volunteerName), never by ID, and do not compare with candidates you did not choose.

You are making a recommendation. The backend validates every hard constraint before executing the mission.`;

export async function askCoordinator(
  donation: { quantityKg: number; foodType: string; storageRequirement: string; minutesUntilExpiration: number },
  candidates: Candidate[]
) {
  const input = {
    donation,
    candidates: candidates.map((c) => ({
      ngoId: c.ngo.id,
      ngoName: c.ngo.name,
      ngoCapacityKg: c.ngo.storage_capacity_kg,
      ngoColdStorage: c.ngo.has_cold_storage,
      ngoCurrentDemand: c.ngo.current_demand,
      volunteerId: c.volunteer.id,
      volunteerName: c.volunteer.name,
      volunteerTransport: c.volunteer.transport_type,
      volunteerCapacityKg: c.volunteer.transport_capacity_kg,
      routeKm: Math.round((c.volunteerToDonorKm + c.donorToNgoKm) * 10) / 10,
      estimatedDeliveryMinutes: c.estimatedDeliveryMinutes,
      riskLevel: c.riskLevel,
      score: c.score,
    })),
  };

  const res = await fetch(`${process.env.OLLAMA_URL ?? "http://localhost:11434"}/api/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: AbortSignal.timeout(60_000), // first call can be slow while the model loads
    body: JSON.stringify({
      model: process.env.OLLAMA_MODEL ?? "llama3.2:3b",
      stream: false,
      keep_alive: "30m", // keep the model in memory between demo runs
      format: DECISION_SCHEMA,
      options: { temperature: 0 },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: JSON.stringify(input) },
      ],
    }),
  });
  if (!res.ok) throw new Error(`Ollama HTTP ${res.status}`);
  const data = await res.json();
  return Decision.parse(JSON.parse(data.message.content));
}
'@

Write-File 'app/api/donations/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { recordEvent } from "@/lib/hedera/events";

export const dynamic = "force-dynamic";

const CreateDonation = z.object({
  donorId: z.string().min(1),
  foodType: z.string().min(1),
  quantityKg: z.number().positive(),
  storageRequirement: z.enum(["ambient", "refrigerated"]),
  expiresInMinutes: z.number().int().positive().max(1440),
});

async function nextDonationId(): Promise<string> {
  const { data } = await supabase
    .from("donations")
    .select("id")
    .order("id", { ascending: false })
    .limit(1);
  const last = data?.[0]?.id ? parseInt(data[0].id.replace("RM-", ""), 10) : 0;
  return `RM-${String(last + 1).padStart(3, "0")}`;
}

export async function GET() {
  const { data, error } = await supabase
    .from("donations")
    .select("*")
    .eq("archived", false)
    .order("created_at", { ascending: false });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}

export async function POST(req: Request) {
  const parsed = CreateDonation.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });
  }
  const d = parsed.data;

  // The donor must exist and be a DONOR; pickup coordinates come from the database.
  const { data: donor } = await supabase
    .from("organizations")
    .select("id, latitude, longitude")
    .eq("id", d.donorId)
    .eq("type", "DONOR")
    .maybeSingle();
  if (!donor) return NextResponse.json({ error: "Unknown donor" }, { status: 400 });

  const id = await nextDonationId();
  const expiresAt = new Date(Date.now() + d.expiresInMinutes * 60_000).toISOString();

  const { data: donation, error } = await supabase
    .from("donations")
    .insert({
      id,
      donor_id: donor.id,
      food_type: d.foodType,
      quantity_kg: d.quantityKg,
      storage_requirement: d.storageRequirement,
      pickup_latitude: donor.latitude,
      pickup_longitude: donor.longitude,
      expires_at: expiresAt,
      status: "AVAILABLE",
    })
    .select()
    .single();
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // Public ledger: no personal data, only essential metadata.
  const hedera = await recordEvent(id, "DONATION_CREATED", {
    donorId: donor.id,
    foodType: d.foodType,
    quantityKg: d.quantityKg,
    status: "AVAILABLE",
  });

  return NextResponse.json({ donation, hedera }, { status: 201 });
}
'@

Write-File 'app/api/missions/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

export async function GET() {
  const { data, error } = await supabase
    .from("missions")
    .select("*, donations!inner(archived)")
    .eq("donations.archived", false)
    .order("created_at", { ascending: false });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
'@

Write-File 'app/api/demo/reset/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

// Demo reset = archive. Rows stay in the database (so old /verify links keep working and IDs never repeat),
// they just disappear from the dashboard. HCS messages can never be deleted, and we don't pretend they can.
export async function POST() {
  const { data, error } = await supabase
    .from("donations")
    .update({ archived: true })
    .eq("archived", false)
    .select("id");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ archived: data?.length ?? 0 });
}
'@

Write-File 'app/api/hedera/retry/route.ts' @'
import { NextResponse } from "next/server";
import { countPending, retryPending } from "@/lib/hedera/events";

export const dynamic = "force-dynamic";

export async function GET() {
  return NextResponse.json({ pending: await countPending() });
}

export async function POST() {
  return NextResponse.json(await retryPending());
}
'@

Write-File 'app/page.tsx' @'
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
          <button className={btnGhost} disabled={busy !== null} onClick={resetDemo}>{busy === "reset" ? "Resetting…" : "Reset demo"}</button>
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
              {busy === "retry" ? "Retrying…" : "Retry now"}
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
                    {busy === "create" ? "Recording on Hedera…" : "Create donation"}
                  </button>
                </div>

                {selected?.status === "AVAILABLE" && (
                  <div className="mt-8 border-t border-[#16231C]/15 pt-6">
                    <h2 className="font-serif text-xl font-semibold">Rescue match for {selected.id}</h2>
                    {!match && (
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run("match", async () => {
                        setMatch(await api(`/api/donations/${selected.id}/match`, "POST"));
                      })}>
                        {busy === "match" ? "AI Coordinator is working…" : "Find rescue match"}
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
                            {busy === "accept" ? "Recording on Hedera…" : "Accept mission"}
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
                        {busy === `pickup-${m.id}` ? "Recording on Hedera…" : "Confirm pickup"}
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
                        {busy === `deliver-${m.id}` ? "Recording on Hedera…" : "Confirm delivery"}
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
                        <span aria-hidden>{e.status === "CONFIRMED" ? "✓" : "…"}</span>
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
                      <div className="flex justify-between"><dt>Meal equivalents (estimate)</dt><dd>≈ {Math.round(Number(selected.quantity_kg) / KG_PER_MEAL)}</dd></div>
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

Write-File 'DEMO_SCRIPT.md' @'
# RescueMesh: 5-minute demo script

## Before you go on stage (2 minutes)
1. Start Ollama, then warm the model: `ollama run llama3.2:3b "hi"` (type /bye afterwards).
2. `npm run dev`, open http://localhost:3000, click **Reset demo**.
3. Confirm the dashboard shows 0 / 0 / 0 / 0 and no "waiting for Hedera" banner.
4. Keep one browser tab on https://hashscan.io/testnet/topic/YOUR_TOPIC_ID as a backup.

## The story
| Time | Screen | Do | Say |
|---|---|---|---|
| 0:00 | Dashboard | Nothing | "Food surplus is not the problem. Coordinating it before it expires is." |
| 0:30 | Donor | Create donation (50 kg, refrigerated, 120 min) | "FreshMart reports surplus. The donation is recorded on Hedera." |
| 1:15 | Donor | Find rescue match | "The backend removes every NGO and volunteer that cannot do the job. The AI only chooses among safe options." |
| 2:00 | Donor | Read the reasons, click Accept mission | "Every number comes from the database. The AI writes the explanation, the backend validates the decision." |
| 2:30 | Volunteer | Confirm pickup | "Ahmed picks it up. Second event on the ledger." |
| 3:15 | NGO | Confirm delivery (50 kg) | "Hope Kitchen confirms what it actually received." |
| 3:45 | Dashboard | Open the Impact receipt, click Verify on Hedera | "Now we don't ask you to trust our database." |
| 4:15 | Verify page | Point at the 5 checked steps | "Each row was read back from Hedera's public Mirror Node and its hash compared. AI decides who should act. Hedera proves what actually happened." |

## If something breaks
- **AI is slow or Ollama is down**: the match still appears and says "Deterministic fallback used". Say it out loud, it proves the backend is the authority.
- **Hedera is slow or down**: the app shows "Pending verification" and a Retry now button. Click it when the network is back.
- **Total failure**: open the HashScan tab and show the messages already on the topic.
- **Need a clean slate mid-demo**: Reset demo (takes one second).
'@

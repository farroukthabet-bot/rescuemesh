# RescueMesh: writes the Phase 7 (map, QR, reputation) files to their exact paths.
# 1) npm i qrcode jsqr   and   npm i -D @types/qrcode
# 2) From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase7.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}

Write-File 'lib/missions.ts' @'
import { supabase } from "@/lib/db/supabase";
import { evaluate, type Donation, type Ngo, type Volunteer } from "@/lib/ai/scoring";
import { recordEvent } from "@/lib/hedera/events";

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
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], (vols ?? []) as Volunteer[]);
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
  if (code.trim().toUpperCase() !== donationId)
    return { httpStatus: 400, error: "The scanned QR code does not match this donation" };

  if (!(await moveStatus(donationId, "PICKUP_PENDING", "PICKED_UP")))
    return { httpStatus: 409, error: "Pickup was already confirmed" };

  const { data: updated } = await supabase
    .from("missions")
    .update({ status: "PICKED_UP", pickup_at: new Date().toISOString() })
    .eq("id", mission.id)
    .select()
    .single();

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

  const { data: updated } = await supabase
    .from("missions")
    .update({ status: "COMPLETED", delivery_at: new Date().toISOString() })
    .eq("id", mission.id)
    .select()
    .single();

  const hedera = await recordEvent(donationId, "DELIVERY_CONFIRMED", { confirmedBy: ngoId, quantityReceivedKg, qrScanned: true });
  return { httpStatus: 200, mission: updated, hedera };
}
'@

Write-File 'app/api/donations/[id]/pickup/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { confirmPickup } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ volunteerId: z.string().min(1), code: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmPickup(id, body.data.volunteerId, body.data.code);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/deliver/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { confirmDelivery } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ ngoId: z.string().min(1), quantityReceivedKg: z.number().positive(), code: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmDelivery(id, body.data.ngoId, body.data.quantityReceivedKg, body.data.code);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/reputation/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

type Row = { donation_id: string; ngo_id: string; volunteer_id: string; donations: { donor_id: string; quantity_kg: number } };
type Rep = { id: string; name: string; count: number; kg: number };

// Reputation is computed only from deliveries whose DELIVERY_CONFIRMED event is CONFIRMED on Hedera.
// Archived (reset) donations still count: the ledger history does not disappear.
export async function GET() {
  const { data: ev } = await supabase
    .from("hedera_events")
    .select("donation_id")
    .eq("event_type", "DELIVERY_CONFIRMED")
    .eq("status", "CONFIRMED");
  const ids = (ev ?? []).map((e) => e.donation_id);

  const empty = { donors: [], ngos: [], volunteers: [] };
  if (ids.length === 0) return NextResponse.json(empty);

  const [{ data: rows }, { data: orgs }, { data: vols }] = await Promise.all([
    supabase.from("missions").select("donation_id, ngo_id, volunteer_id, donations!inner(donor_id, quantity_kg)").in("donation_id", ids).eq("status", "COMPLETED"),
    supabase.from("organizations").select("id, name"),
    supabase.from("volunteers").select("id, name"),
  ]);

  const names = new Map<string, string>([...(orgs ?? []), ...(vols ?? [])].map((x) => [x.id, x.name]));
  const tally = (pick: (r: Row) => string, withKg: boolean): Rep[] => {
    const m = new Map<string, Rep>();
    for (const r of (rows ?? []) as unknown as Row[]) {
      const id = pick(r);
      const cur = m.get(id) ?? { id, name: names.get(id) ?? id, count: 0, kg: 0 };
      cur.count += 1;
      if (withKg) cur.kg += Number(r.donations.quantity_kg);
      m.set(id, cur);
    }
    return [...m.values()].sort((a, b) => b.count - a.count);
  };

  return NextResponse.json({
    donors: tally((r) => r.donations.donor_id, true),
    ngos: tally((r) => r.ngo_id, false),
    volunteers: tally((r) => r.volunteer_id, false),
  });
}
'@

Write-File 'app/components/RouteMap.tsx' @'
import { haversineKm } from "@/lib/ai/scoring";

type P = { lat: number; lng: number; label: string };

const C = { volunteer: "#1F5FBF", donor: "#C77D0A", ngo: "#1F4D3A" };

// Schematic map drawn from database coordinates. No tiles, no API key, works offline.
export default function RouteMap({ donor, volunteer, ngo }: { donor: P; volunteer: P; ngo: P }) {
  const W = 440, H = 250, PAD = 48;
  const pts = [volunteer, donor, ngo];
  const midLat = (Math.min(...pts.map((p) => p.lat)) + Math.max(...pts.map((p) => p.lat))) / 2;
  const k = Math.cos((midLat * Math.PI) / 180);
  const xs = pts.map((p) => p.lng * k);
  const ys = pts.map((p) => -p.lat);
  const minX = Math.min(...xs), minY = Math.min(...ys);
  const spanX = Math.max(Math.max(...xs) - minX, 1e-6);
  const spanY = Math.max(Math.max(...ys) - minY, 1e-6);
  const scale = Math.min((W - 2 * PAD) / spanX, (H - 2 * PAD) / spanY);
  const ox = (W - spanX * scale) / 2, oy = (H - spanY * scale) / 2;
  const proj = (p: P) => ({ x: ox + (p.lng * k - minX) * scale, y: oy + (-p.lat - minY) * scale });

  const v = proj(volunteer), d = proj(donor), n = proj(ngo);
  const toDonor = haversineKm(volunteer.lat, volunteer.lng, donor.lat, donor.lng);
  const toNgo = haversineKm(donor.lat, donor.lng, ngo.lat, ngo.lng);

  return (
    <figure>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" className="w-full max-w-md border border-[#16231C]/15 bg-white"
        aria-label={`Route: ${volunteer.label} to ${donor.label}, then to ${ngo.label}`}>
        <defs>
          <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill="#16231C" fillOpacity="0.55" />
          </marker>
        </defs>
        <line x1={v.x} y1={v.y} x2={d.x} y2={d.y} stroke={C.volunteer} strokeWidth="2" strokeDasharray="5 4" markerEnd="url(#arrow)" />
        <line x1={d.x} y1={d.y} x2={n.x} y2={n.y} stroke={C.ngo} strokeWidth="2.5" markerEnd="url(#arrow)" />
        <circle cx={v.x} cy={v.y} r="8" fill={C.volunteer} />
        <circle cx={n.x} cy={n.y} r="8" fill={C.ngo} />
        <circle cx={d.x} cy={d.y} r="8" fill={C.donor} stroke="#fff" strokeWidth="2" />
        <text x={v.x} y={v.y - 14} textAnchor="middle" fontSize="12" fill="#16231C">{volunteer.label}</text>
        <text x={d.x} y={d.y + 24} textAnchor="middle" fontSize="12" fill="#16231C">{donor.label}</text>
        <text x={n.x} y={n.y + 24} textAnchor="middle" fontSize="12" fill="#16231C">{ngo.label}</text>
      </svg>
      <figcaption className="mt-2 text-xs text-[#16231C]/60">
        Volunteer to donor {toDonor.toFixed(1)} km (dashed), donor to NGO {toNgo.toFixed(1)} km. Schematic map from stored coordinates.
      </figcaption>
    </figure>
  );
}
'@

Write-File 'app/components/QrCode.tsx' @'
"use client";

import { useEffect, useState } from "react";
import QRCode from "qrcode";

export default function QrCode({ value, size = 132 }: { value: string; size?: number }) {
  const [src, setSrc] = useState("");
  useEffect(() => {
    QRCode.toDataURL(value, { width: size * 2, margin: 1, errorCorrectionLevel: "M" })
      .then(setSrc)
      .catch(() => setSrc(""));
  }, [value, size]);

  if (!src) return <div style={{ width: size, height: size }} className="bg-white" aria-hidden />;
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={src} width={size} height={size} alt={`QR code for donation ${value}`} className="border border-[#16231C]/20 bg-white" />;
}
'@

Write-File 'app/components/QrScanner.tsx' @'
"use client";

import { useEffect, useRef, useState } from "react";
import jsQR from "jsqr";

// Camera QR scanner (works on http://localhost). Falls back to a message if the camera is unavailable.
export default function QrScanner({ onResult }: { onResult: (text: string) => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const cb = useRef(onResult);
  cb.current = onResult;
  const [error, setError] = useState("");

  useEffect(() => {
    let stopped = false;
    let raf = 0;
    let stream: MediaStream | undefined;
    const canvas = document.createElement("canvas");

    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
        const v = video.current;
        if (!v) return;
        v.srcObject = stream;
        await v.play();
        const tick = () => {
          if (stopped) return;
          if (v.videoWidth) {
            canvas.width = v.videoWidth;
            canvas.height = v.videoHeight;
            const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
            ctx.drawImage(v, 0, 0);
            const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
            const code = jsQR(img.data, img.width, img.height);
            if (code?.data) { cb.current(code.data); return; }
          }
          raf = requestAnimationFrame(tick);
        };
        tick();
      } catch {
        setError("Camera not available. Type the code instead.");
      }
    })();

    return () => {
      stopped = true;
      cancelAnimationFrame(raf);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  return (
    <div className="mt-2">
      {error ? <p className="text-sm text-[#B3261E]">{error}</p> : <video ref={video} playsInline muted className="w-full max-w-xs border border-[#16231C]/20" />}
    </div>
  );
}
'@

Write-File 'app/components/CodeStep.tsx' @'
"use client";

import { useState } from "react";
import QrScanner from "./QrScanner";

export default function CodeStep({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [scanning, setScanning] = useState(false);
  return (
    <div className="mt-3">
      <label className="block text-sm">
        Donation code from the QR label
        <input
          className="mt-1 block w-full max-w-48 rounded-md border border-[#16231C]/25 bg-white px-3 py-2 text-sm focus-visible:outline-2 focus-visible:outline-[#1F5FBF]"
          value={value}
          placeholder="e.g. RM-003"
          onChange={(e) => onChange(e.target.value)}
        />
      </label>
      <button type="button" className="mt-2 text-sm text-[#1F5FBF] underline underline-offset-2" onClick={() => setScanning((s) => !s)}>
        {scanning ? "Close camera" : "Scan with camera"}
      </button>
      {scanning && <QrScanner onResult={(t) => { onChange(t.trim()); setScanning(false); }} />}
    </div>
  );
}
'@

Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import CodeStep from "./components/CodeStep";
import QrCode from "./components/QrCode";
import RouteMap from "./components/RouteMap";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string; pickup_latitude: number; pickup_longitude: number };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string };
type Named = { id: string; name: string; latitude: number; longitude: number };
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
  const [rep, setRep] = useState<{ donors: Rep[]; ngos: Rep[]; volunteers: Rep[] }>({ donors: [], ngos: [], volunteers: [] });
  const [codes, setCodes] = useState<Record<string, string>>({});
  const [received, setReceived] = useState<Record<string, string>>({});
  const [form, setForm] = useState({ foodType: "Prepared meals", quantityKg: "50", storage: "refrigerated", minutes: "120" });

  const load = useCallback(async () => {
    const [d, m, n, v, p, r] = await Promise.all([
      api("/api/donations"), api("/api/missions"), api("/api/ngos"), api("/api/volunteers"), api("/api/hedera/retry"), api("/api/reputation"),
    ]);
    setDonations(d); setMissions(m); setNgos(n); setVols(v); setPending(p.pending); setRep(r);
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

  // Map: uses the accepted mission, or the AI recommendation while the donation is still available.
  const selMission = selected ? missions.find((m) => m.donation_id === selected.id) : undefined;
  const selRec = selected?.status === "AVAILABLE" ? match?.recommendation : undefined;
  const mapNgo = ngos.find((n) => n.id === (selMission?.ngo_id ?? selRec?.ngoId));
  const mapVol = vols.find((v) => v.id === (selMission?.volunteer_id ?? selRec?.volunteerId));
  const mapPoints = selected && mapNgo && mapVol ? {
    donor: { lat: Number(selected.pickup_latitude), lng: Number(selected.pickup_longitude), label: DONORS[selected.donor_id] ?? "Donor" },
    volunteer: { lat: Number(mapVol.latitude), lng: Number(mapVol.longitude), label: mapVol.name },
    ngo: { lat: Number(mapNgo.latitude), lng: Number(mapNgo.longitude), label: mapNgo.name },
  } : null;
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
                      <CodeStep value={codes["p-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["p-" + m.id]: v })} />
                      <button className={`${btn} mt-3`} disabled={busy !== null || !(codes["p-" + m.id] ?? "").trim()} onClick={() => run(`pickup-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/pickup`, "POST", { volunteerId: m.volunteer_id, code: codes["p-" + m.id] });
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
                      <CodeStep value={codes["d-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["d-" + m.id]: v })} />
                      <button className={`${btn} mt-3`} disabled={busy !== null || !(codes["d-" + m.id] ?? "").trim()} onClick={() => run(`deliver-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/deliver`, "POST", {
                          ngoId: m.ngo_id, quantityReceivedKg: Number(received[m.id] ?? d?.quantity_kg), code: codes["d-" + m.id],
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
                {mapPoints && (
                  <div className="mb-8">
                    <h3 className="mb-2 font-serif text-lg font-semibold">Route</h3>
                    <RouteMap {...mapPoints} />
                  </div>
                )}
                <div className="mb-8 flex items-center gap-4">
                  <QrCode value={selected.id} />
                  <p className="max-w-xs text-sm text-[#16231C]/70">
                    <span className="font-medium text-[#16231C]">Donation label {selected.id}</span><br />
                    Put this QR code on the package. The volunteer scans it at pickup and the NGO scans it on arrival.
                  </p>
                </div>
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

        <section aria-label="Verified track record" className="mt-12 border-t border-[#16231C]/15 pt-6">
          <h2 className="font-serif text-xl font-semibold">Verified track record</h2>
          <p className="text-sm text-[#16231C]/65">Counted only from deliveries whose final event is confirmed on Hedera.</p>
          <div className="mt-4 grid gap-8 sm:grid-cols-3">
            {[
              { title: "Donors", list: rep.donors, unit: "verified donations", kg: true },
              { title: "NGOs", list: rep.ngos, unit: "successful deliveries", kg: false },
              { title: "Volunteers", list: rep.volunteers, unit: "successful pickups", kg: false },
            ].map((col) => (
              <div key={col.title}>
                <h3 className="text-sm font-medium">{col.title}</h3>
                {col.list.length === 0 ? (
                  <p className="mt-1 text-sm text-[#16231C]/55">Nothing verified yet.</p>
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

## Stretch features to point at
- **Route map** (right column, after the match): the volunteer to donor to NGO path from stored coordinates.
- **QR label** (right column): the volunteer and the NGO must enter or scan the code before Confirm is enabled. A wrong code is refused by the backend.
- **Verified track record** (bottom): donors, NGOs and volunteers ranked only by deliveries confirmed on Hedera. It survives Reset demo.
'@

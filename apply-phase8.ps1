# RescueMesh: writes the Phase 8 (real CUN map) files to their exact paths.
# Before running: 1) save public\cun-map.jpg  2) run supabase\phase8.sql in Supabase.
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase8.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}

Write-File 'lib/map/calibration.ts' @'
// Pixel <-> GPS conversion for /public/cun-map.jpg (Google Maps screenshot, north up).
// Fitted by least squares on 6 control points: 4 donor locations and 2 roundabouts.
// Worst residual is about 5 px (about 7 m), good enough for a schematic demo map.
export const MAP = {
  src: "/cun-map.jpg",
  width: 1136,
  height: 943,
  AX: 62751.89783561566, BX: -639111.4473500763,
  CY: -77407.56945786755, DY: 2852580.5698341606,
};

export function geoToPixel(lat: number, lng: number) {
  return { x: MAP.AX * lng + MAP.BX, y: MAP.CY * lat + MAP.DY };
}

export function pixelToGeo(x: number, y: number) {
  return { lat: (y - MAP.DY) / MAP.CY, lng: (x - MAP.BX) / MAP.AX };
}
'@

Write-File 'lib/ai/scoring.ts' @'
// Deterministic part of the matching engine: hard constraints, ETA, risk, scoring.
// The LLM never computes any of these numbers, it only receives them.

export const MAX_ROUTE_KM = 3;    // volunteer -> donor -> NGO route limit (sized for the Centre Urbain Nord demo area)
export const SPEED_KMH = 25;      // assumed average urban speed
export const HANDLING_MIN = 5;    // loading time, and unloading time

export type Donation = {
  id: string;
  food_type: string;
  quantity_kg: number;
  storage_requirement: "ambient" | "refrigerated";
  pickup_latitude: number;
  pickup_longitude: number;
  expires_at: string;
};
export type Ngo = {
  id: string; name: string; latitude: number; longitude: number;
  storage_capacity_kg: number; has_cold_storage: boolean; current_demand: string | null;
};
export type Volunteer = {
  id: string; name: string; latitude: number; longitude: number;
  transport_type: string; transport_capacity_kg: number; has_cold_storage: boolean; available: boolean;
};

export type Candidate = {
  ngo: Ngo;
  volunteer: Volunteer;
  score: number; // 0-100
  volunteerToDonorKm: number;
  donorToNgoKm: number;
  estimatedPickupMinutes: number;
  estimatedDeliveryMinutes: number;
  riskLevel: "LOW" | "MEDIUM" | "HIGH";
  reason: string[];
};
export type Rejection = { type: "ngo" | "volunteer" | "pair"; id: string; name: string; reasons: string[] };

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number) {
  const R = 6371, rad = (d: number) => (d * Math.PI) / 180;
  const a =
    Math.sin(rad(lat2 - lat1) / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lon2 - lon1) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const round1 = (n: number) => Math.round(n * 10) / 10;
const clamp01 = (n: number) => Math.max(0, Math.min(1, n));

export function evaluate(donation: Donation, ngos: Ngo[], volunteers: Volunteer[], now = Date.now()) {
  const qty = Number(donation.quantity_kg);
  const minutesLeft = (Date.parse(donation.expires_at) - now) / 60000;
  const needCold = donation.storage_requirement === "refrigerated";
  const rejected: Rejection[] = [];

  // 1) Hard constraints per NGO
  const okNgos = ngos.filter((n) => {
    const r: string[] = [];
    if (Number(n.storage_capacity_kg) < qty) r.push(`Capacity ${n.storage_capacity_kg} kg is below ${qty} kg`);
    if (needCold && !n.has_cold_storage) r.push("No cold storage");
    if (r.length) rejected.push({ type: "ngo", id: n.id, name: n.name, reasons: r });
    return r.length === 0;
  });

  // 2) Hard constraints per volunteer
  const okVols = volunteers.filter((v) => {
    const r: string[] = [];
    if (!v.available) r.push("Not available");
    if (Number(v.transport_capacity_kg) < qty) r.push(`Transport capacity ${v.transport_capacity_kg} kg is below ${qty} kg`);
    if (needCold && !v.has_cold_storage) r.push("No refrigerated transport");
    if (r.length) rejected.push({ type: "volunteer", id: v.id, name: v.name, reasons: r });
    return r.length === 0;
  });

  // 3) Pair constraints (route length, arrival before expiration) + scoring
  const candidates: Candidate[] = [];
  for (const v of okVols) {
    for (const n of okNgos) {
      const vToD = haversineKm(v.latitude, v.longitude, donation.pickup_latitude, donation.pickup_longitude);
      const dToN = haversineKm(donation.pickup_latitude, donation.pickup_longitude, n.latitude, n.longitude);
      const pickupMin = Math.round((vToD / SPEED_KMH) * 60) + HANDLING_MIN;
      const deliveryMin = pickupMin + Math.round((dToN / SPEED_KMH) * 60) + HANDLING_MIN;

      const pairReasons: string[] = [];
      if (vToD + dToN > MAX_ROUTE_KM) pairReasons.push(`Route of ${round1(vToD + dToN)} km exceeds ${MAX_ROUTE_KM} km`);
      if (deliveryMin >= minutesLeft) pairReasons.push(`Delivery in ${deliveryMin} min is not before expiration (${Math.floor(minutesLeft)} min left)`);
      if (pairReasons.length) {
        rejected.push({ type: "pair", id: `${n.id}+${v.id}`, name: `${n.name} + ${v.name}`, reasons: pairReasons });
        continue;
      }

      const margin = (minutesLeft - deliveryMin) / minutesLeft;
      const proximity = 1 - clamp01((vToD + dToN) / MAX_ROUTE_KM);
      const capacityFit =
        (clamp01(Number(n.storage_capacity_kg) / (qty * 1.5)) + clamp01(Number(v.transport_capacity_kg) / (qty * 1.5))) / 2;
      const expirationSafety = clamp01(margin);
      const storageCompat = 1; // hard constraints already guarantee compatibility
      const score = Math.round(100 * (0.3 * proximity + 0.25 * capacityFit + 0.25 * expirationSafety + 0.2 * storageCompat));

      const reason = [
        `${n.name} has ${n.storage_capacity_kg} kg capacity for a ${qty} kg donation`,
        ...(needCold ? [`${n.name} has cold storage and ${v.name} has refrigerated transport`] : []),
        `${v.name} can carry up to ${v.transport_capacity_kg} kg by ${v.transport_type.toLowerCase()}`,
        `Estimated delivery in ${deliveryMin} min, ${Math.floor(minutesLeft - deliveryMin)} min before expiration`,
      ];

      candidates.push({
        ngo: n, volunteer: v, score,
        volunteerToDonorKm: round1(vToD), donorToNgoKm: round1(dToN),
        estimatedPickupMinutes: pickupMin, estimatedDeliveryMinutes: deliveryMin,
        riskLevel: margin >= 0.5 ? "LOW" : margin >= 0.2 ? "MEDIUM" : "HIGH",
        reason,
      });
    }
  }
  candidates.sort((a, b) => b.score - a.score);

  return {
    candidates, rejected,
    minutesLeft: Math.floor(minutesLeft),
    stats: {
      ngosConsidered: ngos.length, volunteersConsidered: volunteers.length,
      ngosEligible: okNgos.length, volunteersEligible: okVols.length,
    },
  };
}
'@

Write-File 'app/components/CityMap.tsx' @'
"use client";

import { useEffect, useRef, useState } from "react";
import { MAP, geoToPixel } from "@/lib/map/calibration";

type Actor = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Pt = { x: number; y: number };
export type MapRoute = { key: string; donorId: string; ngoId: string; volunteerId: string; stage: "home" | "donor" | "ngo" };

const COLOR = { donor: "#C77D0A", ngo: "#1F4D3A", volunteer: "#1F5FBF" };
const R = 12;
const halo = { paintOrder: "stroke" as const };

const pt = (a: Actor): Pt => geoToPixel(Number(a.latitude), Number(a.longitude));

// Real map of Centre Urbain Nord. Dots come from database coordinates, so the map, the AI distances and the ETAs agree.
export default function CityMap({
  donors, ngos, volunteers, selectedDonorId, route, onSelectDonor,
}: {
  donors: Actor[]; ngos: Actor[]; volunteers: Actor[];
  selectedDonorId: string; route: MapRoute | null; onSelectDonor: (id: string) => void;
}) {
  const [focusId, setFocusId] = useState<string | null>(null);
  const [dot, setDot] = useState<Pt | null>(null);
  const pos = useRef<Pt | null>(null);
  const lastKey = useRef<string | null>(null);
  const raf = useRef(0);

  const rDonor = route ? donors.find((d) => d.id === route.donorId) : undefined;
  const rNgo = route ? ngos.find((n) => n.id === route.ngoId) : undefined;
  const rVol = route ? volunteers.find((v) => v.id === route.volunteerId) : undefined;
  const ready = !!(route && rDonor && rNgo && rVol);
  const home = rVol ? pt(rVol) : { x: 0, y: 0 };
  const donorP = rDonor ? pt(rDonor) : { x: 0, y: 0 };
  const ngoP = rNgo ? pt(rNgo) : { x: 0, y: 0 };
  const stage = route?.stage;
  const key = route?.key;

  // Volunteer animation: home -> donor after the mission is accepted, donor -> NGO after pickup.
  useEffect(() => {
    cancelAnimationFrame(raf.current);
    if (!ready || !stage || !key) { pos.current = null; lastKey.current = null; setDot(null); return; }
    const target = stage === "home" ? home : stage === "donor" ? donorP : ngoP;
    const from = lastKey.current === key && pos.current ? pos.current : target; // no animation on first display
    lastKey.current = key;
    const reduce = typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const dur = reduce ? 0 : 3500;
    const t0 = performance.now();
    const step = (now: number) => {
      const t = dur === 0 ? 1 : Math.min(1, (now - t0) / dur);
      const e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
      const p = { x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e };
      pos.current = p;
      setDot(p);
      if (t < 1) raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, key, stage, route?.volunteerId, home.x, home.y, donorP.x, donorP.y, ngoP.x, ngoP.y]);

  const label = (p: Pt, text: string, side: "left" | "right", bold = false) => (
    <text x={p.x + (side === "right" ? R + 6 : -R - 6)} y={p.y + 6} textAnchor={side === "right" ? "start" : "end"}
      fontSize="20" fontWeight={bold ? 700 : 500} fill="#16231C" stroke="#fff" strokeWidth="5" strokeLinejoin="round" style={halo}>
      {text}
    </text>
  );
  const tri = (p: Pt, r = R + 2) => `${p.x},${p.y - r} ${p.x + r},${p.y + r * 0.8} ${p.x - r},${p.y + r * 0.8}`;

  return (
    <figure>
      <svg viewBox={`0 0 ${MAP.width} ${MAP.height}`} className="w-full border border-[#16231C]/15 bg-white"
        role="group" aria-label="Map of Centre Urbain Nord with donors, NGOs and volunteers">
        <image href={MAP.src} width={MAP.width} height={MAP.height} />
        <defs>
          <marker id="cm-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill="#16231C" fillOpacity="0.7" />
          </marker>
        </defs>

        {ready && (
          <>
            <line x1={home.x} y1={home.y} x2={donorP.x} y2={donorP.y} stroke={COLOR.volunteer} strokeWidth="4" strokeDasharray="10 8" markerEnd="url(#cm-arrow)" />
            <line x1={donorP.x} y1={donorP.y} x2={ngoP.x} y2={ngoP.y} stroke={COLOR.ngo} strokeWidth="5" markerEnd="url(#cm-arrow)" />
          </>
        )}

        {ngos.map((n) => {
          const p = pt(n);
          const hot = route?.ngoId === n.id;
          return (
            <g key={n.id}>
              {hot && <rect x={p.x - R - 6} y={p.y - R - 6} width={2 * R + 12} height={2 * R + 12} fill="none" stroke={COLOR.ngo} strokeWidth="3" />}
              <rect x={p.x - R} y={p.y - R} width={2 * R} height={2 * R} fill={COLOR.ngo} stroke="#fff" strokeWidth="3" />
              {label(p, n.name, p.x > MAP.width * 0.78 ? "left" : "right", hot)}
            </g>
          );
        })}

        {volunteers.map((v) => {
          if (ready && route?.volunteerId === v.id) return null; // drawn as the moving dot below
          const p = pt(v);
          const off = v.available === false;
          return (
            <g key={v.id}>
              <polygon points={tri(p)} fill={off ? "#fff" : COLOR.volunteer} stroke={off ? "#6B7280" : "#fff"} strokeWidth="3" />
              {label(p, off ? `${v.name} (unavailable)` : v.name, "left")}
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
              {focusId === d.id && <circle cx={p.x} cy={p.y} r={R + 14} fill="none" stroke="#1F5FBF" strokeWidth="3" />}
              <circle cx={p.x} cy={p.y} r={R} fill={COLOR.donor} stroke="#fff" strokeWidth="3" />
              {label(p, d.name, "right", selected)}
            </g>
          );
        })}

        {ready && dot && rVol && (
          <g>
            <polygon points={tri(dot, R + 4)} fill={COLOR.volunteer} stroke="#fff" strokeWidth="3" />
            {label(dot, rVol.name, "left", true)}
          </g>
        )}
      </svg>

      <figcaption className="mt-2 text-xs text-[#16231C]/65">
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><circle cx="6" cy="6" r="5" fill={COLOR.donor} /></svg>Donor (click to donate)</span>
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><rect x="1" y="1" width="10" height="10" fill={COLOR.ngo} /></svg>NGO</span>
        <span className="mr-4 inline-flex items-center gap-1"><svg width="12" height="12" aria-hidden><polygon points="6,1 11,10 1,10" fill={COLOR.volunteer} /></svg>Volunteer</span>
        <br />
        Map data (c) Google. Donors are real places used as simulated demo data. NGOs and volunteers are fictional.
      </figcaption>
    </figure>
  );
}
'@

Write-File 'app/api/donors/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

export async function GET() {
  const { data, error } = await supabase.from("organizations").select("*").eq("type", "DONOR").order("id");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
'@

Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import CodeStep from "./components/CodeStep";
import QrCode from "./components/QrCode";
import CityMap from "./components/CityMap";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string; pickup_latitude: number; pickup_longitude: number };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string };
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

  async function resetDemo() {
    if (!window.confirm("Reset the demo? Donations and missions disappear from the dashboard. Hedera records stay on the public ledger.")) return;
    await run("reset", async () => {
      await api("/api/demo/reset", "POST");
      setSelectedId(null); setMatch(null); setEvents([]);
      return "Demo reset. Earlier donations stay verifiable through their verify links.";
    });
  }

  const donorName = (id: string) => donors.find((x) => x.id === id)?.name ?? id;
  function selectDonor(id: string) {
    setRole("Donor"); setDonorId(id); setSelectedId(null); setMatch(null);
    const preset = DONOR_PRESETS[id];
    if (preset) setForm((f) => ({ ...f, ...preset }));
  }

  const selected = donations.find((d) => d.id === selectedId) ?? null;

  // Map: uses the accepted mission, or the AI recommendation while the donation is still available.
  const selMission = selected ? missions.find((m) => m.donation_id === selected.id) : undefined;
  const selRec = selected?.status === "AVAILABLE" ? match?.recommendation : undefined;
  const routeNgoId = selMission?.ngo_id ?? selRec?.ngoId;
  const routeVolId = selMission?.volunteer_id ?? selRec?.volunteerId;
  const route = selected && routeNgoId && routeVolId ? {
    key: selected.id, donorId: selected.donor_id, ngoId: routeNgoId, volunteerId: routeVolId,
    stage: (!selMission ? "home" : selMission.status === "PICKUP_PENDING" ? "donor" : "ngo") as "home" | "donor" | "ngo",
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

  if (!mounted) return <main className="min-h-screen bg-[#F2F4EF]" />; // render the UI only in the browser: extensions inject attributes into server HTML

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
                <p className="mb-4 text-sm text-[#16231C]/65">Donating as <strong>{donorName(donorId)}</strong>. Click a donor on the map to switch.</p>
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
                        {d && donorName(d.donor_id)}: {d?.quantity_kg} kg of {d?.food_type.toLowerCase()}. Driver: {nameOf(vols, m.volunteer_id)}. Pickup pending.
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
                        {d && donorName(d.donor_id)}, {d?.quantity_kg} kg, carried by {nameOf(vols, m.volunteer_id)}.
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
          <section aria-label="Map and donations">
            <CityMap donors={donors} ngos={ngos} volunteers={vols} selectedDonorId={donorId} route={route} onSelectDonor={selectDonor} />

            <h2 className="mt-10 font-serif text-xl font-semibold">Donations</h2>
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


if (-not (Test-Path (Join-Path $root "public\cun-map.jpg"))) { Write-Host "WARNING: public\cun-map.jpg is missing. Save the map image there." -ForegroundColor Yellow }

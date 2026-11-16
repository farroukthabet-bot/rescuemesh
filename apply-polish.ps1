# RescueMesh: new logo, richer track record, off-duty volunteers shown on the map.
# No SQL, no new packages.
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-polish.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}








Write-File 'app/components/Logo.tsx' @'
// RescueMesh mark: three actors (donor, NGO, volunteer) linked in a small mesh around the shared record.
export default function Logo({ size = 40, className = "" }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 40 40" role="img" aria-label="RescueMesh" className={className}>
      <defs>
        <linearGradient id="rm-logo-g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#B5A8FF" />
          <stop offset="1" stopColor="#6A58E8" />
        </linearGradient>
      </defs>
      <rect width="40" height="40" rx="11" fill="url(#rm-logo-g)" />
      <g stroke="#0D0C16" strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M20 9 10.5 27.5h19z" strokeWidth="2.2" />
        <path d="M20 21V9M20 21l-9.5 6.5M20 21l9.5 6.5" strokeWidth="1.4" strokeOpacity="0.7" />
      </g>
      <circle cx="20" cy="9" r="4.2" fill="#FF7A66" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="10.5" cy="27.5" r="4.2" fill="#34D3A0" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="29.5" cy="27.5" r="4.2" fill="#ECEAF8" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="20" cy="21" r="2.3" fill="#0D0C16" />
    </svg>
  );
}
'@

Write-File 'app/icon.svg' @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">
      <defs>
        <linearGradient id="rm-logo-g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#B5A8FF" />
          <stop offset="1" stop-color="#6A58E8" />
        </linearGradient>
      </defs>
      <rect width="40" height="40" rx="11" fill="url(#rm-logo-g)" />
      <g stroke="#0D0C16" stroke-linecap="round" stroke-linejoin="round" fill="none">
        <path d="M20 9 10.5 27.5h19z" stroke-width="2.2" />
        <path d="M20 21V9M20 21l-9.5 6.5M20 21l9.5 6.5" stroke-width="1.4" stroke-opacity="0.7" />
      </g>
      <circle cx="20" cy="9" r="4.2" fill="#FF7A66" stroke="#0D0C16" stroke-width="2" />
      <circle cx="10.5" cy="27.5" r="4.2" fill="#34D3A0" stroke="#0D0C16" stroke-width="2" />
      <circle cx="29.5" cy="27.5" r="4.2" fill="#ECEAF8" stroke="#0D0C16" stroke-width="2" />
      <circle cx="20" cy="21" r="2.3" fill="#0D0C16" />
</svg>
'@

Write-File 'app/components/CityMap.tsx' @'
"use client";

import { useEffect, useRef, useState } from "react";
import { MAP, geoToPixel, pixelToGeo } from "@/lib/map/calibration";

type Actor = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Pt = { x: number; y: number };

// One entry per volunteer that has a mission. The stage says where that volunteer is heading.
export type MapRoute = { volunteerId: string; donorId: string; ngoId: string; stage: "assigned" | "donor" | "ngo" | "back"; highlight: boolean };
// AI recommendation shown before the mission is accepted (lines only, nobody moves yet).
export type MapPreview = { volunteerId: string; donorId: string; ngoId: string };

const COLOR = { donor: "#FF7A66", ngo: "#34D3A0", volunteer: "#A594FF" };
const INK = "#ECEAF8";
const PANEL = "#12111F";
const R = 15;
const DURATION = 3500;

// 24x24 icon paths drawn inside the badges.
const ICON = {
  donor: "M5 8h14l-1.2 11a1 1 0 0 1-1 .9H7.2a1 1 0 0 1-1-.9L5 8z M9 8V7a3 3 0 0 1 6 0v1",
  ngo: "M4 11.5 12 5l8 6.5V19a1 1 0 0 1-1 1h-4v-5h-6v5H5a1 1 0 0 1-1-1z",
  volunteer: "M12 4 19 20l-7-3.5L5 20z",
};

const pt = (a: Actor): Pt => geoToPixel(Number(a.latitude), Number(a.longitude));
const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
const hexPoints = (p: Pt, r: number) =>
  Array.from({ length: 6 }, (_, i) => `${p.x + r * Math.cos((Math.PI / 3) * i + Math.PI / 6)},${p.y + r * Math.sin((Math.PI / 3) * i + Math.PI / 6)}`).join(" ");

type Item = { r: MapRoute; v: Actor; home: Pt; donorP: Pt; ngoP: Pt; target: Pt };
type Anim = { from: Pt; to: Pt; t0: number; dur: number };

// Real map of Centre Urbain Nord, restyled dark. Dots come from database coordinates, so the map, the AI distances
// and the ETAs agree. Every volunteer is animated independently, so several missions can run at the same time.
export default function CityMap({
  donors, ngos, volunteers, selectedDonorId, routes, preview, onSelectDonor, pick,
}: {
  donors: Actor[]; ngos: Actor[]; volunteers: Actor[]; selectedDonorId: string;
  routes: MapRoute[]; preview: MapPreview | null; onSelectDonor: (id: string) => void;
  // Click-to-place mode, used when a new volunteer chooses their home position.
  pick?: { active: boolean; point: { lat: number; lng: number } | null; onPick: (lat: number, lng: number) => void };
}) {
  const [focusId, setFocusId] = useState<string | null>(null);
  const [dots, setDots] = useState<Record<string, Pt>>({});
  const [calm, setCalm] = useState(false); // prefers-reduced-motion: no pulsing halos, no travel animation
  const cur = useRef<Record<string, Pt>>({});
  const seenStage = useRef<Record<string, string>>({});
  const anims = useRef<Record<string, Anim>>({});
  const settled = useRef(false);
  const raf = useRef(0);

  useEffect(() => { setCalm(window.matchMedia("(prefers-reduced-motion: reduce)").matches); }, []);

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
          // New mission started while the page is open: drive from home to the donor.
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

  // Name tag: a small dark glass pill, readable on any part of the map.
  const tag = (p: Pt, text: string, side: "left" | "right", strong = false) => {
    const w = text.length * 8.4 + 18;
    const x = side === "right" ? p.x + R + 8 : p.x - R - 8 - w;
    return (
      <g pointerEvents="none">
        <rect x={x} y={p.y - 14} width={w} height={28} rx={14} fill={PANEL} fillOpacity={0.88} stroke={strong ? "#C9BEFF" : "#ffffff"} strokeOpacity={strong ? 0.8 : 0.16} />
        <text x={x + w / 2} y={p.y + 5.5} textAnchor="middle" fontSize="16" fontWeight={strong ? 700 : 500} fill={INK}>{text}</text>
      </g>
    );
  };
  const icon = (p: Pt, d: string, color = PANEL) => (
    <g transform={`translate(${p.x - 10} ${p.y - 10}) scale(${20 / 24})`} pointerEvents="none">
      <path d={d} fill="none" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
    </g>
  );
  const halo = (p: Pt, color: string, shape: "circle" | "square" = "circle") => (
    <g pointerEvents="none">
      {shape === "circle" ? (
        <circle cx={p.x} cy={p.y} r={R + 6} fill="none" stroke={color} strokeWidth="2" strokeOpacity={calm ? 0.6 : undefined}>
          {!calm && <animate attributeName="r" values={`${R + 3};${R + 20}`} dur="2.2s" repeatCount="indefinite" />}
          {!calm && <animate attributeName="stroke-opacity" values="0.8;0" dur="2.2s" repeatCount="indefinite" />}
        </circle>
      ) : (
        <rect x={p.x - R - 6} y={p.y - R - 6} width={2 * R + 12} height={2 * R + 12} rx={12} fill="none" stroke={color} strokeWidth="2" strokeOpacity={0.7} />
      )}
    </g>
  );

  const pv = (() => {
    if (!preview) return null;
    const v = volunteers.find((x) => x.id === preview.volunteerId);
    const d = donors.find((x) => x.id === preview.donorId);
    const n = ngos.find((x) => x.id === preview.ngoId);
    return v && d && n ? { home: pt(v), donorP: pt(d), ngoP: pt(n), ngoId: n.id } : null;
  })();
  const routeByVol = new Map(items.map((i) => [i.r.volunteerId, i]));
  const hotNgos = new Set([...items.filter((i) => i.r.stage !== "back").map((i) => i.r.ngoId), ...(pv ? [pv.ngoId] : [])]);

  const line = (a: Pt, b: Pt, color: string, dotted: boolean) => (
    <>
      <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke={color} strokeWidth="12" strokeOpacity="0.16" strokeLinecap="round" />
      <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke={color} strokeWidth="4" strokeLinecap="round" strokeDasharray={dotted ? "1 10" : undefined} />
    </>
  );

  return (
    <figure>
      <svg viewBox={`0 0 ${MAP.width} ${MAP.height}`} className={`mx-auto block max-h-[74vh] w-full ${pick?.active ? "cursor-crosshair" : ""}`}
        role="group" aria-label="Map of Centre Urbain Nord with donors, NGOs and volunteers"
        onClick={(e) => {
          if (!pick?.active) return;
          const svg = e.currentTarget;
          const m = svg.getScreenCTM();
          if (!m) return;
          const q = svg.createSVGPoint();
          q.x = e.clientX; q.y = e.clientY;
          const { x, y } = q.matrixTransform(m.inverse());
          if (x < 0 || y < 0 || x > MAP.width || y > MAP.height) return;
          const g = pixelToGeo(x, y);
          pick.onPick(g.lat, g.lng);
        }}>
        <image href={MAP.src} width={MAP.width} height={MAP.height} />

        {pv && (
          <g opacity="0.6">
            {line(pv.home, pv.donorP, COLOR.volunteer, true)}
            {line(pv.donorP, pv.ngoP, COLOR.ngo, true)}
          </g>
        )}

        {items.filter((i) => i.r.stage !== "back").map((i) => (
          <g key={`line-${i.r.volunteerId}`} opacity={i.r.highlight ? 1 : 0.55}>
            {(i.r.stage === "assigned" || i.r.stage === "donor") && line(i.home, i.donorP, COLOR.volunteer, true)}
            {line(i.donorP, i.ngoP, COLOR.ngo, false)}
          </g>
        ))}

        {ngos.map((n) => {
          const p = pt(n);
          const hot = hotNgos.has(n.id);
          return (
            <g key={n.id}>
              {hot && halo(p, COLOR.ngo, "square")}
              <rect x={p.x - R} y={p.y - R} width={2 * R} height={2 * R} rx={9} fill={COLOR.ngo} stroke={INK} strokeWidth="2.5" />
              {icon(p, ICON.ngo)}
              {tag(p, n.name, p.x > MAP.width * 0.78 ? "left" : "right", hot)}
            </g>
          );
        })}

        {volunteers.map((v) => {
          const it = routeByVol.get(v.id);
          const p = it ? (dots[v.id] ?? it.target) : pt(v);
          const active = !!it && it.r.stage !== "back";
          const off = !active && v.available === false; // idle and off duty, even if they once finished a mission
          return (
            <g key={v.id}>
              {active && halo(p, COLOR.volunteer)}
              <polygon points={hexPoints(p, R + 2)} fill={off ? PANEL : COLOR.volunteer} stroke={off ? "#6B6A85" : INK} strokeWidth="2.5" strokeLinejoin="round" />
              {icon(p, ICON.volunteer, off ? "#6B6A85" : PANEL)}
              {tag(p, off ? `${v.name} (off duty)` : v.name, "left", !!it?.r.highlight)}
            </g>
          );
        })}

        {donors.map((d) => {
          const p = pt(d);
          const selected = d.id === selectedDonorId;
          return (
            <g key={d.id} role="button" tabIndex={0} aria-label={`Donate as ${d.name}`} aria-pressed={selected}
              className="cursor-pointer" style={{ outline: "none" }}
              onClick={() => { if (!pick?.active) onSelectDonor(d.id); }}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onSelectDonor(d.id); } }}
              onFocus={() => setFocusId(d.id)} onBlur={() => setFocusId(null)}>
              <circle cx={p.x} cy={p.y} r="28" fill="transparent" />
              {selected && halo(p, COLOR.donor)}
              {focusId === d.id && <circle cx={p.x} cy={p.y} r={R + 12} fill="none" stroke="#C9BEFF" strokeWidth="3" />}
              <circle cx={p.x} cy={p.y} r={R} fill={COLOR.donor} stroke={INK} strokeWidth="2.5" />
              {icon(p, ICON.donor)}
              {tag(p, d.name, "right", selected)}
            </g>
          );
        })}

        {pick?.active && pick.point && (() => {
          const hp = geoToPixel(pick.point.lat, pick.point.lng);
          return (
            <g>
              <polygon points={hexPoints(hp, R + 8)} fill="none" stroke={COLOR.volunteer} strokeWidth="3" strokeDasharray="6 5" />
              <polygon points={hexPoints(hp, R)} fill={COLOR.volunteer} fillOpacity="0.55" />
              {tag(hp, "Your home", "left", true)}
            </g>
          );
        })()}
      </svg>

      <figcaption className="flex flex-wrap items-center gap-x-5 gap-y-1 px-4 py-2.5 text-xs text-[#ECEAF8]/70">
        <span className="inline-flex items-center gap-1.5"><svg width="14" height="14" aria-hidden><circle cx="7" cy="7" r="6" fill={COLOR.donor} /></svg>Donor (click to donate)</span>
        <span className="inline-flex items-center gap-1.5"><svg width="14" height="14" aria-hidden><rect x="1" y="1" width="12" height="12" rx="4" fill={COLOR.ngo} /></svg>NGO</span>
        <span className="inline-flex items-center gap-1.5"><svg width="14" height="14" aria-hidden><polygon points={hexPoints({ x: 7, y: 7 }, 6.5)} fill={COLOR.volunteer} /></svg>Volunteer</span>
      </figcaption>
    </figure>
  );
}
'@

Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import CodeStep from "./components/CodeStep";
import QrCode from "./components/QrCode";
import CityMap, { type MapPreview, type MapRoute } from "./components/CityMap";
import Logo from "./components/Logo";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string; pickup_latitude: number; pickup_longitude: number };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string; received_kg: number | null; events?: string[] };
type Named = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Rep = { id: string; name: string; count: number; kg: number };
type EventRow = { event_type: string; status: string; actor_id?: string | null; signer_account_id?: string | null; hedera_consensus_timestamp?: string | null; hedera_transaction_id?: string | null };
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
const VEHICLE_CAPACITY: Record<string, number> = { Bike: 10, Scooter: 20, Car: 60, Van: 150 };

const DONOR_PRESETS: Record<string, { foodType: string; quantityKg: string; storage: string }> = {
  "DONOR-01": { foodType: "Fresh groceries", quantityKg: "60", storage: "refrigerated" },
  "DONOR-02": { foodType: "Bakery goods", quantityKg: "25", storage: "ambient" },
  "DONOR-03": { foodType: "Fresh produce", quantityKg: "40", storage: "refrigerated" },
  "DONOR-04": { foodType: "Prepared meals", quantityKg: "50", storage: "refrigerated" },
};
const KG_PER_MEAL = 0.5; // estimate used for "meal equivalents"

const btn =
  "rounded-lg bg-[#8B7CF6] px-4 py-2 text-sm font-semibold text-[#0D0C16] transition hover:bg-[#A89BFF] disabled:opacity-50 disabled:hover:bg-[#8B7CF6] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#C9BEFF]";
const btnGhost =
  "rounded-lg border border-[#C9BEFF]/40 px-4 py-2 text-sm font-medium text-[#C9BEFF] transition hover:bg-[#8B7CF6]/10 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#C9BEFF]";
const input =
  "w-full rounded-lg border border-[#ECEAF8]/20 bg-[#1B1A33] px-3 py-2 text-sm text-[#ECEAF8] placeholder:text-[#ECEAF8]/40 focus-visible:outline-2 focus-visible:outline-[#C9BEFF]";

// The signed steps of a donation, in the order they appear on the timeline (short label for the scrubber).
const FLOW_STEPS: [string, string][] = [
  ["DONATION_CREATED", "Created"], ["NGO_MATCHED", "Matched"], ["VOLUNTEER_ASSIGNED", "Accepted"],
  ["DONOR_HANDOVER_CONFIRMED", "Handed over"], ["PICKUP_CONFIRMED", "Picked up"],
  ["DROPOFF_CONFIRMED", "Dropped off"], ["DELIVERY_CONFIRMED", "Delivered"],
];
// Donations recorded before every actor had its own account.
const LEGACY_STEPS: [string, string][] = [
  ["DONATION_CREATED", "Created"], ["NGO_MATCHED", "Matched"], ["VOLUNTEER_ASSIGNED", "Assigned"],
  ["PICKUP_CONFIRMED", "Picked up"], ["DELIVERY_CONFIRMED", "Delivered"],
];

const human = (s: string) => (s.charAt(0) + s.slice(1).toLowerCase()).replace(/_/g, " ");
const EVENT_LABEL: Record<string, string> = {
  DONATION_CREATED: "Donation created",
  NGO_MATCHED: "NGO matched",
  VOLUNTEER_ASSIGNED: "Volunteer assigned",
  PICKUP_CONFIRMED: "Pickup confirmed",
  DONOR_HANDOVER_CONFIRMED: "Donor handed over",
  DROPOFF_CONFIRMED: "Volunteer dropped off",
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
    status === "COMPLETED" ? "bg-[#34D3A0] text-[#0D0C16]"
    : status === "AVAILABLE" ? "bg-[#8B7CF6]/20 text-[#D2C9FF]"
    : status === "PICKED_UP" ? "bg-[#34D3A0]/15 text-[#7EE8C6]"
    : "bg-[#FBBF24]/15 text-[#FCD34D]";
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
  const [volId, setVolId] = useState("");
  const [ngoId, setNgoId] = useState("");
  const [joining, setJoining] = useState(false);
  const [home, setHome] = useState<{ lat: number; lng: number } | null>(null);
  const [joinForm, setJoinForm] = useState({ name: "", vehicle: "Car", capacityKg: "60", cold: false });
  const busyRef = useRef<string | null>(null);
  const [dock, setDock] = useState<"timeline" | "donations" | "record">("donations");
  const [stepKey, setStepKey] = useState<string | null>(null);
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
  useEffect(() => { busyRef.current = busy; }, [busy]);
  useEffect(() => { setStepKey(null); if (selectedId) setDock("timeline"); }, [selectedId]);

  // Remember who THIS device is acting as (each phone or tab can be a different person).
  useEffect(() => {
    try {
      setVolId(localStorage.getItem("rm.volunteer") ?? "");
      setNgoId(localStorage.getItem("rm.ngo") ?? "");
      const d = localStorage.getItem("rm.donor");
      if (d) setDonorId(d);
    } catch { /* storage blocked: defaults are used */ }
  }, []);
  useEffect(() => { if (vols.length && !vols.some((v) => v.id === volId)) setVolId(vols[0].id); }, [vols, volId]);
  useEffect(() => { if (ngos.length && !ngos.some((n) => n.id === ngoId)) setNgoId(ngos[0].id); }, [ngos, ngoId]);

  // Live refresh so several screens stay in sync (paused while this screen is busy or hidden).
  useEffect(() => {
    const t = setInterval(() => { if (!document.hidden && !busyRef.current) load().catch(() => {}); }, 4000);
    return () => clearInterval(t);
  }, [load]);
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
  function remember(key: string, value: string) { try { localStorage.setItem(key, value); } catch { /* ignore */ } }
  function chooseVolunteer(id: string) { setVolId(id); remember("rm.volunteer", id); }
  function chooseNgo(id: string) { setNgoId(id); remember("rm.ngo", id); }
  function selectDonor(id: string) {
    setRole("Donor"); setDonorId(id); setSelectedId(null); setMatch(null); remember("rm.donor", id);
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

  // Donor side of the pickup handoff: the volunteer is on the way and the donor has not signed yet.
  const handovers = missions.filter((m) => ms(m) === "EN_ROUTE" && !(m.events ?? []).includes("DONOR_HANDOVER_CONFIRMED")
    && donations.find((d) => d.id === m.donation_id)?.donor_id === donorId);
  // Each screen only shows the missions of the person it is acting as.
  const myVolMissions = missions.filter((m) => m.volunteer_id === volId && ["PICKUP_PENDING", "EN_ROUTE", "PICKED_UP"].includes(ms(m)));
  const myNgoMissions = missions.filter((m) => m.ngo_id === ngoId && ms(m) === "PICKED_UP");
  const meVol = vols.find((v) => v.id === volId);
  const meNgo = ngos.find((n) => n.id === ngoId);

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

  if (!mounted) return <main className="min-h-screen bg-[#0D0C16]" />; // render the UI only in the browser: extensions inject attributes into server HTML

  const hederaText = (h: { status?: string } | undefined) =>
    h?.status === "CONFIRMED" ? "Recorded on Hedera." : "Saved. Hedera verification is pending.";

  // ---- signed-step timeline for the selected donation
  const legacyFlow = events.length > 0 && events.every((e) => !e.actor_id);
  const stepList = legacyFlow ? LEGACY_STEPS : FLOW_STEPS;
  const evByType = new Map(events.map((e) => [e.event_type, e]));
  const firstMissing = stepList.findIndex(([t]) => !evByType.has(t));
  const lastDoneType = [...stepList].reverse().find(([t]) => evByType.has(t))?.[0] ?? null;
  const activeStep = stepKey ?? lastDoneType;
  const activeEv = activeStep ? evByType.get(activeStep) : undefined;
  const actorName = (id?: string | null) =>
    !id ? "Platform" : id === "PLATFORM" ? "Coordinator"
    : donors.find((x) => x.id === id)?.name ?? ngos.find((x) => x.id === id)?.name ?? vols.find((x) => x.id === id)?.name ?? id;
  const clock = (ts?: string | null) => (ts ? new Date(ts).toISOString().slice(11, 19) + " UTC" : "");
  const ROLES: { role: Role; label: string; icon: string }[] = [
    { role: "Donor", label: "Donor", icon: "M5 8h14l-1.2 11a1 1 0 0 1-1 .9H7.2a1 1 0 0 1-1-.9L5 8z M9 8V7a3 3 0 0 1 6 0v1" },
    { role: "Volunteer", label: "Volunteer", icon: "M12 4 19 20l-7-3.5L5 20z" },
    { role: "NGO", label: "NGO", icon: "M4 11.5 12 5l8 6.5V19a1 1 0 0 1-1 1h-4v-5h-6v5H5a1 1 0 0 1-1-1z" },
  ];
  const TABS: ["timeline" | "donations" | "record", string][] = [["timeline", "Signed steps"], ["donations", "Donations"], ["record", "Track record"]];

  return (
    <main className="min-h-screen bg-[#0D0C16] text-[#ECEAF8]">
      <div className="grid lg:grid-cols-[88px_minmax(0,1fr)_410px] lg:grid-rows-[auto_1fr] lg:[grid-template-areas:'rail_top_panel'_'rail_dock_panel']">

        {/* ---------------------------------------------- rail: who is this screen */}
        <nav aria-label="Choose a role" className="flex items-center gap-3 border-b border-[#ECEAF8]/10 bg-[#0A0910] px-4 py-3 lg:sticky lg:top-0 lg:h-screen lg:flex-col lg:justify-start lg:gap-3 lg:border-b-0 lg:border-r lg:px-2 lg:py-6 lg:[grid-area:rail]">
          <Logo size={40} className="shrink-0 lg:mb-5" />
          <div role="group" aria-label="Role" className="flex gap-2 lg:flex-col">
            {ROLES.map((r) => (
              <button key={r.role} aria-pressed={role === r.role} onClick={() => setRole(r.role)}
                className={`flex w-[66px] flex-col items-center gap-1 rounded-xl px-1 py-2.5 text-[11px] font-medium transition focus-visible:outline-2 focus-visible:outline-[#C9BEFF] ${role === r.role ? "bg-[#8B7CF6] text-[#0D0C16]" : "text-[#ECEAF8]/65 hover:bg-[#ECEAF8]/10"}`}>
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d={r.icon} /></svg>
                {r.label}
              </button>
            ))}
          </div>
          <p className="ml-auto flex items-center gap-1.5 text-[11px] text-[#ECEAF8]/55 lg:ml-0 lg:mt-auto lg:flex-col">
            <span aria-hidden className="h-2 w-2 rounded-full bg-[#34D3A0] motion-safe:animate-pulse" />
            Live
          </p>
        </nav>

        {/* ---------------------------------------------- top: title, impact, map */}
        <div className="px-5 pt-6 lg:px-8 lg:[grid-area:top]">
          <header>
            <h1 className="font-[family-name:var(--font-heading)] text-2xl font-semibold tracking-tight">RescueMesh</h1>
            <p className="text-sm text-[#ECEAF8]/60">Rescue the surplus. Prove the rescue.</p>
          </header>

          <section aria-label="Impact so far" className="mt-6 flex flex-wrap items-end gap-x-12 gap-y-5">
            <div>
              <p className="text-sm text-[#ECEAF8]/60">Food rescued</p>
              <p className="font-[family-name:var(--font-heading)] text-6xl font-semibold leading-none tabular-nums text-[#C9BEFF] sm:text-7xl">
                {stats[2].value}<span className="ml-2 text-2xl font-medium text-[#ECEAF8]/50">kg</span>
              </p>
            </div>
            <div className="flex gap-8 sm:gap-10">
              {[stats[0], stats[1], stats[3]].map((x) => (
                <div key={x.label}>
                  <p className="font-[family-name:var(--font-heading)] text-3xl font-semibold tabular-nums">{x.value}</p>
                  <p className="text-xs text-[#ECEAF8]/55">{x.label}</p>
                </div>
              ))}
            </div>
          </section>

          {notice && (
            <p role="status" className={`mt-5 rounded-xl border px-4 py-2.5 text-sm ${notice.ok ? "border-[#34D3A0]/40 bg-[#34D3A0]/10" : "border-[#FB7185]/50 bg-[#FB7185]/10"}`}>
              {notice.text}
            </p>
          )}

          {pending > 0 && (
            <p className="mt-4 flex flex-wrap items-center gap-3 rounded-xl border border-[#FBBF24]/40 bg-[#FBBF24]/10 px-4 py-2.5 text-sm">
              {pending} {pending === 1 ? "event is" : "events are"} waiting for Hedera verification. The app keeps working.
              <button className={btnGhost} disabled={busy !== null} onClick={() => run("retry", async () => {
                const r = await api("/api/hedera/retry", "POST");
                return `${r.confirmed} ${r.confirmed === 1 ? "event" : "events"} recorded on Hedera${r.stillPending ? `, ${r.stillPending} still pending` : ""}.`;
              })}>
                {busy === "retry" ? "Retrying\u2026" : "Retry now"}
              </button>
            </p>
          )}

          <div className="mt-6 overflow-hidden rounded-2xl border border-[#ECEAF8]/10 bg-[#1D1B42] shadow-[0_0_90px_-40px_#8B7CF6]">
            <CityMap donors={donors} ngos={ngos} volunteers={vols} selectedDonorId={donorId} routes={volRoutes} preview={preview} onSelectDonor={selectDonor}
              pick={{ active: joining && role === "Volunteer", point: home, onPick: (lat, lng) => setHome({ lat, lng }) }} />
          </div>
        </div>

        {/* ---------------------------------------------- panel: what this person can do */}
        <aside className="border-t border-[#ECEAF8]/10 bg-[#11101C] px-5 py-6 lg:sticky lg:top-0 lg:h-screen lg:overflow-y-auto lg:border-l lg:border-t-0 lg:[grid-area:panel]">
          <section aria-label={`${role} actions`}>
            {role === "Donor" && (
              <>
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Report surplus food</h2>
                <label className="mb-4 block text-sm">Acting as
                  <select className={`${input} mt-1`} value={donorId} onChange={(e) => selectDonor(e.target.value)}>
                    {donors.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                  </select>
                  <span className="mt-1 block text-xs text-[#ECEAF8]/60">You can also click a donor on the map.</span>
                </label>
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
                  <div className="mt-8 border-t border-[#ECEAF8]/15 pt-6">
                    <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Rescue match for {selected.id}</h2>
                    {!match && (
                      <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run("match", async () => {
                        setMatch(await api(`/api/donations/${selected.id}/match`, "POST"));
                      })}>
                        {busy === "match" ? "AI Coordinator is working\u2026" : "Find rescue match"}
                      </button>
                    )}
                    {busy === "match" && (
                      <ul className="mt-3 animate-pulse space-y-1 text-sm text-[#ECEAF8]/70">
                        <li>Checking NGO capacity and cold storage</li>
                        <li>Checking volunteer availability and transport</li>
                        <li>Checking the expiration window</li>
                      </ul>
                    )}
                    {match && !match.matched && (
                      <div className="mt-3 text-sm">
                        <p className="font-medium text-[#FB7185]">No safe match found.</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5 text-[#ECEAF8]/75">
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
                        <p className="text-[#ECEAF8]/70">
                          Pickup in about {match.recommendation.estimatedPickupMinutes} min, delivery in about {match.recommendation.estimatedDeliveryMinutes} min.
                          Risk: {match.recommendation.riskLevel.toLowerCase()}. NGO is {match.recommendation.ngoDistanceKm} km away.
                        </p>
                        <p className="mt-3">{match.recommendation.explanation}</p>
                        <ul className="mt-3 list-disc space-y-1 pl-5 text-[#ECEAF8]/75">
                          {match.recommendation.reason.map((r) => <li key={r}>{r}</li>)}
                        </ul>
                        {match.recommendation.source !== "llm" && (
                          <p className="mt-2 text-xs text-[#ECEAF8]/55">AI model unavailable. Deterministic fallback used.</p>
                        )}
                        <div className="mt-4 flex gap-3">
                          <button className={btn} disabled={busy !== null} onClick={() => run("accept", async () => {
                            const rec = match.recommendation!;
                            await api(`/api/donations/${selected.id}/accept`, "POST", { ngoId: rec.ngoId, volunteerId: rec.volunteerId });
                            setMatch(null);
                            return `Mission accepted and the match is signed on Hedera by the coordinator. Switch to Volunteer to start the pickup.`;
                          })}>
                            {busy === "accept" ? "Recording on Hedera\u2026" : "Accept mission"}
                          </button>
                          <button className={btnGhost} disabled={busy !== null} onClick={() => setMatch(null)}>Discard</button>
                        </div>
                      </div>
                    )}
                  </div>
                )}

                {handovers.length > 0 && (
                  <div className="mt-8 border-t border-[#ECEAF8]/15 pt-6">
                    <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Handovers to confirm</h2>
                    {handovers.map((m) => {
                      const d = donationOf(m.donation_id);
                      return (
                        <div key={m.id} className="mt-4 border-l-4 border-[#FBBF24] pl-4">
                          <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{d && donorName(d.donor_id)}: {m.donation_id}</p>
                          <p className="text-sm text-[#ECEAF8]/70">
                            {nameOf(vols, m.volunteer_id)} is here to collect {d?.quantity_kg} kg. Confirm that you handed the food over. Your own Hedera account signs this.
                          </p>
                          <button className={`${btn} mt-3`} disabled={busy !== null || !d} onClick={() => run(`handover-${m.id}`, async () => {
                            const r = await api(`/api/donations/${m.donation_id}/handover`, "POST", { donorId: d!.donor_id });
                            setSelectedId(m.donation_id);
                            return r.pickupComplete
                              ? `Handover confirmed. Both sides signed, ${nameOf(vols, m.volunteer_id)} is on the way to the NGO.`
                              : `Handover confirmed and signed by ${donorName(d!.donor_id)}. Waiting for the volunteer to confirm the pickup.`;
                          })}>
                            {busy === `handover-${m.id}` ? "Signing on Hedera\u2026" : "Confirm handover"}
                          </button>
                        </div>
                      );
                    })}
                  </div>
                )}
              </>
            )}

            {role === "Volunteer" && (
              <>
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Your missions</h2>
                <label className="mt-3 block text-sm">Acting as
                  <select className={`${input} mt-1`} value={volId} onChange={(e) => chooseVolunteer(e.target.value)}>
                    {vols.map((v) => <option key={v.id} value={v.id}>{v.name}{v.available === false ? " (off duty)" : ""}</option>)}
                  </select>
                </label>
                {meVol && (
                  <div className="mt-2 flex flex-wrap items-center gap-3 text-sm">
                    <span>{meVol.available === false ? "Off duty" : "On duty"}</span>
                    <button className={btnGhost} disabled={busy !== null} onClick={() => run("duty", async () => {
                      await api(`/api/volunteers/${meVol.id}`, "PATCH", { available: meVol.available === false });
                      return meVol.available === false ? `${meVol.name} is on duty again.` : `${meVol.name} is off duty and will not be matched.`;
                    })}>
                      {meVol.available === false ? "Go on duty" : "Go off duty"}
                    </button>
                  </div>
                )}
                <button type="button" className="mt-3 text-sm text-[#C9BEFF] underline underline-offset-2" onClick={() => { setJoining((j) => !j); setHome(null); }}>
                  {joining ? "Cancel" : "Join as a volunteer"}
                </button>
                {joining && (
                  <div className="mt-3 space-y-3 border-l-4 border-[#8B7CF6] pl-4">
                    <label className="block text-sm">Name
                      <input className={`${input} mt-1`} value={joinForm.name} maxLength={40} onChange={(e) => setJoinForm({ ...joinForm, name: e.target.value })} />
                    </label>
                    <div className="grid grid-cols-2 gap-3">
                      <label className="block text-sm">Vehicle
                        <select className={`${input} mt-1`} value={joinForm.vehicle}
                          onChange={(e) => setJoinForm({ ...joinForm, vehicle: e.target.value, capacityKg: String(VEHICLE_CAPACITY[e.target.value] ?? joinForm.capacityKg) })}>
                          {Object.keys(VEHICLE_CAPACITY).map((v) => <option key={v} value={v}>{v}</option>)}
                        </select>
                      </label>
                      <label className="block text-sm">Capacity (kg)
                        <input type="number" min={1} className={`${input} mt-1`} value={joinForm.capacityKg} onChange={(e) => setJoinForm({ ...joinForm, capacityKg: e.target.value })} />
                      </label>
                    </div>
                    <label className="flex items-center gap-2 text-sm">
                      <input type="checkbox" checked={joinForm.cold} onChange={(e) => setJoinForm({ ...joinForm, cold: e.target.checked })} />
                      Refrigerated transport
                    </label>
                    <p className="text-sm">{home ? `Home position set (${home.lat.toFixed(4)}, ${home.lng.toFixed(4)}).` : "Click the map to set your home position."}</p>
                    <button className={btn} disabled={busy !== null || joinForm.name.trim().length < 2 || !home || !(Number(joinForm.capacityKg) > 0)} onClick={() => run("join", async () => {
                      const r = await api("/api/volunteers", "POST", {
                        name: joinForm.name.trim(), transportType: joinForm.vehicle, capacityKg: Number(joinForm.capacityKg),
                        coldStorage: joinForm.cold, latitude: home!.lat, longitude: home!.lng,
                      });
                      await load(); // the new volunteer must be in the list before we select them
                      chooseVolunteer(r.volunteer.id);
                      setJoining(false); setHome(null); setJoinForm({ name: "", vehicle: "Car", capacityKg: "60", cold: false });
                      return `Welcome ${r.volunteer.name}. Your own Hedera account ${r.hederaAccountId} was created.${r.warning ? " " + r.warning : ""}`;
                    })}>
                      {busy === "join" ? "Creating your Hedera account\u2026" : "Create volunteer account"}
                    </button>
                  </div>
                )}
                {myVolMissions.length === 0 && (
                  <p className="mt-3 text-sm text-[#ECEAF8]/65">No missions for {meVol?.name ?? "this volunteer"} right now. As a donor, create a donation and accept a match first.</p>
                )}
                {myVolMissions.map((m) => {
                  const d = donationOf(m.donation_id);
                  const st = ms(m);
                  const ev = m.events ?? [];
                  const me = nameOf(vols, m.volunteer_id);
                  const dn = d ? donorName(d.donor_id) : "the donor";
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#FBBF24] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">Mission {m.donation_id}</p>
                      <p className="text-sm text-[#ECEAF8]/70">
                        {dn}: {d?.quantity_kg} kg of {d?.food_type.toLowerCase()}. Driver: {me}.{" "}
                        {st === "PICKUP_PENDING" ? "Ready to start." : st === "EN_ROUTE" ? "On the way to the donor." : `On the way to ${nameOf(ngos, m.ngo_id)}.`}
                      </p>

                      {st === "PICKUP_PENDING" && (
                        <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`start-${m.id}`, async () => {
                          await api(`/api/donations/${m.donation_id}/start`, "POST", { volunteerId: m.volunteer_id });
                          setSelectedId(m.donation_id);
                          return `${me} accepted the mission, signed on Hedera by their own account, and is on the way to ${dn}.`;
                        })}>
                          {busy === `start-${m.id}` ? "Signing on Hedera\u2026" : "Start pickup"}
                        </button>
                      )}

                      {st === "EN_ROUTE" && (ev.includes("PICKUP_CONFIRMED") ? (
                        <p className="mt-3 text-sm">You confirmed the pickup. Waiting for {dn} to confirm the handover.</p>
                      ) : (
                        <>
                          <CodeStep value={codes["p-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["p-" + m.id]: v })} />
                          <button className={`${btn} mt-3`} disabled={busy !== null || !(codes["p-" + m.id] ?? "").trim()} onClick={() => run(`pickup-${m.id}`, async () => {
                            const r = await api(`/api/donations/${m.donation_id}/pickup`, "POST", { volunteerId: m.volunteer_id, code: codes["p-" + m.id] });
                            setSelectedId(m.donation_id);
                            return r.pickupComplete
                              ? `Pickup complete. Donor and volunteer both signed on Hedera. ${hederaText(r.hedera)}`
                              : `Pickup confirmed and signed by ${me}. Waiting for ${dn} to confirm the handover (switch to Donor).`;
                          })}>
                            {busy === `pickup-${m.id}` ? "Signing on Hedera\u2026" : "Confirm pickup"}
                          </button>
                        </>
                      ))}

                      {st === "PICKED_UP" && (ev.includes("DROPOFF_CONFIRMED") ? (
                        <p className="mt-3 text-sm">You confirmed the drop-off. Waiting for {nameOf(ngos, m.ngo_id)} to confirm the delivery.</p>
                      ) : (
                        <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`dropoff-${m.id}`, async () => {
                          const r = await api(`/api/donations/${m.donation_id}/dropoff`, "POST", { volunteerId: m.volunteer_id });
                          setSelectedId(m.donation_id);
                          return r.deliveryComplete
                            ? `Delivery complete. Volunteer and NGO both signed on Hedera. ${hederaText(r.hedera)}`
                            : `Drop-off confirmed and signed by ${me}. Waiting for ${nameOf(ngos, m.ngo_id)} to confirm the delivery (switch to NGO).`;
                        })}>
                          {busy === `dropoff-${m.id}` ? "Signing on Hedera\u2026" : "Hand over to the NGO"}
                        </button>
                      ))}
                    </div>
                  );
                })}
              </>
            )}

            {role === "NGO" && (
              <>
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Incoming donations</h2>
                <label className="mt-3 block text-sm">Acting as
                  <select className={`${input} mt-1`} value={ngoId} onChange={(e) => chooseNgo(e.target.value)}>
                    {ngos.map((n) => <option key={n.id} value={n.id}>{n.name}</option>)}
                  </select>
                </label>
                {myNgoMissions.length === 0 && (
                  <p className="mt-3 text-sm text-[#ECEAF8]/65">Nothing on the way to {meNgo?.name ?? "this NGO"} yet. Deliveries appear here once the donor and the volunteer have both confirmed the pickup.</p>
                )}
                {myNgoMissions.map((m) => {
                  const d = donationOf(m.donation_id);
                  const ev = m.events ?? [];
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#34D3A0] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{nameOf(ngos, m.ngo_id)} receives {m.donation_id}</p>
                      <p className="text-sm text-[#ECEAF8]/70">
                        {d && donorName(d.donor_id)}, {d?.quantity_kg} kg, carried by {nameOf(vols, m.volunteer_id)}.{ev.includes("DROPOFF_CONFIRMED") ? ` ${nameOf(vols, m.volunteer_id)} has handed the food over.` : ""}
                      </p>
                      {ev.includes("DELIVERY_CONFIRMED") ? (
                        <p className="mt-3 text-sm">You confirmed the delivery. Waiting for {nameOf(vols, m.volunteer_id)} to confirm the drop-off.</p>
                      ) : (<>
                      <label className="mt-3 block text-sm">Quantity received (kg)
                        <input type="number" min={1} className={`${input} mt-1 max-w-40`}
                          value={received[m.id] ?? String(d?.quantity_kg ?? "")}
                          onChange={(e) => setReceived({ ...received, [m.id]: e.target.value })} />
                      </label>
                      <CodeStep value={codes["d-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["d-" + m.id]: v })} />
                      {(() => {
                        const rs = receivedState(m);
                        if (!(rs.got > 0)) return <p className="mt-2 text-sm text-[#FB7185]">Enter the quantity received.</p>;
                        if (rs.got > rs.sent) return <p className="mt-2 text-sm text-[#FB7185]">The donor sent {rs.sent} kg. You cannot receive more than that.</p>;
                        if (rs.got < rs.sent) return <p className="mt-2 text-sm text-[#FCD34D]">Only {rs.got} of {rs.sent} kg received. The {rs.sent - rs.got} kg difference will be recorded.</p>;
                        return null;
                      })()}
                      <button className={`${btn} mt-3`} disabled={busy !== null || !receivedState(m).valid || !(codes["d-" + m.id] ?? "").trim()} onClick={() => run(`deliver-${m.id}`, async () => {
                        const r = await api(`/api/donations/${m.donation_id}/deliver`, "POST", {
                          ngoId: m.ngo_id, quantityReceivedKg: Number(received[m.id] ?? d?.quantity_kg), code: codes["d-" + m.id],
                        });
                        setSelectedId(m.donation_id);
                        const rs = receivedState(m);
                        const diff = rs.got < rs.sent ? ` ${rs.got} of ${rs.sent} kg received, ${rs.sent - rs.got} kg difference recorded.` : "";
                        return r.deliveryComplete
                          ? `Delivery complete. Volunteer and NGO both signed on Hedera.${diff} ${hederaText(r.hedera)}`
                          : `Receipt confirmed and signed by ${nameOf(ngos, m.ngo_id)}.${diff} Waiting for ${nameOf(vols, m.volunteer_id)} to confirm the drop-off (switch to Volunteer).`;
                      })}>
                        {busy === `deliver-${m.id}` ? "Signing on Hedera\u2026" : "Confirm delivery"}
                      </button>
                      </>)}
                    </div>
                  );
                })}
              </>
            )}
          </section>
        </aside>

        {/* ---------------------------------------------- dock: steps, donations, track record */}
        <div className="px-5 pb-12 pt-8 lg:px-8 lg:[grid-area:dock]">
          <div role="tablist" aria-label="Details" className="flex gap-1 border-b border-[#ECEAF8]/10">
            {TABS.map(([key, label]) => (
              <button key={key} role="tab" aria-selected={dock === key} onClick={() => setDock(key)}
                className={`-mb-px border-b-2 px-4 py-2.5 text-sm font-medium transition focus-visible:outline-2 focus-visible:outline-[#C9BEFF] ${dock === key ? "border-[#8B7CF6] text-[#ECEAF8]" : "border-transparent text-[#ECEAF8]/55 hover:text-[#ECEAF8]"}`}>
                {label}
              </button>
            ))}
          </div>

          <div role="tabpanel" className="pt-6">
            {dock === "timeline" && (!selected ? (
              <p className="text-sm text-[#ECEAF8]/60">Select a donation to replay its signed steps.</p>
            ) : (
              <div>
                <div className="flex flex-wrap items-center gap-3">
                  <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">{selected.id}</h2>
                  <Badge status={selected.status} />
                  <span className="text-sm text-[#ECEAF8]/60">{selected.quantity_kg} kg, {selected.food_type.toLowerCase()}, {selected.storage_requirement}</span>
                </div>

                <div className="mt-6 overflow-x-auto pb-2">
                  <ol className="flex min-w-[720px] items-start" aria-label="Signed steps">
                    {stepList.map(([type, short], i) => {
                      const ev = evByType.get(type);
                      const state = ev ? (ev.status === "CONFIRMED" ? "done" : "pending") : i === firstMissing ? "next" : "todo";
                      const nextDone = i < stepList.length - 1 && evByType.has(stepList[i + 1][0]);
                      return (
                        <li key={type} className="relative flex-1">
                          {i < stepList.length - 1 && (
                            <span aria-hidden className="absolute left-1/2 top-[13px] h-0.5 w-full"
                              style={{ background: ev && nextDone ? "#34D3A0" : ev ? "linear-gradient(to right, #34D3A0, rgba(236,234,248,0.15))" : "rgba(236,234,248,0.15)" }} />
                          )}
                          <button type="button" aria-pressed={activeStep === type} onClick={() => setStepKey(type)}
                            className="relative z-10 flex w-full flex-col items-center gap-1.5 px-1 focus-visible:outline-2 focus-visible:outline-[#C9BEFF]">
                            <span className={`flex h-7 w-7 items-center justify-center rounded-full border-2 ${
                              state === "done" ? "border-[#34D3A0] bg-[#34D3A0] text-[#0D0C16]"
                              : state === "pending" ? "border-[#FBBF24] bg-[#FBBF24]/20 text-[#FBBF24] motion-safe:animate-pulse"
                              : state === "next" ? "border-[#8B7CF6] bg-[#8B7CF6]/15 motion-safe:animate-pulse"
                              : "border-[#ECEAF8]/25 bg-[#0D0C16]"} ${activeStep === type ? "ring-4 ring-[#8B7CF6]/35" : ""}`}>
                              {state === "done" && <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>}
                              {state === "pending" && <span className="text-xs font-bold">!</span>}
                            </span>
                            <span className={`text-xs ${activeStep === type ? "font-semibold text-[#ECEAF8]" : "text-[#ECEAF8]/70"}`}>{short}</span>
                            <span className="text-[11px] text-[#ECEAF8]/45">{ev ? actorName(ev.actor_id) : "\u00a0"}</span>
                          </button>
                        </li>
                      );
                    })}
                  </ol>
                </div>

                <p className="mt-4 min-h-[2.5rem] text-sm text-[#ECEAF8]/75" aria-live="polite">
                  {activeEv && activeStep ? (
                    <>
                      <span className="font-medium text-[#ECEAF8]">{EVENT_LABEL[activeStep] ?? activeStep}</span>
                      {activeEv.status === "CONFIRMED" ? ` signed by ${actorName(activeEv.actor_id)}` : " is waiting for Hedera verification"}
                      {activeEv.signer_account_id && <> (<a className="font-mono text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/account/${activeEv.signer_account_id}`} target="_blank" rel="noreferrer">{activeEv.signer_account_id}</a>)</>}
                      {activeEv.hedera_consensus_timestamp && ` at ${clock(activeEv.hedera_consensus_timestamp)}`}
                      {activeEv.hedera_transaction_id && activeEv.status === "CONFIRMED" && <> . <a className="text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/transaction/${activeEv.hedera_transaction_id}`} target="_blank" rel="noreferrer">Open on HashScan</a></>}
                    </>
                  ) : "No signed step yet."}
                </p>

                <div className="mt-6 grid gap-6 md:grid-cols-[auto_minmax(0,1fr)]">
                  <div className="flex items-center gap-4">
                    <div className="rounded-xl bg-white p-2"><QrCode value={selected.id} size={112} /></div>
                    <p className="max-w-[11rem] text-sm text-[#ECEAF8]/65">
                      <span className="font-medium text-[#ECEAF8]">Label {selected.id}</span><br />
                      Put it on the package. The receiver scans it.
                    </p>
                  </div>

                  {selected.status === "COMPLETED" ? (
                    <div className="max-w-sm rounded-2xl border-2 border-dashed border-[#C9BEFF]/45 bg-[#16152A] p-5">
                      <p className="font-[family-name:var(--font-heading)] text-xl font-semibold">Impact receipt</p>
                      <dl className="mt-3 space-y-1.5 text-sm">
                        <div className="flex justify-between"><dt className="text-[#ECEAF8]/65">Donation</dt><dd>{selected.id}</dd></div>
                        <div className="flex justify-between"><dt className="text-[#ECEAF8]/65">Food rescued</dt><dd className="font-semibold text-[#7EE8C6]">{rescuedKg} kg</dd></div>
                        {rescuedKg < Number(selected.quantity_kg) && (
                          <div className="flex justify-between text-[#FCD34D]"><dt>Sent by donor</dt><dd>{selected.quantity_kg} kg ({Number(selected.quantity_kg) - rescuedKg} kg difference)</dd></div>
                        )}
                        <div className="flex justify-between"><dt className="text-[#ECEAF8]/65">Meal equivalents (estimate)</dt><dd>&asymp; {Math.round(rescuedKg / KG_PER_MEAL)}</dd></div>
                        <div className="flex justify-between"><dt className="text-[#ECEAF8]/65">Signed steps on Hedera</dt><dd>{events.filter((e) => e.status === "CONFIRMED").length}</dd></div>
                      </dl>
                      <p className="mt-3 text-xs text-[#ECEAF8]/50">Meals are estimated at {KG_PER_MEAL} kg per meal. This is an estimate, not a measurement.</p>
                      <Link href={`/verify/${selected.id}`} className={`${btn} mt-4 inline-block`}>Verify on Hedera</Link>
                    </div>
                  ) : (
                    <p className="self-center text-sm text-[#ECEAF8]/55">The impact receipt appears here once the delivery is signed by both sides.</p>
                  )}
                </div>
              </div>
            ))}

            {dock === "donations" && (donations.length === 0 ? (
              <p className="text-sm text-[#ECEAF8]/60">No donations yet. Pick a donor and report surplus food to start.</p>
            ) : (
              <ul className="divide-y divide-[#ECEAF8]/10 overflow-hidden rounded-2xl border border-[#ECEAF8]/10">
                {donations.map((d) => (
                  <li key={d.id}>
                    <button onClick={() => { setSelectedId(d.id); setDock("timeline"); setMatch(null); }} aria-current={selectedId === d.id}
                      className={`flex w-full items-center justify-between gap-3 px-4 py-3 text-left transition hover:bg-[#1B1A33] focus-visible:outline-2 focus-visible:outline-[#C9BEFF] ${selectedId === d.id ? "bg-[#1B1A33]" : ""}`}>
                      <span>
                        <span className="font-medium">{d.id}</span>
                        <span className="ml-2 text-sm text-[#ECEAF8]/60">{donorName(d.donor_id)}: {d.quantity_kg} kg, {d.food_type.toLowerCase()}, {d.storage_requirement}</span>
                      </span>
                      <Badge status={d.status} />
                    </button>
                  </li>
                ))}
              </ul>
            ))}

            {dock === "record" && (() => {
              const totalRescues = rep.donors.reduce((n, r) => n + r.count, 0);
              const totalKg = rep.donors.reduce((n, r) => n + r.kg, 0);
              const contributors = rep.donors.length + rep.ngos.length + rep.volunteers.length;
              const cols = [
                { title: "Donors", unit: "verified donations", list: rep.donors, color: "#FF7A66", icon: ROLES[0].icon, kg: true },
                { title: "NGOs", unit: "successful deliveries", list: rep.ngos, color: "#34D3A0", icon: ROLES[2].icon, kg: false },
                { title: "Volunteers", unit: "successful pickups", list: rep.volunteers, color: "#A594FF", icon: ROLES[1].icon, kg: false },
              ];
              return (
                <div>
                  <div className="grid gap-4 sm:grid-cols-3">
                    {[
                      { label: "Verified rescues", value: totalRescues, unit: "" },
                      { label: "Food delivered", value: totalKg, unit: "kg" },
                      { label: "Contributors with a record", value: contributors, unit: "" },
                    ].map((t) => (
                      <div key={t.label} className="rounded-2xl border border-[#ECEAF8]/10 p-5"
                        style={{ background: "linear-gradient(135deg, rgba(139,124,246,0.22), rgba(22,21,42,0.55))" }}>
                        <p className="text-sm text-[#ECEAF8]/65">{t.label}</p>
                        <p className="mt-1 font-[family-name:var(--font-heading)] text-5xl font-semibold leading-none tabular-nums text-[#C9BEFF]">
                          {t.value}{t.unit && <span className="ml-1.5 text-xl font-medium text-[#ECEAF8]/50">{t.unit}</span>}
                        </p>
                      </div>
                    ))}
                  </div>

                  <div className="mt-5 grid gap-4 lg:grid-cols-3">
                    {cols.map((col) => {
                      const max = Math.max(1, ...col.list.map((r) => r.count));
                      return (
                        <section key={col.title} aria-label={col.title} className="rounded-2xl border border-[#ECEAF8]/10 bg-[#16152A]/70 p-5">
                          <header className="flex items-center gap-2.5">
                            <span className="flex h-8 w-8 items-center justify-center rounded-lg" style={{ background: `${col.color}26`, color: col.color }}>
                              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d={col.icon} /></svg>
                            </span>
                            <h3 className="font-[family-name:var(--font-heading)] text-lg font-semibold">{col.title}</h3>
                          </header>
                          {col.list.length === 0 ? (
                            <p className="mt-4 text-sm text-[#ECEAF8]/50">Nothing verified yet. The first confirmed delivery appears here.</p>
                          ) : (
                            <ol className="mt-4 space-y-4">
                              {col.list.map((r, i) => (
                                <li key={r.id}>
                                  <div className="flex items-center justify-between gap-3">
                                    <span className="flex min-w-0 items-center gap-2 text-sm font-medium">
                                      <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-bold"
                                        style={{ background: i === 0 ? col.color : "rgba(236,234,248,0.12)", color: i === 0 ? "#0D0C16" : "#ECEAF8" }}>{i + 1}</span>
                                      <span className="truncate">{r.name}</span>
                                    </span>
                                    <span className="font-[family-name:var(--font-heading)] text-xl font-semibold tabular-nums">{r.count}</span>
                                  </div>
                                  <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-[#ECEAF8]/10" role="img" aria-label={`${r.count} ${col.unit}`}>
                                    <div className="h-full rounded-full" style={{ width: `${Math.max(8, Math.round((r.count / max) * 100))}%`, background: `linear-gradient(90deg, ${col.color}, ${col.color}99)` }} />
                                  </div>
                                  <p className="mt-1 text-xs text-[#ECEAF8]/50">{col.unit}{col.kg ? `, ${r.kg} kg` : ""}</p>
                                </li>
                              ))}
                            </ol>
                          )}
                        </section>
                      );
                    })}
                  </div>

                  <p className="mt-5 flex items-center gap-2 text-xs text-[#ECEAF8]/55">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#34D3A0" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
                    Counted only from deliveries whose final event is confirmed on Hedera.
                  </p>
                </div>
              );
            })()}
          </div>
        </div>
      </div>
    </main>
  );
}
'@

Write-File 'app/verify/[id]/page.tsx' @'
import Link from "next/link";
import Logo from "../../components/Logo";
import { notFound } from "next/navigation";
import { createHash } from "crypto";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

const MIRROR = "https://testnet.mirrornode.hedera.com/api/v1";

// Current flow: two handoffs, each needs two signatures from two different accounts.
const STEPS: [string, string][] = [
  ["DONATION_CREATED", "Donation created"],
  ["NGO_MATCHED", "NGO matched by the coordinator"],
  ["VOLUNTEER_ASSIGNED", "Volunteer accepted the mission"],
  ["DONOR_HANDOVER_CONFIRMED", "Donor confirmed the handover"],
  ["PICKUP_CONFIRMED", "Volunteer confirmed the pickup"],
  ["DROPOFF_CONFIRMED", "Volunteer confirmed the drop-off"],
  ["DELIVERY_CONFIRMED", "NGO confirmed the delivery"],
];
// Donations recorded before per-actor accounts existed.
const LEGACY_STEPS: [string, string][] = [
  ["DONATION_CREATED", "Donation created"],
  ["NGO_MATCHED", "NGO matched"],
  ["VOLUNTEER_ASSIGNED", "Volunteer assigned"],
  ["PICKUP_CONFIRMED", "Pickup confirmed"],
  ["DELIVERY_CONFIRMED", "Delivery confirmed"],
];

type EventRow = {
  event_type: string; status: string; actor_id: string | null; signer_account_id: string | null;
  hedera_topic_id: string | null; hedera_sequence_number: string | null; payload_hash: string | null;
};
type Check = { state: "verified" | "pending" | "unreachable" | "mismatch" | "missing"; consensus?: string; payer?: string };

// Read the message back from the public Mirror Node, compare its hash with the one we stored,
// and check that the account that paid for (and therefore signed) the message is the one we recorded.
async function check(ev?: EventRow): Promise<Check> {
  if (!ev) return { state: "missing" };
  if (ev.status !== "CONFIRMED") return { state: "pending" };
  try {
    const r = await fetch(`${MIRROR}/topics/${ev.hedera_topic_id}/messages/${ev.hedera_sequence_number}`, { cache: "no-store" });
    if (!r.ok) return { state: "unreachable" };
    const m = await r.json();
    const text = Buffer.from(m.message, "base64").toString("utf8");
    const hash = createHash("sha256").update(text).digest("hex");
    const payer: string | undefined = m.payer_account_id;
    const sameContent = hash === ev.payload_hash;
    const sameSigner = !ev.signer_account_id || !payer || payer === ev.signer_account_id;
    return { state: sameContent && sameSigner ? "verified" : "mismatch", consensus: m.consensus_timestamp, payer };
  } catch {
    return { state: "unreachable" };
  }
}

const time = (ts?: string) => (ts ? new Date(Number(ts.split(".")[0]) * 1000).toISOString().slice(11, 19) + " UTC" : "");
const LABEL: Record<Check["state"], string> = {
  verified: "Read back from Hedera, content and signer match",
  pending: "Pending verification",
  unreachable: "Mirror Node not reachable yet, refresh in a few seconds",
  mismatch: "Does not match the ledger (content or signer)",
  missing: "Not reached yet",
};

export default async function VerifyPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { data: donation } = await supabase.from("donations").select("*").eq("id", id).maybeSingle();
  if (!donation) notFound();

  const [{ data }, { data: orgs }, { data: vols }, { data: accts }] = await Promise.all([
    supabase.from("hedera_events").select("*").eq("donation_id", id),
    supabase.from("organizations").select("id, name"),
    supabase.from("volunteers").select("id, name"),
    supabase.from("actor_accounts").select("actor_id, hedera_account_id"),
  ]);
  const rows = (data ?? []) as EventRow[];
  const names = new Map<string, string>([...(orgs ?? []), ...(vols ?? [])].map((x) => [x.id as string, x.name as string]));
  const ownAccount = new Map<string, string>((accts ?? []).map((a) => [a.actor_id as string, a.hedera_account_id as string]));

  const legacy = rows.length > 0 && rows.every((e) => !e.actor_id);
  const steps = legacy ? LEGACY_STEPS : STEPS;
  const byType = new Map(rows.map((e) => [e.event_type, e]));
  const checks = await Promise.all(steps.map(([t]) => check(byType.get(t))));
  const allVerified = checks.every((c) => c.state === "verified");
  const topic = rows.find((e) => e.hedera_topic_id)?.hedera_topic_id;

  // Who signed: the actor's own account, or the platform acting on their behalf.
  function signer(ev: EventRow | undefined, c: Check) {
    if (!ev || !ev.actor_id) return null;
    const acct = c.payer ?? ev.signer_account_id ?? undefined;
    const who = ev.actor_id === "PLATFORM" ? "RescueMesh coordinator" : names.get(ev.actor_id) ?? ev.actor_id;
    const own = ownAccount.get(ev.actor_id);
    const onBehalf = ev.actor_id !== "PLATFORM" && (!own || (acct && own !== acct));
    return { who, acct, onBehalf };
  }

  return (
    <main className="min-h-screen bg-[#0D0C16] text-[#ECEAF8]">
      <div className="mx-auto max-w-2xl px-5 py-10">
        <Link href="/" className="inline-flex items-center gap-2.5 text-sm text-[#C9BEFF] underline underline-offset-2"><Logo size={30} />Back to dashboard</Link>
        <h1 className="mt-4 font-[family-name:var(--font-heading)] text-4xl font-semibold tracking-tight">Donation {id}</h1>
        <p className="mt-1 text-[#ECEAF8]/70">{donation.quantity_kg} kg of {String(donation.food_type).toLowerCase()}, currently {String(donation.status).toLowerCase().replace(/_/g, " ")}.</p>

        <p className={`mt-6 inline-block px-3 py-1.5 font-[family-name:var(--font-heading)] text-lg font-semibold ${allVerified ? "bg-[#34D3A0] text-[#0D0C16]" : "bg-[#FBBF24]/15 text-[#FCD34D]"}`}>
          {allVerified ? "Verified by Hedera" : "Not fully verified yet"}
        </p>

        <ol className="mt-8 border-l-2 border-[#ECEAF8]/25">
          {steps.map(([type, title], i) => {
            const c = checks[i];
            const ev = byType.get(type);
            const ok = c.state === "verified";
            const sg = signer(ev, c);
            return (
              <li key={type} className="relative pb-7 pl-6">
                <span aria-hidden className={`absolute -left-[9px] top-1 h-4 w-4 rounded-full border-2 ${ok ? "border-[#34D3A0] bg-[#34D3A0]" : "border-[#ECEAF8]/35 bg-[#0D0C16]"}`} />
                <p className="font-medium">{title}</p>
                <p className="text-sm text-[#ECEAF8]/65">
                  {c.consensus ? `${time(c.consensus)}, ` : ""}{LABEL[c.state]}
                </p>
                {sg && (
                  <p className="text-sm text-[#ECEAF8]/65">
                    {sg.onBehalf ? `Signed by the platform on behalf of ${sg.who}` : `Signed by ${sg.who}`}
                    {sg.acct && (
                      <>
                        {" "}(<a className="font-mono text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/account/${sg.acct}`} target="_blank" rel="noreferrer">{sg.acct}</a>)
                      </>
                    )}
                  </p>
                )}
                {ev?.hedera_sequence_number && (
                  <p className="mt-0.5 font-mono text-xs text-[#ECEAF8]/55">sequence {ev.hedera_sequence_number}</p>
                )}
              </li>
            );
          })}
        </ol>

        <div className="mt-2 border-t border-[#ECEAF8]/15 pt-5 text-sm">
          <p>
            Each row was fetched from the public Hedera Mirror Node. Its content hash is compared with the hash saved by RescueMesh,
            and the account that signed it is compared with the one we recorded, so this page does not rely on our database alone.
          </p>
          {!legacy && (
            <p className="mt-3">
              Each handoff needs two signatures from two different accounts: donor and volunteer at pickup, volunteer and NGO at delivery.
              Only registered accounts can write to the topic.
            </p>
          )}
          {topic && (
            <p className="mt-3">
              Hedera Consensus Service topic <span className="font-mono">{topic}</span>{" "}
              <a className="text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/topic/${topic}`} target="_blank" rel="noreferrer">
                Open on HashScan
              </a>
            </p>
          )}
        </div>
      </div>
    </main>
  );
}
'@

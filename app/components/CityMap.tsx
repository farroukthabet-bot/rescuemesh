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
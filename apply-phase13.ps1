# RescueMesh: Acting-as selectors, live refresh, volunteer sign-up, on/off duty.
# No new SQL needed.
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase13.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}






Write-File 'lib/hedera/keystore.ts' @'
import crypto from "crypto";
import { PrivateKey } from "@hashgraph/sdk";
import { supabase } from "@/lib/db/supabase";

export type Signer = { actorId: string; accountId: string; key: PrivateKey; viaPlatform: boolean };

// Each actor (donor, NGO, volunteer) has its OWN Hedera account. Its private key is stored encrypted
// (AES-256-GCM) in the actor_accounts table. In this demo the server decrypts the key to sign for the actor
// (custodial). In production the key would live in the actor's own wallet and the signature would come from there.

function secret(): Buffer {
  const hex = process.env.KEY_ENCRYPTION_SECRET ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("KEY_ENCRYPTION_SECRET must be 64 hex characters (see .env.local)");
  return Buffer.from(hex, "hex");
}

// Format: iv:authTag:ciphertext (base64). Must match scripts/setup-actors.mjs.
export function encryptSecret(plain: string): string {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", secret(), iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString("base64")).join(":");
}

export function decryptSecret(blob: string): string {
  const [iv, tag, enc] = blob.split(":").map((p) => Buffer.from(p, "base64"));
  const d = crypto.createDecipheriv("aes-256-gcm", secret(), iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]).toString("utf8");
}

function platform(): Signer {
  return {
    actorId: "PLATFORM",
    accountId: process.env.HEDERA_ACCOUNT_ID!,
    key: PrivateKey.fromStringECDSA(process.env.HEDERA_PRIVATE_KEY!),
    viaPlatform: false,
  };
}

const cache = new Map<string, Signer>();

/** Who signs for this actor. PLATFORM = the coordinator account from .env.local. */
export async function getSigner(actorId: string): Promise<Signer> {
  if (actorId === "PLATFORM") return platform();
  const hit = cache.get(actorId);
  if (hit) return hit;

  const { data } = await supabase.from("actor_accounts").select("*").eq("actor_id", actorId).maybeSingle();
  // Actor without its own account (setup not run yet): fall back to the platform account and say so.
  if (!data) return { ...platform(), actorId, viaPlatform: true };

  const signer: Signer = {
    actorId,
    accountId: data.hedera_account_id,
    key: PrivateKey.fromStringDer(decryptSecret(data.encrypted_private_key)),
    viaPlatform: false,
  };
  cache.set(actorId, signer);
  return signer;
}
'@

Write-File 'lib/hedera/hcs.ts' @'
import { Client, TopicMessageSubmitTransaction } from "@hashgraph/sdk";
import { createHash } from "crypto";
import type { Signer } from "./keystore";

const clients = new Map<string, Client>();

// One client per signing account: the transaction is paid and signed by the actor's own account.
export function clientFor(s: Signer): Client {
  let c = clients.get(s.accountId);
  if (!c) {
    c = Client.forTestnet().setOperator(s.accountId, s.key);
    clients.set(s.accountId, c);
  }
  return c;
}

/** Submit one JSON message to the RescueMesh HCS topic, signed and paid by `signer`. */
export async function submitToTopic(payload: Record<string, unknown>, signer: Signer) {
  const topicId = process.env.HEDERA_TOPIC_ID;
  if (!topicId) throw new Error("HEDERA_TOPIC_ID is not set in .env.local");

  const message = JSON.stringify(payload);
  const c = clientFor(signer);

  const tx = await new TopicMessageSubmitTransaction({ topicId, message }).execute(c);
  const record = await tx.getRecord(c); // record includes the consensus timestamp

  return {
    topicId,
    sequenceNumber: record.receipt.topicSequenceNumber!.toString(),
    consensusTimestamp: record.consensusTimestamp.toDate().toISOString(),
    transactionId: tx.transactionId.toString(),
    payloadHash: createHash("sha256").update(message).digest("hex"),
    signerAccountId: signer.accountId,
  };
}
'@

Write-File 'lib/hedera/onboard.ts' @'
import { AccountCreateTransaction, Hbar, KeyList, PrivateKey, PublicKey, TopicUpdateTransaction } from "@hashgraph/sdk";
import { supabase } from "@/lib/db/supabase";
import { clientFor } from "./hcs";
import { encryptSecret, getSigner } from "./keystore";

let queue: Promise<unknown> = Promise.resolve();
/** Run onboarding jobs one at a time, so two sign-ups can never overwrite each other's topic key list. */
export function exclusive<T>(job: () => Promise<T>): Promise<T> {
  const run = queue.then(job, job);
  queue = run.catch(() => undefined);
  return run;
}

/** Creates a Hedera account for a new actor (paid by the platform with test HBAR) and stores its key encrypted. */
export async function createActorAccount(actorId: string): Promise<string> {
  const platform = await getSigner("PLATFORM");
  const client = clientFor(platform);
  const key = PrivateKey.generateECDSA();
  const tx = await new AccountCreateTransaction()
    .setKeyWithoutAlias(key.publicKey)
    .setInitialBalance(new Hbar(3))
    .setAccountMemo(`RescueMesh ${actorId}`) // IDs only on the public ledger
    .execute(client);
  const accountId = (await tx.getReceipt(client)).accountId!.toString();

  const { error } = await supabase.from("actor_accounts").insert({
    actor_id: actorId,
    hedera_account_id: accountId,
    public_key: key.publicKey.toStringDer(),
    encrypted_private_key: encryptSecret(key.toStringDer()),
  });
  if (error) throw new Error(error.message);
  return accountId;
}

/** Adds every registered actor to the topic's submit key (threshold 1 of N). Needs the topic's admin key (the platform). */
export async function refreshSubmitKey() {
  const topicId = process.env.HEDERA_TOPIC_ID;
  if (!topicId) throw new Error("HEDERA_TOPIC_ID is not set");
  const platform = await getSigner("PLATFORM");
  const client = clientFor(platform);
  const { data } = await supabase.from("actor_accounts").select("public_key");
  const keys = [platform.key.publicKey, ...(data ?? []).map((a) => PublicKey.fromString(a.public_key as string))];
  const tx = await new TopicUpdateTransaction().setTopicId(topicId).setSubmitKey(new KeyList(keys, 1)).execute(client);
  await tx.getReceipt(client);
}
'@

Write-File 'app/api/volunteers/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { MAP, geoToPixel } from "@/lib/map/calibration";
import { createActorAccount, exclusive, refreshSubmitKey } from "@/lib/hedera/onboard";

export const dynamic = "force-dynamic";

const MAX_VOLUNTEERS = Number(process.env.MAX_VOLUNTEERS ?? 30); // every volunteer costs the platform a few test HBAR

export async function GET() {
  const { data, error } = await supabase.from("volunteers").select("*");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}

const Body = z.object({
  name: z.string().trim().min(2).max(40),
  transportType: z.enum(["Bike", "Scooter", "Car", "Van"]),
  capacityKg: z.number().positive().max(1000),
  coldStorage: z.boolean(),
  latitude: z.number(),
  longitude: z.number(),
});

// Anyone can register as a volunteer: new row + their own Hedera account + permission to write to the topic.
export async function POST(req: Request) {
  const parsed = Body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });
  const b = parsed.data;

  const p = geoToPixel(b.latitude, b.longitude);
  if (p.x < 0 || p.y < 0 || p.x > MAP.width || p.y > MAP.height)
    return NextResponse.json({ error: "Pick a home position inside the map" }, { status: 400 });

  return exclusive(async () => {
    const { data: all } = await supabase.from("volunteers").select("id");
    if ((all?.length ?? 0) >= MAX_VOLUNTEERS)
      return NextResponse.json({ error: `Volunteer limit reached (${MAX_VOLUNTEERS}) for this demo` }, { status: 429 });
    const last = Math.max(0, ...(all ?? []).map((v) => parseInt(String(v.id).replace("VOL-", ""), 10) || 0));
    const id = `VOL-${String(last + 1).padStart(2, "0")}`;

    let accountId: string;
    try {
      accountId = await createActorAccount(id);
    } catch (e) {
      console.error("[onboard] account creation failed:", e);
      return NextResponse.json({ error: `Could not create the Hedera account: ${e instanceof Error ? e.message : e}` }, { status: 502 });
    }

    const { data: volunteer, error } = await supabase
      .from("volunteers")
      .insert({
        id, name: b.name, latitude: b.latitude, longitude: b.longitude,
        transport_type: b.transportType, transport_capacity_kg: b.capacityKg,
        has_cold_storage: b.coldStorage, available: true,
      })
      .select()
      .single();
    if (error) {
      await supabase.from("actor_accounts").delete().eq("actor_id", id); // undo
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    let warning: string | undefined;
    try {
      await refreshSubmitKey();
    } catch (e) {
      console.error("[onboard] topic key update failed:", e);
      warning = "The account exists, but the topic could not be updated, so this volunteer's events will stay pending. Create a new topic with scripts/create-topic.mjs.";
    }
    return NextResponse.json({ volunteer, hederaAccountId: accountId, warning }, { status: 201 });
  });
}
'@

Write-File 'app/api/volunteers/[id]/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { busyVolunteerIds } from "@/lib/busy";

export const dynamic = "force-dynamic";

const Body = z.object({ available: z.boolean() });

// On duty / off duty. Off-duty volunteers are not matched. Nobody can go off duty in the middle of a mission.
export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });

  if (!body.data.available && (await busyVolunteerIds()).has(id))
    return NextResponse.json({ error: "Finish the current mission before going off duty" }, { status: 409 });

  const { data, error } = await supabase.from("volunteers").update({ available: body.data.available }).eq("id", id).select().maybeSingle();
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  if (!data) return NextResponse.json({ error: "Volunteer not found" }, { status: 404 });
  return NextResponse.json(data);
}
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
  donors, ngos, volunteers, selectedDonorId, routes, preview, onSelectDonor, pick,
}: {
  donors: Actor[]; ngos: Actor[]; volunteers: Actor[]; selectedDonorId: string;
  routes: MapRoute[]; preview: MapPreview | null; onSelectDonor: (id: string) => void;
  // Click-to-place mode, used when a new volunteer chooses their home position.
  pick?: { active: boolean; point: { lat: number; lng: number } | null; onPick: (lat: number, lng: number) => void };
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
      <svg viewBox={`0 0 ${MAP.width} ${MAP.height}`} className={`w-full border border-[#0E2237]/15 bg-white ${pick?.active ? "cursor-crosshair" : ""}`}
        role="group" aria-label="Map of Centre Urbain Nord with donors, NGOs and volunteers"
        onClick={(e) => {
          if (!pick?.active) return;
          const r = e.currentTarget.getBoundingClientRect();
          const x = ((e.clientX - r.left) / r.width) * MAP.width;
          const y = ((e.clientY - r.top) / r.height) * MAP.height;
          if (x < 0 || y < 0 || x > MAP.width || y > MAP.height) return;
          const g = pixelToGeo(x, y);
          pick.onPick(g.lat, g.lng);
        }}>
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
              onClick={() => { if (!pick?.active) onSelectDonor(d.id); }}
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
        {pick?.active && pick.point && (() => {
          const hp = geoToPixel(pick.point.lat, pick.point.lng);
          return (
            <g>
              <polygon points={tri(hp, R + 6)} fill="none" stroke={COLOR.volunteer} strokeWidth="4" strokeDasharray="6 4" />
              <polygon points={tri(hp)} fill={COLOR.volunteer} fillOpacity="0.5" />
              {label(hp, "Your home", "left", true)}
            </g>
          );
        })()}
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

Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import CodeStep from "./components/CodeStep";
import QrCode from "./components/QrCode";
import CityMap, { type MapPreview, type MapRoute } from "./components/CityMap";

type Role = "Donor" | "Volunteer" | "NGO";
type Donation = { id: string; donor_id: string; food_type: string; quantity_kg: number; storage_requirement: string; status: string; pickup_latitude: number; pickup_longitude: number };
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string; received_kg: number | null; events?: string[] };
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
const VEHICLE_CAPACITY: Record<string, number> = { Bike: 10, Scooter: 20, Car: 60, Van: 150 };

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
  const [volId, setVolId] = useState("");
  const [ngoId, setNgoId] = useState("");
  const [joining, setJoining] = useState(false);
  const [home, setHome] = useState<{ lat: number; lng: number } | null>(null);
  const [joinForm, setJoinForm] = useState({ name: "", vehicle: "Car", capacityKg: "60", cold: false });
  const busyRef = useRef<string | null>(null);
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
                <label className="mb-4 block text-sm">Acting as
                  <select className={`${input} mt-1`} value={donorId} onChange={(e) => selectDonor(e.target.value)}>
                    {donors.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                  </select>
                  <span className="mt-1 block text-xs text-[#0E2237]/60">You can also click a donor on the map.</span>
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
                  <div className="mt-8 border-t border-[#0E2237]/15 pt-6">
                    <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Handovers to confirm</h2>
                    {handovers.map((m) => {
                      const d = donationOf(m.donation_id);
                      return (
                        <div key={m.id} className="mt-4 border-l-4 border-[#E8A200] pl-4">
                          <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{d && donorName(d.donor_id)}: {m.donation_id}</p>
                          <p className="text-sm text-[#0E2237]/70">
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
                <button type="button" className="mt-3 text-sm text-[#2A3EB1] underline underline-offset-2" onClick={() => { setJoining((j) => !j); setHome(null); }}>
                  {joining ? "Cancel" : "Join as a volunteer"}
                </button>
                {joining && (
                  <div className="mt-3 space-y-3 border-l-4 border-[#2A3EB1] pl-4">
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
                  <p className="mt-3 text-sm text-[#0E2237]/65">No missions for {meVol?.name ?? "this volunteer"} right now. As a donor, create a donation and accept a match first.</p>
                )}
                {myVolMissions.map((m) => {
                  const d = donationOf(m.donation_id);
                  const st = ms(m);
                  const ev = m.events ?? [];
                  const me = nameOf(vols, m.volunteer_id);
                  const dn = d ? donorName(d.donor_id) : "the donor";
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#E8A200] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">Mission {m.donation_id}</p>
                      <p className="text-sm text-[#0E2237]/70">
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
                  <p className="mt-3 text-sm text-[#0E2237]/65">Nothing on the way to {meNgo?.name ?? "this NGO"} yet. Deliveries appear here once the donor and the volunteer have both confirmed the pickup.</p>
                )}
                {myNgoMissions.map((m) => {
                  const d = donationOf(m.donation_id);
                  const ev = m.events ?? [];
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#0F7B6C] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{nameOf(ngos, m.ngo_id)} receives {m.donation_id}</p>
                      <p className="text-sm text-[#0E2237]/70">
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

          {/* ------------------------------------------------ donations + receipt */}
          <section aria-label="Map and donations">
            <CityMap donors={donors} ngos={ngos} volunteers={vols} selectedDonorId={donorId} routes={volRoutes} preview={preview} onSelectDonor={selectDonor}
              pick={{ active: joining && role === "Volunteer", point: home, onPick: (lat, lng) => setHome({ lat, lng }) }} />

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

Write-File 'DEMO_SCRIPT.md' @'
# RescueMesh: demo script (about 5 minutes)

## Before you go on stage (3 minutes)
1. Start Ollama, then warm the model: `ollama run llama3.2:3b "hi"` (type /bye afterwards).
2. Create a fresh topic so HashScan only shows this demo: `node --env-file=.env.local scripts/create-topic.mjs`, paste the ID into `HEDERA_TOPIC_ID`, restart `npm run dev`. Do not rehearse on this topic.
3. Clean dashboard: `Invoke-RestMethod -Method Post http://localhost:3000/api/demo/reset`, then refresh.
4. Open HashScan on the topic in a second window: https://hashscan.io/testnet/topic/YOUR_TOPIC_ID
5. Check that no "waiting for Hedera" banner appears.

## The story
| Time | Role | Do | Say |
|---|---|---|---|
| 0:00 | - | Show the dashboard and the map | "Food surplus is not the problem. Coordinating it before it expires, and proving it happened, is." |
| 0:30 | Donor | Click a donor on the map, Create donation | "The donor declares a surplus. It is signed by the donor's own Hedera account." |
| 1:00 | Donor | Find rescue match | "The backend removes every NGO and volunteer that cannot do the job. The AI only chooses among safe options." |
| 1:45 | Donor | Accept mission | "The coordinator signs the match." |
| 2:00 | Volunteer | Start pickup | "The volunteer accepts with their own account and drives to the donor." |
| 2:20 | Volunteer | Enter the QR code, Confirm pickup | "A handoff needs two signatures. The volunteer has signed, the donor has not." |
| 2:40 | Donor | Confirm handover | "Now both sides signed. Only then does the food count as picked up." |
| 3:00 | Volunteer | Hand over to the NGO | "Second handoff, same rule." |
| 3:20 | NGO | Enter the code and the quantity, Confirm delivery | "The NGO confirms what it actually received." |
| 3:45 | Dashboard | Open the Impact receipt, Verify on Hedera | "Now you do not have to trust our database." |
| 4:15 | Verify page + HashScan | Show 7 verified rows and the different signer accounts, then the topic page | "Each step is signed by its own account. Only registered accounts can write to this topic. AI decides who should act, Hedera proves what actually happened." |

## If something breaks
- **AI slow or Ollama down**: the match still appears and says "Deterministic fallback used". Say it out loud, it proves the backend is the authority.
- **Hedera slow or down**: the app shows "Pending verification" and a Retry now button.
- **Total failure**: open the HashScan tab and your screenshots of the previous run.
- **Clean slate mid-demo**: run the reset command in a second terminal, then refresh.

## Stretch features to point at
- **Map**: the volunteer drives to the donor, then to the NGO, then back home. Several missions can run at once.
- **QR label**: the receiver (volunteer, NGO) must enter or scan the code. A wrong code is refused.
- **Verified track record** (bottom of the page): built only from deliveries confirmed on Hedera. It survives a reset.
- **Tamper test** (optional): change one character of `payload_hash` in Supabase and reload the Verify page. That row turns red.

## Demo on several screens
- Open the app on the laptop (Donor) and on two phones or tabs, one as a volunteer and one as the NGO. Pick the person in each **Acting as** list. The choice is remembered per device.
- Screens refresh every 4 seconds, so the volunteer sees the mission appear a moment after the donor accepts it.
- Show **Join as a volunteer**: type a name, click the map for the home position, create. Their own Hedera account appears in the message.
- Phones need the laptop's address (for example `http://192.168.x.x:3000`) on the same Wi-Fi. Allow the camera for the QR scan, which only works on `localhost` or HTTPS, so use manual code entry on phones.
'@

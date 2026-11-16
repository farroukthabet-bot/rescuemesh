# RescueMesh: one Hedera account per actor, topic submit key, two-party handoffs.
# 1) Run supabase\phase12.sql in Supabase FIRST.
# 2) Add KEY_ENCRYPTION_SECRET to .env.local (see the chat message).
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-phase12.ps1
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
function clientFor(s: Signer): Client {
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

Write-File 'lib/hedera/events.ts' @'
import { supabase } from "@/lib/db/supabase";
import { submitToTopic } from "./hcs";
import { getSigner } from "./keystore";

export type EventType =
  | "DONATION_CREATED"
  | "NGO_MATCHED"
  | "VOLUNTEER_ASSIGNED"
  | "DONOR_HANDOVER_CONFIRMED"
  | "PICKUP_CONFIRMED"
  | "DROPOFF_CONFIRMED"
  | "DELIVERY_CONFIRMED"
  | "IMPACT_VERIFIED";

/**
 * Records a critical event on Hedera (HCS) and logs the references in hedera_events.
 * - Idempotent: one event per (donationId, eventType). Already CONFIRMED -> returned as is.
 * - Never throws on Hedera failure: the row is saved as PENDING so the app keeps working.
 * - Only put non-personal data in `data` (it goes on a public ledger).
 * - `actorId` decides WHO signs: the message is sent from that actor's own Hedera account
 *   (DONOR-01, NGO-02, VOL-03 ...) or from PLATFORM for decisions taken by the coordinator.
 */
export async function recordEvent(
  donationId: string,
  eventType: EventType,
  actorId: string,
  data: Record<string, unknown> = {}
) {
  const { data: existing } = await supabase
    .from("hedera_events")
    .select("*")
    .eq("donation_id", donationId)
    .eq("event_type", eventType)
    .maybeSingle();

  if (existing?.status === "CONFIRMED") return existing;

  let payload: Record<string, unknown> = {
    event: eventType,
    donationId,
    actor: actorId,
    ...data,
    timestamp: new Date().toISOString(),
  };

  let row: Record<string, unknown>;
  try {
    const signer = await getSigner(actorId);
    payload = { ...payload, signer: signer.accountId };
    const r = await submitToTopic(payload, signer);
    row = {
      donation_id: donationId,
      event_type: eventType,
      actor_id: actorId,
      signer_account_id: r.signerAccountId,
      hedera_topic_id: r.topicId,
      hedera_sequence_number: r.sequenceNumber,
      hedera_consensus_timestamp: r.consensusTimestamp,
      hedera_transaction_id: r.transactionId,
      payload_hash: r.payloadHash,
      payload,
      status: "CONFIRMED",
    };
  } catch (err) {
    console.error(`[hedera] ${eventType} (${actorId}) failed for ${donationId}:`, err);
    // Keep the payload so the event can be re-sent later with its original content and time.
    row = { donation_id: donationId, event_type: eventType, actor_id: actorId, payload, status: "PENDING" };
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
      const signer = await getSigner(row.actor_id ?? "PLATFORM");
      const base = row.payload ?? { event: row.event_type, donationId: row.donation_id, timestamp: row.created_at };
      const payload = { ...base, signer: signer.accountId };
      const r = await submitToTopic(payload, signer);
      await supabase
        .from("hedera_events")
        .update({
          signer_account_id: r.signerAccountId,
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

  // The match is the coordinator's decision, so the platform account signs it.
  // The volunteer signs their own acceptance later, when they press Start pickup.
  const matched = await recordEvent(donationId, "NGO_MATCHED", "PLATFORM", { ngoId, volunteerId, matchScore: pair.score });

  return { httpStatus: 201, mission, hedera: matched };
}


/** Which event types already exist for this donation (counted even if still PENDING on Hedera). */
async function eventTypes(donationId: string): Promise<Set<string>> {
  const { data } = await supabase.from("hedera_events").select("event_type").eq("donation_id", donationId);
  return new Set((data ?? []).map((e) => e.event_type as string));
}

// ---------------------------------------------------------------- START (the volunteer accepts and leaves)
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

  // The volunteer's own account signs the acceptance of the mission.
  const hedera = await recordEvent(donationId, "VOLUNTEER_ASSIGNED", volunteerId, { volunteerId });
  return { httpStatus: 200, mission: updated, hedera };
}

// ---------------------------------------------------------------- HANDOFF 1: donor -> volunteer (two signatures)
async function finishPickup(donationId: string, missionId: string) {
  const have = await eventTypes(donationId);
  if (!(have.has("DONOR_HANDOVER_CONFIRMED") && have.has("PICKUP_CONFIRMED"))) return { complete: false as const };

  const moved = await moveStatus(donationId, "PICKUP_PENDING", "PICKED_UP");
  if (!moved) return { complete: true as const }; // another request already finished it

  const { data: mission, error } = await supabase
    .from("missions")
    .update({ status: "PICKED_UP", pickup_at: new Date().toISOString() })
    .eq("id", missionId)
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "PICKED_UP", "PICKUP_PENDING"); // never leave donation and mission out of sync
    return { complete: false as const, error: `Could not update the mission: ${error.message}` };
  }
  return { complete: true as const, mission };
}

export async function donorHandover(donationId: string, donorId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.donor_id !== donorId)
    return { httpStatus: 403, error: "Only the donor of this donation can confirm the handover" };
  if (donation.status !== "PICKUP_PENDING" || mission.status !== "EN_ROUTE")
    return { httpStatus: 409, error: "The volunteer has not started the pickup yet, or the handover is already complete" };
  if ((await eventTypes(donationId)).has("DONOR_HANDOVER_CONFIRMED"))
    return { httpStatus: 409, error: "You already confirmed the handover" };

  const hedera = await recordEvent(donationId, "DONOR_HANDOVER_CONFIRMED", donorId, { confirmedBy: donorId });
  const f = await finishPickup(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, pickupComplete: f.complete };
}

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
  if ((await eventTypes(donationId)).has("PICKUP_CONFIRMED"))
    return { httpStatus: 409, error: "You already confirmed the pickup" };

  const hedera = await recordEvent(donationId, "PICKUP_CONFIRMED", volunteerId, { confirmedBy: volunteerId, qrScanned: true });
  const f = await finishPickup(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, pickupComplete: f.complete };
}

// ---------------------------------------------------------------- HANDOFF 2: volunteer -> NGO (two signatures)
async function finishDelivery(donationId: string, missionId: string) {
  const have = await eventTypes(donationId);
  if (!(have.has("DROPOFF_CONFIRMED") && have.has("DELIVERY_CONFIRMED"))) return { complete: false as const };

  const moved = await moveStatus(donationId, "PICKED_UP", "COMPLETED");
  if (!moved) return { complete: true as const };

  const { data: mission, error } = await supabase
    .from("missions")
    .update({ status: "COMPLETED", delivery_at: new Date().toISOString() })
    .eq("id", missionId)
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "COMPLETED", "PICKED_UP");
    return { complete: false as const, error: `Could not update the mission: ${error.message}` };
  }
  return { complete: true as const, mission };
}

export async function volunteerDropoff(donationId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can confirm the drop-off" };
  if (donation.status !== "PICKED_UP")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKED_UP` };
  if ((await eventTypes(donationId)).has("DROPOFF_CONFIRMED"))
    return { httpStatus: 409, error: "You already confirmed the drop-off" };

  const hedera = await recordEvent(donationId, "DROPOFF_CONFIRMED", volunteerId, { confirmedBy: volunteerId });
  const f = await finishDelivery(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, deliveryComplete: f.complete };
}

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
  if ((await eventTypes(donationId)).has("DELIVERY_CONFIRMED"))
    return { httpStatus: 409, error: "You already confirmed the delivery" };

  // Store what was really received first: if this fails, nothing else has happened yet.
  const { error: qErr } = await supabase.from("missions").update({ received_kg: quantityReceivedKg }).eq("id", mission.id);
  if (qErr) return { httpStatus: 500, error: `Could not save the received quantity: ${qErr.message}. Did you run supabase/phase10.sql?` };

  const hedera = await recordEvent(donationId, "DELIVERY_CONFIRMED", ngoId, {
    confirmedBy: ngoId, quantityReceivedKg, quantityDonatedKg: Number(donation.quantity_kg), qrScanned: true,
  });
  const f = await finishDelivery(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, deliveryComplete: f.complete };
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
  const hedera = await recordEvent(id, "DONATION_CREATED", donor.id, {
    donorId: donor.id,
    foodType: d.foodType,
    quantityKg: d.quantityKg,
    status: "AVAILABLE",
  });

  return NextResponse.json({ donation, hedera }, { status: 201 });
}
'@

Write-File 'app/api/donations/[id]/handover/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { donorHandover } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ donorId: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await donorHandover(id, body.data.donorId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/dropoff/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { volunteerDropoff } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ volunteerId: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await volunteerDropoff(id, body.data.volunteerId);
  return NextResponse.json(res, { status: httpStatus });
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

  // Attach the event types already recorded per donation (the UI uses them to show "waiting for ...").
  const ids = (data ?? []).map((m) => m.donation_id as string);
  const { data: ev } = ids.length
    ? await supabase.from("hedera_events").select("donation_id, event_type").in("donation_id", ids)
    : { data: [] as { donation_id: string; event_type: string }[] };
  const byDonation = new Map<string, string[]>();
  for (const e of ev ?? []) byDonation.set(e.donation_id, [...(byDonation.get(e.donation_id) ?? []), e.event_type]);

  return NextResponse.json((data ?? []).map((m) => ({ ...m, events: byDonation.get(m.donation_id) ?? [] })));
}
'@

Write-File 'app/verify/[id]/page.tsx' @'
import Link from "next/link";
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
    <main className="min-h-screen bg-[#F4F7FB] text-[#0E2237]">
      <div className="mx-auto max-w-2xl px-5 py-10">
        <Link href="/" className="text-sm text-[#2A3EB1] underline underline-offset-2">Back to dashboard</Link>
        <h1 className="mt-4 font-[family-name:var(--font-heading)] text-4xl font-semibold tracking-tight">Donation {id}</h1>
        <p className="mt-1 text-[#0E2237]/70">{donation.quantity_kg} kg of {String(donation.food_type).toLowerCase()}, currently {String(donation.status).toLowerCase().replace(/_/g, " ")}.</p>

        <p className={`mt-6 inline-block px-3 py-1.5 font-[family-name:var(--font-heading)] text-lg font-semibold ${allVerified ? "bg-[#0F7B6C] text-white" : "bg-[#FDEFC4] text-[#7A5200]"}`}>
          {allVerified ? "Verified by Hedera" : "Not fully verified yet"}
        </p>

        <ol className="mt-8 border-l-2 border-[#0E2237]/25">
          {steps.map(([type, title], i) => {
            const c = checks[i];
            const ev = byType.get(type);
            const ok = c.state === "verified";
            const sg = signer(ev, c);
            return (
              <li key={type} className="relative pb-7 pl-6">
                <span aria-hidden className={`absolute -left-[9px] top-1 h-4 w-4 rounded-full border-2 ${ok ? "border-[#0F7B6C] bg-[#0F7B6C]" : "border-[#0E2237]/40 bg-[#F4F7FB]"}`} />
                <p className="font-medium">{title}</p>
                <p className="text-sm text-[#0E2237]/65">
                  {c.consensus ? `${time(c.consensus)}, ` : ""}{LABEL[c.state]}
                </p>
                {sg && (
                  <p className="text-sm text-[#0E2237]/65">
                    {sg.onBehalf ? `Signed by the platform on behalf of ${sg.who}` : `Signed by ${sg.who}`}
                    {sg.acct && (
                      <>
                        {" "}(<a className="font-mono text-[#2A3EB1] underline underline-offset-2" href={`https://hashscan.io/testnet/account/${sg.acct}`} target="_blank" rel="noreferrer">{sg.acct}</a>)
                      </>
                    )}
                  </p>
                )}
                {ev?.hedera_sequence_number && (
                  <p className="mt-0.5 font-mono text-xs text-[#0E2237]/55">sequence {ev.hedera_sequence_number}</p>
                )}
              </li>
            );
          })}
        </ol>

        <div className="mt-2 border-t border-[#0E2237]/15 pt-5 text-sm">
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
              <a className="text-[#2A3EB1] underline underline-offset-2" href={`https://hashscan.io/testnet/topic/${topic}`} target="_blank" rel="noreferrer">
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

Write-File 'app/page.tsx' @'
"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
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

  // Donor side of the pickup handoff: the volunteer is on the way and the donor has not signed yet.
  const handovers = missions.filter((m) => ms(m) === "EN_ROUTE" && !(m.events ?? []).includes("DONOR_HANDOVER_CONFIRMED"));

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
                {missions.filter((m) => ["PICKUP_PENDING", "EN_ROUTE", "PICKED_UP"].includes(ms(m))).length === 0 && (
                  <p className="mt-3 text-sm text-[#0E2237]/65">No missions waiting. As a donor, create a donation and accept a match first.</p>
                )}
                {missions.filter((m) => ["PICKUP_PENDING", "EN_ROUTE", "PICKED_UP"].includes(ms(m))).map((m) => {
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
                {missions.filter((m) => ms(m) === "PICKED_UP").length === 0 && (
                  <p className="mt-3 text-sm text-[#0E2237]/65">Nothing on the way yet. Deliveries appear here once the donor and the volunteer have both confirmed the pickup.</p>
                )}
                {missions.filter((m) => ms(m) === "PICKED_UP").map((m) => {
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

Write-File 'scripts/setup-actors.mjs' @'
// Creates one Hedera testnet account per actor (donors, NGOs, volunteers) and stores the keys encrypted.
// Run once:  node --env-file=.env.local scripts/setup-actors.mjs
// Safe to re-run: actors that already have an account are skipped.
import crypto from "node:crypto";
import { AccountCreateTransaction, Client, Hbar, PrivateKey } from "@hashgraph/sdk";
import { createClient } from "@supabase/supabase-js";

const need = (k) => { if (!process.env[k]) throw new Error(`${k} is missing in .env.local`); return process.env[k]; };
const secretHex = need("KEY_ENCRYPTION_SECRET");
if (!/^[0-9a-fA-F]{64}$/.test(secretHex)) throw new Error("KEY_ENCRYPTION_SECRET must be 64 hex characters");
const secret = Buffer.from(secretHex, "hex");

const client = Client.forTestnet().setOperator(need("HEDERA_ACCOUNT_ID"), PrivateKey.fromStringECDSA(need("HEDERA_PRIVATE_KEY")));
const db = createClient(need("SUPABASE_URL"), need("SUPABASE_SERVICE_KEY"), { auth: { persistSession: false } });

// Format: iv:authTag:ciphertext (base64). Must match lib/hedera/keystore.ts.
function encrypt(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", secret, iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString("base64")).join(":");
}

const [{ data: orgs, error: e1 }, { data: vols, error: e2 }, { data: have, error: e3 }] = await Promise.all([
  db.from("organizations").select("id, name"),
  db.from("volunteers").select("id, name"),
  db.from("actor_accounts").select("actor_id"),
]);
if (e1 || e2 || e3) throw new Error((e1 || e2 || e3).message + "  (did you run supabase/phase12.sql?)");

const done = new Set(have.map((h) => h.actor_id));
const actors = [...orgs, ...vols];

for (const a of actors) {
  if (done.has(a.id)) { console.log("skip   ", a.id, "(already has an account)"); continue; }
  const key = PrivateKey.generateECDSA();
  const tx = await new AccountCreateTransaction()
    .setKeyWithoutAlias(key.publicKey)
    .setInitialBalance(new Hbar(3))                  // testnet HBAR, plenty for thousands of messages
    .setAccountMemo(`RescueMesh ${a.id}`)            // IDs only: real business names are not put on a public ledger
    .execute(client);
  const accountId = (await tx.getReceipt(client)).accountId.toString();
  const { error } = await db.from("actor_accounts").insert({
    actor_id: a.id,
    hedera_account_id: accountId,
    public_key: key.publicKey.toStringDer(),
    encrypted_private_key: encrypt(key.toStringDer()),
  });
  if (error) throw new Error(error.message);
  console.log("created ", a.id.padEnd(9), "->", accountId);
}
console.log("\nDone. Now create the restricted topic:  node --env-file=.env.local scripts/create-topic.mjs");
process.exit(0);
'@

Write-File 'scripts/create-topic.mjs' @'
// Creates the RescueMesh HCS topic.
// If actor accounts exist (scripts/setup-actors.mjs), the topic gets a SUBMIT KEY: only the platform account and
// the registered actors can write to it. Otherwise it is an open topic (anyone can post).
// Run:  node --env-file=.env.local scripts/create-topic.mjs
import { Client, KeyList, PrivateKey, PublicKey, TopicCreateTransaction } from "@hashgraph/sdk";
import { createClient } from "@supabase/supabase-js";

const need = (k) => { if (!process.env[k]) throw new Error(`${k} is missing in .env.local`); return process.env[k]; };
const operatorKey = PrivateKey.fromStringECDSA(need("HEDERA_PRIVATE_KEY"));
const client = Client.forTestnet().setOperator(need("HEDERA_ACCOUNT_ID"), operatorKey);
const db = createClient(need("SUPABASE_URL"), need("SUPABASE_SERVICE_KEY"), { auth: { persistSession: false } });

const { data: actors } = await db.from("actor_accounts").select("actor_id, public_key");

let tx = new TopicCreateTransaction()
  .setTopicMemo("RescueMesh Events")
  .setAdminKey(operatorKey.publicKey); // the platform can update the list of allowed writers later

if (actors && actors.length > 0) {
  const keys = [operatorKey.publicKey, ...actors.map((a) => PublicKey.fromString(a.public_key))];
  tx = tx.setSubmitKey(new KeyList(keys, 1)); // threshold 1: a message is accepted if ANY ONE of these accounts signs it
  console.log(`Submit key: platform + ${actors.length} registered actors (any one of them may post).`);
} else {
  console.warn("WARNING: no actor accounts found, creating an OPEN topic. Run scripts/setup-actors.mjs first.");
}

const receipt = await (await tx.execute(client)).getReceipt(client);
console.log("HEDERA_TOPIC_ID=" + receipt.topicId.toString());
process.exit(0);
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
'@

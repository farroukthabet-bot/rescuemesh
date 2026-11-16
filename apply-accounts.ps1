# RescueMesh: accounts and roles, admin console, volunteer applications, offers with decline.
# BEFORE running: 1) run supabase\phase14.sql  2) add SUPABASE_ANON_KEY and SESSION_SECRET to .env.local
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-accounts.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}









Write-File 'lib/auth.ts' @'
import crypto from "crypto";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { supabase } from "@/lib/db/supabase";

export type Role = "ADMIN" | "DONOR" | "NGO" | "VOLUNTEER";
export type Membership = { id: number; role: Role; actor_id: string | null; status: "PENDING" | "ACTIVE" | "REJECTED" };
export type AuthInfo = { userId: string; email: string; name: string; isAdmin: boolean; memberships: Membership[] };

// Passwords are checked by Supabase Auth. After that we only keep a small signed cookie (HMAC-SHA256, 7 days).
const COOKIE = "rm_session";
const MAX_AGE = 60 * 60 * 24 * 7;

function secret(): Buffer {
  const hex = process.env.SESSION_SECRET ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("SESSION_SECRET must be 64 hex characters (see .env.local)");
  return Buffer.from(hex, "hex");
}
const sign = (body: string) => crypto.createHmac("sha256", secret()).update(body).digest("base64url");

function makeToken(userId: string): string {
  const body = Buffer.from(JSON.stringify({ u: userId, e: Math.floor(Date.now() / 1000) + MAX_AGE })).toString("base64url");
  return `${body}.${sign(body)}`;
}

function readToken(token: string | undefined): string | null {
  if (!token) return null;
  const [body, mac] = token.split(".");
  if (!body || !mac) return null;
  const a = Buffer.from(mac), b = Buffer.from(sign(body));
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const p = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    return typeof p.u === "string" && p.e > Date.now() / 1000 ? p.u : null;
  } catch {
    return null;
  }
}

export async function setSession(userId: string) {
  (await cookies()).set(COOKIE, makeToken(userId), {
    httpOnly: true, sameSite: "lax", secure: process.env.NODE_ENV === "production", path: "/", maxAge: MAX_AGE,
  });
}
export async function clearSession() { (await cookies()).delete(COOKIE); }

/** The signed-in person, with their roles, or null. Always read from the database, never from the browser. */
export async function getAuth(): Promise<AuthInfo | null> {
  const uid = readToken((await cookies()).get(COOKIE)?.value);
  if (!uid) return null;
  const [{ data: profile }, { data: ms }] = await Promise.all([
    supabase.from("profiles").select("*").eq("user_id", uid).maybeSingle(),
    supabase.from("memberships").select("*").eq("user_id", uid),
  ]);
  if (!profile) return null;
  const memberships = (ms ?? []) as Membership[];
  return {
    userId: uid, email: profile.email, name: profile.display_name,
    isAdmin: memberships.some((m) => m.role === "ADMIN" && m.status === "ACTIVE"),
    memberships,
  };
}

type Gate = { ok: true; auth: AuthInfo; actorId: string | null } | { ok: false; res: NextResponse };

/** Use at the top of every API route. `role` = the role this action needs. The actor id comes from the account, never from the request. */
export async function authorize(role?: Role): Promise<Gate> {
  const auth = await getAuth();
  if (!auth) return { ok: false, res: NextResponse.json({ error: "Please sign in" }, { status: 401 }) };
  if (!role) return { ok: true, auth, actorId: null };
  const m = auth.memberships.find((x) => x.role === role && x.status === "ACTIVE");
  if (!m) return { ok: false, res: NextResponse.json({ error: `This action needs the ${role.toLowerCase()} role` }, { status: 403 }) };
  return { ok: true, auth, actorId: m.actor_id };
}

/** Returns the user id if the email and password are right, otherwise null. */
export async function checkPassword(email: string, password: string): Promise<string | null> {
  const key = process.env.SUPABASE_ANON_KEY;
  if (!key) throw new Error("SUPABASE_ANON_KEY is missing in .env.local (the publishable key)");
  const anon = createClient(process.env.SUPABASE_URL!, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await anon.auth.signInWithPassword({ email, password });
  return error || !data.user ? null : data.user.id;
}

/** Creates a confirmed login (no email is sent) and its profile. */
export async function createLogin(email: string, password: string, name: string): Promise<{ userId: string } | { error: string }> {
  const mail = email.trim().toLowerCase();
  const { data, error } = await supabase.auth.admin.createUser({ email: mail, password, email_confirm: true, user_metadata: { name } });
  if (error || !data.user) return { error: error?.message ?? "Could not create the account" };
  const { error: pErr } = await supabase.from("profiles").insert({ user_id: data.user.id, email: mail, display_name: name });
  if (pErr) {
    await supabase.auth.admin.deleteUser(data.user.id);
    return { error: pErr.message };
  }
  return { userId: data.user.id };
}
'@

Write-File 'lib/actors.ts' @'
import { supabase } from "@/lib/db/supabase";
import { MAP, geoToPixel } from "@/lib/map/calibration";
import { createActorAccount, refreshSubmitKey } from "@/lib/hedera/onboard";

const MAX_ACTORS = Number(process.env.MAX_ACTORS ?? 60); // every actor costs the platform a few test HBAR

export const insideMap = (lat: number, lng: number) => {
  const p = geoToPixel(lat, lng);
  return p.x >= 0 && p.y >= 0 && p.x <= MAP.width && p.y <= MAP.height;
};

async function nextId(table: "organizations" | "volunteers", prefix: string): Promise<string> {
  const { data } = await supabase.from(table).select("id");
  const last = Math.max(0, ...(data ?? []).filter((r) => String(r.id).startsWith(prefix + "-")).map((r) => parseInt(String(r.id).slice(prefix.length + 1), 10) || 0));
  return `${prefix}-${String(last + 1).padStart(2, "0")}`;
}

async function checkCap() {
  const [{ count: a }, { count: b }] = await Promise.all([
    supabase.from("organizations").select("id", { count: "exact", head: true }),
    supabase.from("volunteers").select("id", { count: "exact", head: true }),
  ]);
  if ((a ?? 0) + (b ?? 0) >= MAX_ACTORS) throw new Error(`Actor limit reached (${MAX_ACTORS}) for this demo`);
}

// Call these inside exclusive() from lib/hedera/onboard so two creations never overlap.

export async function createVolunteerActor(v: {
  name: string; transportType: string; capacityKg: number; coldStorage: boolean; latitude: number; longitude: number;
}) {
  await checkCap();
  const id = await nextId("volunteers", "VOL");
  const accountId = await createActorAccount(id);
  const { error } = await supabase.from("volunteers").insert({
    id, name: v.name, latitude: v.latitude, longitude: v.longitude, transport_type: v.transportType,
    transport_capacity_kg: v.capacityKg, has_cold_storage: v.coldStorage, available: true,
  });
  if (error) {
    await supabase.from("actor_accounts").delete().eq("actor_id", id);
    throw new Error(error.message);
  }
  return { id, accountId, warning: await topicWarning() };
}

export async function createPlaceActor(kind: "DONOR" | "NGO", p: {
  name: string; latitude: number; longitude: number; capacityKg?: number; coldStorage?: boolean; demand?: "low" | "medium" | "high"; contactName?: string;
}) {
  await checkCap();
  const id = await nextId("organizations", kind);
  const accountId = await createActorAccount(id);
  const { error } = await supabase.from("organizations").insert({
    id, name: p.name, type: kind, latitude: p.latitude, longitude: p.longitude,
    storage_capacity_kg: kind === "NGO" ? p.capacityKg ?? 0 : 0,
    has_cold_storage: kind === "NGO" ? !!p.coldStorage : false,
    current_demand: kind === "NGO" ? p.demand ?? "medium" : null,
    contact_name: p.contactName ?? null,
  });
  if (error) {
    await supabase.from("actor_accounts").delete().eq("actor_id", id);
    throw new Error(error.message);
  }
  return { id, accountId, warning: await topicWarning() };
}

async function topicWarning(): Promise<string | undefined> {
  try {
    await refreshSubmitKey();
    return undefined;
  } catch (e) {
    console.error("[onboard] topic key update failed:", e);
    return "The Hedera account exists, but the topic could not be updated, so its events will stay pending. Create a new topic with scripts/create-topic.mjs.";
  }
}
'@

Write-File 'lib/requests.ts' @'
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";

export const ApplicationFields = {
  name: z.string().trim().min(2).max(40),
  transportType: z.enum(["Bike", "Scooter", "Car", "Van"]),
  capacityKg: z.number().positive().max(1000),
  coldStorage: z.boolean(),
  latitude: z.number(),
  longitude: z.number(),
};
export type Application = { name: string; transportType: string; capacityKg: number; coldStorage: boolean; latitude: number; longitude: number };

/** Records a volunteer application. The volunteer only exists (with a Hedera account) once an administrator approves it. */
export async function submitApplication(userId: string, a: Application): Promise<{ ok: true } | { ok: false; status: number; error: string }> {
  const { data: existing } = await supabase.from("memberships").select("*").eq("user_id", userId).eq("role", "VOLUNTEER").maybeSingle();
  if (existing && existing.status !== "REJECTED")
    return { ok: false, status: 409, error: existing.status === "ACTIVE" ? "You are already a volunteer" : "Your application is already waiting for approval" };

  const { error } = await supabase.from("volunteer_requests").insert({
    user_id: userId, name: a.name, transport_type: a.transportType, transport_capacity_kg: a.capacityKg,
    has_cold_storage: a.coldStorage, latitude: a.latitude, longitude: a.longitude,
  });
  if (error) return { ok: false, status: 500, error: error.message };

  const m = existing
    ? await supabase.from("memberships").update({ status: "PENDING", actor_id: null }).eq("id", existing.id)
    : await supabase.from("memberships").insert({ user_id: userId, role: "VOLUNTEER", status: "PENDING" });
  if (m.error) return { ok: false, status: 500, error: m.error.message };
  return { ok: true };
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

/** Event type -> which login signed it (counted even if still PENDING on Hedera). */
async function eventUsers(donationId: string): Promise<Map<string, string | null>> {
  const { data } = await supabase.from("hedera_events").select("event_type, signed_by_user").eq("donation_id", donationId);
  return new Map((data ?? []).map((e) => [e.event_type as string, (e.signed_by_user as string | null) ?? null]));
}
const SAME_PERSON = "The same person cannot sign both sides of a handoff. Use a different account for the other party.";

/** Atomic status change: only succeeds if the donation is still in the `from` status. */
async function moveStatus(id: string, from: string, to: string) {
  const { data } = await supabase.from("donations").update({ status: to }).eq("id", id).eq("status", from).select("id");
  return (data?.length ?? 0) === 1;
}

// ---------------------------------------------------------------- OFFER (the donor accepts the AI match)
// The match becomes an OFFER to one volunteer. Nothing is written to Hedera yet: only confirmed facts go on the ledger.
export async function acceptMission(donationId: string, ngoId: string, volunteerId: string, donorId: string) {
  const donation = await getDonation(donationId);
  if (!donation) return { httpStatus: 404, error: "Donation not found" };
  if (donation.donor_id !== donorId) return { httpStatus: 403, error: "This is not your donation" };
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

  if (!(await moveStatus(donationId, "AVAILABLE", "MATCHED")))
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
      status: "OFFERED",
      offer_number: 1,
    })
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "MATCHED", "AVAILABLE"); // roll back
    return { httpStatus: 500, error: error.message };
  }
  return { httpStatus: 201, mission };
}

// ---------------------------------------------------------------- ACCEPT THE OFFER AND START (the volunteer)
export async function startPickup(donationId: string, volunteerId: string, userId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "This offer is not for you" };
  if (donation.status !== "MATCHED" || mission.status !== "OFFERED")
    return { httpStatus: 409, error: "There is no open offer to accept (it may have been withdrawn)" };

  if (!(await moveStatus(donationId, "MATCHED", "PICKUP_PENDING")))
    return { httpStatus: 409, error: "This offer was just changed" };

  const { data: updated, error } = await supabase
    .from("missions")
    .update({ status: "EN_ROUTE", accepted_at: new Date().toISOString() })
    .eq("id", mission.id)
    .eq("status", "OFFERED")
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "PICKUP_PENDING", "MATCHED");
    return { httpStatus: 500, error: error.message };
  }

  // Only now is anything confirmed: the platform signs the match, the volunteer signs the acceptance with their own account.
  const matched = await recordEvent(donationId, "NGO_MATCHED", "PLATFORM", {
    ngoId: mission.ngo_id, volunteerId, matchScore: mission.match_score, offerNumber: mission.offer_number,
  });
  const assigned = await recordEvent(donationId, "VOLUNTEER_ASSIGNED", volunteerId, { volunteerId }, userId);
  return { httpStatus: 200, mission: updated, hedera: [matched, assigned] };
}

// ---------------------------------------------------------------- DECLINE THE OFFER (the volunteer)
// The offer goes to the next best volunteer for the same NGO. If nobody else fits, the donation becomes AVAILABLE again.
export async function declineOffer(donationId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (mission.volunteer_id !== volunteerId) return { httpStatus: 403, error: "This offer is not for you" };
  if (donation.status !== "MATCHED" || mission.status !== "OFFERED")
    return { httpStatus: 409, error: "There is no open offer to decline" };

  const { error: dErr } = await supabase.from("mission_declines").insert({ donation_id: donationId, volunteer_id: volunteerId });
  if (dErr) return { httpStatus: 500, error: `${dErr.message}. Did you run supabase/phase14.sql?` };

  const [{ data: declines }, { data: ngos }, { data: vols }] = await Promise.all([
    supabase.from("mission_declines").select("volunteer_id").eq("donation_id", donationId),
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);
  const declined = new Set((declines ?? []).map((d) => d.volunteer_id as string));
  const busy = await busyVolunteerIds(); // includes everybody with an open offer or a mission, and the one who just declined
  const crew = (vols ?? []).map((v) => (busy.has(v.id) || declined.has(v.id) ? { ...v, available: false, busy: true } : v)) as Volunteer[];
  const next = evaluate(donation as Donation, (ngos ?? []) as Ngo[], crew).candidates.find((c) => c.ngo.id === mission.ngo_id);

  if (next) {
    const { error } = await supabase
      .from("missions")
      .update({
        volunteer_id: next.volunteer.id, offer_number: Number(mission.offer_number ?? 1) + 1, match_score: next.score,
        estimated_pickup_minutes: next.estimatedPickupMinutes, estimated_delivery_minutes: next.estimatedDeliveryMinutes,
      })
      .eq("id", mission.id)
      .eq("status", "OFFERED");
    if (error) return { httpStatus: 500, error: error.message };
    return { httpStatus: 200, reoffered: true, offeredTo: next.volunteer.name };
  }

  // Nobody else fits this NGO: close the offer and give the donation back to the donor.
  await supabase.from("missions").delete().eq("id", mission.id);
  await moveStatus(donationId, "MATCHED", "AVAILABLE");
  return { httpStatus: 200, reoffered: false };
}

// ---------------------------------------------------------------- HANDOFF 1: donor -> volunteer (two signatures)
async function finishPickup(donationId: string, missionId: string) {
  const have = await eventUsers(donationId);
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

export async function donorHandover(donationId: string, donorId: string, userId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.donor_id !== donorId)
    return { httpStatus: 403, error: "Only the donor of this donation can confirm the handover" };
  if (donation.status !== "PICKUP_PENDING" || mission.status !== "EN_ROUTE")
    return { httpStatus: 409, error: "The volunteer has not accepted and started yet, or the handover is already complete" };
  const users = await eventUsers(donationId);
  if (users.has("DONOR_HANDOVER_CONFIRMED")) return { httpStatus: 409, error: "You already confirmed the handover" };
  if (users.get("PICKUP_CONFIRMED") === userId) return { httpStatus: 403, error: SAME_PERSON };

  const hedera = await recordEvent(donationId, "DONOR_HANDOVER_CONFIRMED", donorId, { confirmedBy: donorId }, userId);
  const f = await finishPickup(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, pickupComplete: f.complete };
}

export async function confirmPickup(donationId: string, volunteerId: string, code: string, userId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKUP_PENDING")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKUP_PENDING` };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can confirm pickup" };
  if (mission.status !== "EN_ROUTE")
    return { httpStatus: 409, error: "Accept the offer first, then confirm the pickup on arrival" };
  if (code.trim().toUpperCase() !== donationId)
    return { httpStatus: 400, error: "The scanned QR code does not match this donation" };
  const users = await eventUsers(donationId);
  if (users.has("PICKUP_CONFIRMED")) return { httpStatus: 409, error: "You already confirmed the pickup" };
  if (users.get("DONOR_HANDOVER_CONFIRMED") === userId) return { httpStatus: 403, error: SAME_PERSON };

  const hedera = await recordEvent(donationId, "PICKUP_CONFIRMED", volunteerId, { confirmedBy: volunteerId, qrScanned: true }, userId);
  const f = await finishPickup(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, pickupComplete: f.complete };
}

// ---------------------------------------------------------------- HANDOFF 2: volunteer -> NGO (two signatures)
async function finishDelivery(donationId: string, missionId: string) {
  const have = await eventUsers(donationId);
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

export async function volunteerDropoff(donationId: string, volunteerId: string, userId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can confirm the drop-off" };
  if (donation.status !== "PICKED_UP")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKED_UP` };
  const users = await eventUsers(donationId);
  if (users.has("DROPOFF_CONFIRMED")) return { httpStatus: 409, error: "You already confirmed the drop-off" };
  if (users.get("DELIVERY_CONFIRMED") === userId) return { httpStatus: 403, error: SAME_PERSON };

  const hedera = await recordEvent(donationId, "DROPOFF_CONFIRMED", volunteerId, { confirmedBy: volunteerId }, userId);
  const f = await finishDelivery(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, deliveryComplete: f.complete };
}

export async function confirmDelivery(donationId: string, ngoId: string, quantityReceivedKg: number, code: string, userId: string) {
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
  const users = await eventUsers(donationId);
  if (users.has("DELIVERY_CONFIRMED")) return { httpStatus: 409, error: "You already confirmed the delivery" };
  if (users.get("DROPOFF_CONFIRMED") === userId) return { httpStatus: 403, error: SAME_PERSON };

  // Store what was really received first: if this fails, nothing else has happened yet.
  const { error: qErr } = await supabase.from("missions").update({ received_kg: quantityReceivedKg }).eq("id", mission.id);
  if (qErr) return { httpStatus: 500, error: `Could not save the received quantity: ${qErr.message}. Did you run supabase/phase10.sql?` };

  const hedera = await recordEvent(donationId, "DELIVERY_CONFIRMED", ngoId, {
    confirmedBy: ngoId, quantityReceivedKg, quantityDonatedKg: Number(donation.quantity_kg), qrScanned: true,
  }, userId);
  const f = await finishDelivery(donationId, mission.id);
  if ("error" in f && f.error) return { httpStatus: 500, error: f.error };
  return { httpStatus: 200, hedera, deliveryComplete: f.complete };
}
'@

Write-File 'lib/busy.ts' @'
import { supabase } from "@/lib/db/supabase";

/** Volunteers with an open offer or a mission in progress (donation MATCHED, PICKUP_PENDING or PICKED_UP, not archived). */
export async function busyVolunteerIds(): Promise<Set<string>> {
  const { data } = await supabase
    .from("missions")
    .select("volunteer_id, donations!inner(status, archived)")
    .in("donations.status", ["MATCHED", "PICKUP_PENDING", "PICKED_UP"])
    .eq("donations.archived", false);
  return new Set((data ?? []).map((r) => r.volunteer_id as string));
}
'@

Write-File 'lib/ai/match.ts' @'
import { supabase } from "@/lib/db/supabase";
import { evaluate, type Candidate, type Donation, type Ngo, type Volunteer } from "./scoring";
import { askCoordinator } from "./coordinator";
import { busyVolunteerIds } from "@/lib/busy";

const MAX_LLM_ATTEMPTS = 2;

export async function findMatch(donationId: string, donorId?: string) {
  const { data: donation } = await supabase.from("donations").select("*").eq("id", donationId).maybeSingle();
  if (!donation) return { error: "Donation not found", httpStatus: 404 as const };
  if (donorId && donation.donor_id !== donorId) return { error: "This is not your donation", httpStatus: 403 as const };
  if (donation.status !== "AVAILABLE")
    return { error: `Donation is ${donation.status}, only AVAILABLE donations can be matched`, httpStatus: 409 as const };

  const [{ data: ngos }, { data: volunteers }] = await Promise.all([
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);

  // Everything the AI will see comes from the database + deterministic code.
  const busy = await busyVolunteerIds();
  const crew = (volunteers ?? []).map((v) => (busy.has(v.id) ? { ...v, available: false, busy: true } : v)) as Volunteer[];
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], crew);

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
  data: Record<string, unknown> = {},
  userId?: string
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
      signed_by_user: userId ?? null,
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
    row = { donation_id: donationId, event_type: eventType, actor_id: actorId, signed_by_user: userId ?? null, payload, status: "PENDING" };
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

Write-File 'app/api/auth/login/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { checkPassword, setSession } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({ email: z.string().trim().toLowerCase().email(), password: z.string().min(1) });

export async function POST(req: Request) {
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Enter your email and password" }, { status: 400 });

  let userId: string | null;
  try {
    userId = await checkPassword(body.data.email, body.data.password);
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : "Sign-in is not configured" }, { status: 500 });
  }
  if (!userId) return NextResponse.json({ error: "Wrong email or password" }, { status: 401 });

  const { data: profile } = await supabase.from("profiles").select("user_id").eq("user_id", userId).maybeSingle();
  if (!profile) return NextResponse.json({ error: "This login is not set up for RescueMesh. Ask the administrator." }, { status: 403 });

  try {
    await setSession(userId);
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : "Could not start the session" }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
'@

Write-File 'app/api/auth/logout/route.ts' @'
import { NextResponse } from "next/server";
import { clearSession } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function POST() {
  await clearSession();
  return NextResponse.json({ ok: true });
}
'@

Write-File 'app/api/auth/signup/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { createLogin, setSession } from "@/lib/auth";
import { insideMap } from "@/lib/actors";
import { ApplicationFields, submitApplication } from "@/lib/requests";

export const dynamic = "force-dynamic";

const Body = z.object({
  ...ApplicationFields,
  email: z.string().trim().toLowerCase().email(),
  password: z.string().min(8).max(72),
});

// New people can only apply to be volunteers. Donors and NGOs are added by the administrator.
export async function POST(req: Request) {
  const parsed = Body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Check the form: name, a valid email, a password of at least 8 characters, and your home position" }, { status: 400 });
  const b = parsed.data;
  if (!insideMap(b.latitude, b.longitude)) return NextResponse.json({ error: "Pick a home position inside the map" }, { status: 400 });

  const { data: taken } = await supabase.from("profiles").select("user_id").eq("email", b.email).maybeSingle();
  if (taken) return NextResponse.json({ error: "An account with this email already exists. Sign in, then apply from your account." }, { status: 409 });

  const login = await createLogin(b.email, b.password, b.name);
  if ("error" in login) return NextResponse.json({ error: login.error }, { status: 400 });

  const r = await submitApplication(login.userId, b);
  if (!r.ok) return NextResponse.json({ error: r.error }, { status: r.status });

  await setSession(login.userId);
  return NextResponse.json({ ok: true }, { status: 201 });
}
'@

Write-File 'app/api/me/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { getAuth } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const auth = await getAuth();
  if (!auth) return NextResponse.json({ error: "Please sign in" }, { status: 401 });

  const ids = auth.memberships.map((m) => m.actor_id).filter((x): x is string => !!x);
  const names = new Map<string, string>();
  if (ids.length) {
    const [{ data: orgs }, { data: vols }] = await Promise.all([
      supabase.from("organizations").select("id, name").in("id", ids),
      supabase.from("volunteers").select("id, name").in("id", ids),
    ]);
    for (const x of [...(orgs ?? []), ...(vols ?? [])]) names.set(x.id as string, x.name as string);
  }
  return NextResponse.json({
    user: { id: auth.userId, name: auth.name, email: auth.email },
    isAdmin: auth.isAdmin,
    memberships: auth.memberships.map((m) => ({
      role: m.role, status: m.status, actorId: m.actor_id, actorName: m.actor_id ? names.get(m.actor_id) ?? m.actor_id : null,
    })),
  });
}
'@

Write-File 'app/api/volunteer-requests/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { insideMap } from "@/lib/actors";
import { ApplicationFields, submitApplication } from "@/lib/requests";

export const dynamic = "force-dynamic";

const Body = z.object(ApplicationFields);

// A signed-in person (donor, NGO...) who also wants to be a volunteer.
export async function POST(req: Request) {
  const g = await authorize();
  if (!g.ok) return g.res;
  const parsed = Body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  if (!insideMap(parsed.data.latitude, parsed.data.longitude)) return NextResponse.json({ error: "Pick a home position inside the map" }, { status: 400 });

  const r = await submitApplication(g.auth.userId, parsed.data);
  if (!r.ok) return NextResponse.json({ error: r.error }, { status: r.status });
  return NextResponse.json({ ok: true }, { status: 201 });
}
'@

Write-File 'app/api/admin/overview/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;

  const [{ data: reqs }, { data: profiles }, { data: ms }, { data: orgs }, { data: vols }] = await Promise.all([
    supabase.from("volunteer_requests").select("*").eq("status", "PENDING").order("created_at", { ascending: true }),
    supabase.from("profiles").select("*").order("created_at", { ascending: true }),
    supabase.from("memberships").select("*"),
    supabase.from("organizations").select("id, name, type, latitude, longitude"),
    supabase.from("volunteers").select("id, name, latitude, longitude, available"),
  ]);
  const email = new Map((profiles ?? []).map((p) => [p.user_id as string, p.email as string]));
  return NextResponse.json({
    requests: (reqs ?? []).map((r) => ({ ...r, email: email.get(r.user_id) ?? "" })),
    accounts: (profiles ?? []).map((p) => ({
      userId: p.user_id, email: p.email, name: p.display_name,
      memberships: (ms ?? []).filter((m) => m.user_id === p.user_id).map((m) => ({ role: m.role, status: m.status, actorId: m.actor_id })),
    })),
    donors: (orgs ?? []).filter((o) => o.type === "DONOR"),
    ngos: (orgs ?? []).filter((o) => o.type === "NGO"),
    volunteers: vols ?? [],
  });
}
'@

Write-File 'app/api/admin/requests/[id]/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";
import { createVolunteerActor } from "@/lib/actors";
import { exclusive } from "@/lib/hedera/onboard";

export const dynamic = "force-dynamic";

const Body = z.object({ decision: z.enum(["approve", "reject"]) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Choose approve or reject" }, { status: 400 });

  return exclusive(async () => {
    const { data: r } = await supabase.from("volunteer_requests").select("*").eq("id", id).maybeSingle();
    if (!r) return NextResponse.json({ error: "Request not found" }, { status: 404 });
    if (r.status !== "PENDING") return NextResponse.json({ error: "This request was already decided" }, { status: 409 });
    const now = new Date().toISOString();

    if (body.data.decision === "reject") {
      await supabase.from("volunteer_requests").update({ status: "REJECTED", decided_at: now }).eq("id", id);
      await supabase.from("memberships").update({ status: "REJECTED" }).eq("user_id", r.user_id).eq("role", "VOLUNTEER");
      return NextResponse.json({ ok: true, decision: "rejected" });
    }

    try {
      // The volunteer, their own Hedera account and their place in the topic's key list are created only now.
      const v = await createVolunteerActor({
        name: r.name, transportType: r.transport_type, capacityKg: Number(r.transport_capacity_kg),
        coldStorage: r.has_cold_storage, latitude: r.latitude, longitude: r.longitude,
      });
      await supabase.from("memberships").update({ status: "ACTIVE", actor_id: v.id }).eq("user_id", r.user_id).eq("role", "VOLUNTEER");
      await supabase.from("volunteer_requests").update({ status: "APPROVED", decided_at: now }).eq("id", id);
      return NextResponse.json({ ok: true, decision: "approved", volunteerId: v.id, hederaAccountId: v.accountId, warning: v.warning });
    } catch (e) {
      return NextResponse.json({ error: e instanceof Error ? e.message : "Could not create the volunteer" }, { status: 502 });
    }
  });
}
'@

Write-File 'app/api/admin/places/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { createPlaceActor, insideMap } from "@/lib/actors";
import { exclusive } from "@/lib/hedera/onboard";

export const dynamic = "force-dynamic";

const Body = z.object({
  kind: z.enum(["DONOR", "NGO"]),
  name: z.string().trim().min(2).max(60),
  latitude: z.number(),
  longitude: z.number(),
  contactName: z.string().trim().max(60).optional(),
  capacityKg: z.number().positive().max(100000).optional(),
  coldStorage: z.boolean().optional(),
  demand: z.enum(["low", "medium", "high"]).optional(),
});

// Donors and NGOs are added by the administrator (people contact the administrator directly, not through the app).
export async function POST(req: Request) {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  const b = body.data;
  if (!insideMap(b.latitude, b.longitude)) return NextResponse.json({ error: "Pick a position inside the map" }, { status: 400 });
  if (b.kind === "NGO" && !b.capacityKg) return NextResponse.json({ error: "An NGO needs a storage capacity" }, { status: 400 });

  return exclusive(async () => {
    try {
      const p = await createPlaceActor(b.kind, b);
      return NextResponse.json({ ok: true, id: p.id, hederaAccountId: p.accountId, warning: p.warning }, { status: 201 });
    } catch (e) {
      return NextResponse.json({ error: e instanceof Error ? e.message : "Could not create the place" }, { status: 502 });
    }
  });
}
'@

Write-File 'app/api/admin/accounts/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { authorize, createLogin } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({
  email: z.string().trim().toLowerCase().email(),
  name: z.string().trim().min(2).max(60).optional(),
  password: z.string().min(8).max(72).optional(),
  role: z.enum(["ADMIN", "DONOR", "NGO", "VOLUNTEER"]),
  actorId: z.string().optional(),
});

// Gives a person a role. If they have no login yet, one is created (name and password needed).
// An existing login can receive more roles: one login can be donor, NGO and volunteer at once.
export async function POST(req: Request) {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  const b = body.data;

  let actorId: string | null = null;
  if (b.role !== "ADMIN") {
    if (!b.actorId) return NextResponse.json({ error: "Choose which place or volunteer this role belongs to" }, { status: 400 });
    const found = b.role === "VOLUNTEER"
      ? (await supabase.from("volunteers").select("id").eq("id", b.actorId).maybeSingle()).data
      : (await supabase.from("organizations").select("id").eq("id", b.actorId).eq("type", b.role).maybeSingle()).data;
    if (!found) return NextResponse.json({ error: "That actor does not exist for this role" }, { status: 400 });
    actorId = b.actorId;
  }

  let { data: profile } = await supabase.from("profiles").select("*").eq("email", b.email).maybeSingle();
  let created = false;
  if (!profile) {
    if (!b.password || !b.name) return NextResponse.json({ error: "This email has no login yet: enter a name and a password (8+ characters)" }, { status: 400 });
    const l = await createLogin(b.email, b.password, b.name);
    if ("error" in l) return NextResponse.json({ error: l.error }, { status: 400 });
    profile = (await supabase.from("profiles").select("*").eq("user_id", l.userId).maybeSingle()).data;
    created = true;
  }
  if (!profile) return NextResponse.json({ error: "Could not load the account" }, { status: 500 });

  const { data: existing } = await supabase.from("memberships").select("*").eq("user_id", profile.user_id).eq("role", b.role).maybeSingle();
  const r = existing
    ? await supabase.from("memberships").update({ actor_id: actorId, status: "ACTIVE" }).eq("id", existing.id)
    : await supabase.from("memberships").insert({ user_id: profile.user_id, role: b.role, actor_id: actorId, status: "ACTIVE" });
  if (r.error) return NextResponse.json({ error: r.error.message }, { status: 500 });
  return NextResponse.json({ ok: true, createdLogin: created, email: profile.email }, { status: 201 });
}
'@

Write-File 'app/api/donations/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { recordEvent } from "@/lib/hedera/events";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

const CreateDonation = z.object({
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
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase
    .from("donations")
    .select("*")
    .eq("archived", false)
    .order("created_at", { ascending: false });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}

export async function POST(req: Request) {
  // Only a donor can create a donation, and always for their own place: the donor comes from the account.
  const g = await authorize("DONOR");
  if (!g.ok) return g.res;
  const parsed = CreateDonation.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });
  }
  const d = parsed.data;

  // The donor must exist and be a DONOR; pickup coordinates come from the database.
  const { data: donor } = await supabase
    .from("organizations")
    .select("id, latitude, longitude")
    .eq("id", g.actorId ?? "")
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
  }, g.auth.userId);

  return NextResponse.json({ donation, hedera }, { status: 201 });
}
'@

Write-File 'app/api/donations/[id]/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Donation + mission + Hedera event references (used by the details and verification pages).
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { id } = await params;
  const { data: donation } = await supabase.from("donations").select("*").eq("id", id).maybeSingle();
  if (!donation) return NextResponse.json({ error: "Donation not found" }, { status: 404 });

  const [{ data: mission }, { data: events }] = await Promise.all([
    supabase.from("missions").select("*").eq("donation_id", id).maybeSingle(),
    supabase.from("hedera_events").select("*").eq("donation_id", id).order("created_at", { ascending: true }),
  ]);
  return NextResponse.json({ donation, mission, events });
}
'@

Write-File 'app/api/donations/[id]/match/route.ts' @'
import { NextResponse } from "next/server";
import { authorize } from "@/lib/auth";
import { findMatch } from "@/lib/ai/match";

export const dynamic = "force-dynamic";

export async function POST(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("DONOR");
  if (!g.ok) return g.res;
  const { id } = await params;
  const { httpStatus, ...body } = await findMatch(id, g.actorId ?? undefined);
  return NextResponse.json(body, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/accept/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { acceptMission } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ ngoId: z.string().min(1), volunteerId: z.string().min(1) });

// The donor accepts the AI match: it becomes an offer to the volunteer.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("DONOR");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await acceptMission(id, body.data.ngoId, body.data.volunteerId, g.actorId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/start/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { startPickup } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({});

// The volunteer accepts the offer and leaves for the donor.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await startPickup(id, g.actorId, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/decline/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { declineOffer } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({});

// The volunteer declines the offer. It goes to the next best volunteer.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await declineOffer(id, g.actorId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/handover/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { donorHandover } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({});

// The donor confirms the handover (signed by the donor's own Hedera account).
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("DONOR");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await donorHandover(id, g.actorId, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/pickup/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { confirmPickup } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ code: z.string().min(1) });

// The volunteer confirms the pickup with the QR code.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmPickup(id, g.actorId, body.data.code, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/dropoff/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { volunteerDropoff } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({});

// The volunteer confirms the drop-off at the NGO.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await volunteerDropoff(id, g.actorId, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/deliver/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { confirmDelivery } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ quantityReceivedKg: z.number().positive(), code: z.string().min(1) });

// The NGO confirms what it received, with the QR code.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("NGO");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmDelivery(id, g.actorId, body.data.quantityReceivedKg, body.data.code, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/ngos/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase
    .from("organizations")
    .select("*")
    .eq("type", "NGO");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
'@

Write-File 'app/api/donors/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase.from("organizations").select("*").eq("type", "DONOR").order("id");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
'@

Write-File 'app/api/missions/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
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

Write-File 'app/api/reputation/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

type Row = { donation_id: string; ngo_id: string; volunteer_id: string; received_kg: number | null; donations: { donor_id: string; quantity_kg: number } };
type Rep = { id: string; name: string; count: number; kg: number };

// Reputation is computed only from deliveries whose DELIVERY_CONFIRMED event is CONFIRMED on Hedera.
// Archived (reset) donations still count: the ledger history does not disappear.
export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data: ev } = await supabase
    .from("hedera_events")
    .select("donation_id")
    .eq("event_type", "DELIVERY_CONFIRMED")
    .eq("status", "CONFIRMED");
  const ids = (ev ?? []).map((e) => e.donation_id);

  const empty = { donors: [], ngos: [], volunteers: [] };
  if (ids.length === 0) return NextResponse.json(empty);

  const [{ data: rows }, { data: orgs }, { data: vols }] = await Promise.all([
    supabase.from("missions").select("donation_id, ngo_id, volunteer_id, received_kg, donations!inner(donor_id, quantity_kg)").in("donation_id", ids).eq("status", "COMPLETED"),
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
      if (withKg) cur.kg += Number(r.received_kg ?? r.donations.quantity_kg);
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

Write-File 'app/api/hedera/retry/route.ts' @'
import { NextResponse } from "next/server";
import { countPending, retryPending } from "@/lib/hedera/events";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  return NextResponse.json({ pending: await countPending() });
}

export async function POST() {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  return NextResponse.json(await retryPending());
}
'@

Write-File 'app/api/demo/reset/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Demo reset = archive. Rows stay in the database (so old /verify links keep working and IDs never repeat),
// they just disappear from the dashboard. HCS messages can never be deleted, and we don't pretend they can.
export async function POST() {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const { data, error } = await supabase
    .from("donations")
    .update({ archived: true })
    .eq("archived", false)
    .select("id");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ archived: data?.length ?? 0 });
}
'@

Write-File 'app/api/volunteers/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Volunteers are no longer created here: people apply (see /join) and an administrator approves them.
export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase.from("volunteers").select("*");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
'@

Write-File 'app/api/volunteers/[id]/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { busyVolunteerIds } from "@/lib/busy";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({ available: z.boolean() });

// On duty / off duty. Off-duty volunteers are not matched. Nobody can go off duty in the middle of a mission.
export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok) return g.res;
  const { id } = await params;
  if (g.actorId !== id) return NextResponse.json({ error: "You can only change your own duty status" }, { status: 403 });
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
type Mission = { id: string; donation_id: string; ngo_id: string; volunteer_id: string; status: string; received_kg: number | null; offer_number?: number; estimated_delivery_minutes?: number | null; events?: string[] };
type Named = { id: string; name: string; latitude: number; longitude: number; available?: boolean };
type Me = {
  user: { id: string; name: string; email: string };
  isAdmin: boolean;
  memberships: { role: string; status: string; actorId: string | null; actorName: string | null }[];
};
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
  if (res.status === 401 && typeof window !== "undefined") {
    window.location.assign("/login");
    throw new Error("Please sign in");
  }
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
  return <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${tone}`}>{status === "MATCHED" ? "Offered" : human(status)}</span>;
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
  const [me, setMe] = useState<Me | null>(null);
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

  // Who is signed in on this screen (the server decides, from the session cookie).
  useEffect(() => { api("/api/me").then(setMe).catch(() => {}); }, []);

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
  // Roles come from the account. One login can be donor, NGO and volunteer at once.
  const held = (r: string) => me?.memberships.find((m) => m.role === r && m.status === "ACTIVE");
  const donorId = held("DONOR")?.actorId ?? "";
  const volId = held("VOLUNTEER")?.actorId ?? "";
  const ngoId = held("NGO")?.actorId ?? "";
  const volPending = me?.memberships.find((m) => m.role === "VOLUNTEER" && m.status === "PENDING");
  const volRejected = me?.memberships.find((m) => m.role === "VOLUNTEER" && m.status === "REJECTED");
  const volMissing = !!me && !held("VOLUNTEER") && !volPending;
  async function signOut() {
    await fetch("/api/auth/logout", { method: "POST" });
    window.location.assign("/login");
  }
  // Clicking your own place on the map selects it. Other donors are not yours to act for.
  function selectDonor(id: string) {
    if (id !== donorId) return;
    setRole("Donor"); setSelectedId(null); setMatch(null);
  }
  useEffect(() => {
    const preset = DONOR_PRESETS[donorId];
    if (preset) setForm((f) => ({ ...f, ...preset }));
  }, [donorId]);

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
      stage: ((ms(current) === "OFFERED" || ms(current) === "PICKUP_PENDING") ? "assigned" : ms(current) === "EN_ROUTE" ? "donor" : ms(current) === "PICKED_UP" ? "ngo" : "back") as MapRoute["stage"],
      highlight: current.donation_id === selected?.id,
    }];
  });
  const selRec = selected?.status === "AVAILABLE" ? match?.recommendation : undefined;
  const preview: MapPreview | null = selected && selRec
    ? { volunteerId: selRec.volunteerId, donorId: selected.donor_id, ngoId: selRec.ngoId } : null;

  // Donor side of the pickup handoff: the volunteer is on the way and the donor has not signed yet.
  const handovers = missions.filter((m) => ms(m) === "EN_ROUTE" && !(m.events ?? []).includes("DONOR_HANDOVER_CONFIRMED")
    && donations.find((d) => d.id === m.donation_id)?.donor_id === donorId);
  // Offers sent for this donor's donations that no volunteer has accepted yet.
  const offers = missions.filter((m) => ms(m) === "OFFERED" && donations.find((d) => d.id === m.donation_id)?.donor_id === donorId);
  // Each screen only shows the missions of the account that is signed in.
  const myVolMissions = missions.filter((m) => m.volunteer_id === volId && ["OFFERED", "PICKUP_PENDING", "EN_ROUTE", "PICKED_UP"].includes(ms(m)));
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

  if (!mounted || !me) return <main className="min-h-screen bg-[#0D0C16]" />; // render the UI only in the browser: extensions inject attributes into server HTML

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
  const availableRoles = ROLES.filter((r) =>
    (r.role === "Donor" && donorId) || (r.role === "Volunteer" && (volId || volPending || volRejected)) || (r.role === "NGO" && ngoId));
  const TABS: ["timeline" | "donations" | "record", string][] = [["timeline", "Signed steps"], ["donations", "Donations"], ["record", "Track record"]];

  return (
    <main className="min-h-screen bg-[#0D0C16] text-[#ECEAF8]">
      <div className="grid lg:grid-cols-[88px_minmax(0,1fr)_410px] lg:grid-rows-[auto_1fr] lg:[grid-template-areas:'rail_top_panel'_'rail_dock_panel']">

        {/* ---------------------------------------------- rail: who is this screen */}
        <nav aria-label="Choose a role" className="flex items-center gap-3 border-b border-[#ECEAF8]/10 bg-[#0A0910] px-4 py-3 lg:sticky lg:top-0 lg:h-screen lg:flex-col lg:justify-start lg:gap-3 lg:border-b-0 lg:border-r lg:px-2 lg:py-6 lg:[grid-area:rail]">
          <Logo size={40} className="shrink-0 lg:mb-5" />
          <div role="group" aria-label="Role" className="flex gap-2 lg:flex-col">
            {availableRoles.map((r) => (
              <button key={r.role} aria-pressed={role === r.role} onClick={() => setRole(r.role)}
                className={`flex w-[66px] flex-col items-center gap-1 rounded-xl px-1 py-2.5 text-[11px] font-medium transition focus-visible:outline-2 focus-visible:outline-[#C9BEFF] ${role === r.role ? "bg-[#8B7CF6] text-[#0D0C16]" : "text-[#ECEAF8]/65 hover:bg-[#ECEAF8]/10"}`}>
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d={r.icon} /></svg>
                {r.label}
              </button>
            ))}
          </div>
          {me.isAdmin && (
            <Link href="/admin" className="flex w-[66px] flex-col items-center gap-1 rounded-xl px-1 py-2.5 text-[11px] font-medium text-[#ECEAF8]/65 transition hover:bg-[#ECEAF8]/10 focus-visible:outline-2 focus-visible:outline-[#C9BEFF]">
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M12 3l8 3v6c0 4.5-3.2 7.8-8 9-4.8-1.2-8-4.5-8-9V6z" /><path d="M9 12l2 2 4-4" /></svg>
              Admin
            </Link>
          )}
          <div className="ml-auto flex items-center gap-3 lg:ml-0 lg:mt-auto lg:flex-col">
            <p className="flex items-center gap-1.5 text-[11px] text-[#ECEAF8]/55 lg:flex-col">
              <span aria-hidden className="h-2 w-2 rounded-full bg-[#34D3A0] motion-safe:animate-pulse" />
              Live
            </p>
            <button onClick={signOut} title="Sign out" className="flex flex-col items-center gap-1 rounded-xl px-2 py-2 text-[11px] text-[#ECEAF8]/65 transition hover:bg-[#ECEAF8]/10 focus-visible:outline-2 focus-visible:outline-[#C9BEFF]">
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#8B7CF6]/25 text-sm font-semibold text-[#D2C9FF]">{me.user.name.slice(0, 1).toUpperCase()}</span>
              Sign out
            </button>
          </div>
        </nav>

        {/* ---------------------------------------------- top: title, impact, map */}
        <div className="px-5 pt-6 lg:px-8 lg:[grid-area:top]">
          <header>
            <h1 className="font-[family-name:var(--font-heading)] text-2xl font-semibold tracking-tight">RescueMesh</h1>
            <p className="text-sm text-[#ECEAF8]/60">Rescue the surplus. Prove the rescue.</p>
            <p className="mt-1 text-xs text-[#ECEAF8]/45">
              Signed in as {me.user.name}
              {volMissing && <> . <Link href="/join" className="text-[#C9BEFF] underline underline-offset-2">Become a volunteer</Link></>}
            </p>
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
            <CityMap donors={donors} ngos={ngos} volunteers={vols} selectedDonorId={donorId} routes={volRoutes} preview={preview} onSelectDonor={selectDonor} />
          </div>
        </div>

        {/* ---------------------------------------------- panel: what this person can do */}
        <aside className="border-t border-[#ECEAF8]/10 bg-[#11101C] px-5 py-6 lg:sticky lg:top-0 lg:h-screen lg:overflow-y-auto lg:border-l lg:border-t-0 lg:[grid-area:panel]">
          {availableRoles.length === 0 ? (
            <section aria-label="Account">
              <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">{me.isAdmin ? "Administrator" : "Welcome"}</h2>
              <p className="mt-3 text-sm text-[#ECEAF8]/70">
                {me.isAdmin
                  ? "You see everything on the map and in the lists. Add places, approve volunteers and give roles in the admin console."
                  : "Your account has no role yet. Donors and NGOs are added by the administrator. You can apply to become a volunteer."}
              </p>
              {me.isAdmin && <Link href="/admin" className={`${btn} mt-4 inline-block`}>Open the admin console</Link>}
              {volMissing && <Link href="/join" className={`${btn} mt-4 inline-block`}>Apply as a volunteer</Link>}
            </section>
          ) : (
          <>
          <section aria-label={`${role} actions`}>
            {role === "Donor" && (
              <>
                <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Report surplus food</h2>
                <p className="mb-4 text-sm text-[#ECEAF8]/65">Donating as <strong className="text-[#ECEAF8]">{donorName(donorId)}</strong></p>
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
                            return `Offer sent to ${rec.volunteerName}. They can accept or decline. Nothing is signed on Hedera until a volunteer accepts.`;
                          })}>
                            {busy === "accept" ? "Sending\u2026" : "Send offer"}
                          </button>
                          <button className={btnGhost} disabled={busy !== null} onClick={() => setMatch(null)}>Discard</button>
                        </div>
                      </div>
                    )}
                  </div>
                )}

                {offers.length > 0 && (
                  <div className="mt-8 border-t border-[#ECEAF8]/15 pt-6">
                    <h2 className="font-[family-name:var(--font-heading)] text-xl font-semibold">Waiting for a volunteer</h2>
                    {offers.map((m) => (
                      <p key={m.id} className="mt-3 text-sm text-[#ECEAF8]/75">
                        <span className="font-medium text-[#ECEAF8]">{m.donation_id}</span>: offered to {nameOf(vols, m.volunteer_id)}
                        {(m.offer_number ?? 1) > 1 ? ` (offer ${m.offer_number}, earlier volunteers declined)` : ""}. They can accept or decline.
                      </p>
                    ))}
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
                {volPending && !volId && (
                  <p className="mt-4 rounded-xl border border-[#FBBF24]/40 bg-[#FBBF24]/10 p-4 text-sm">
                    Your volunteer application is waiting for approval by an administrator. Your missions will appear here once it is approved.
                  </p>
                )}
                {volRejected && !volId && (
                  <p className="mt-4 rounded-xl border border-[#FB7185]/40 bg-[#FB7185]/10 p-4 text-sm">
                    Your volunteer application was not accepted. You can <Link href="/join" className="text-[#C9BEFF] underline underline-offset-2">apply again</Link>.
                  </p>
                )}
                {volId && meVol && (
                  <div className="mt-3 flex flex-wrap items-center gap-3 text-sm">
                    <span>{meVol.name}: {meVol.available === false ? "off duty" : "on duty"}</span>
                    <button className={btnGhost} disabled={busy !== null} onClick={() => run("duty", async () => {
                      await api(`/api/volunteers/${meVol.id}`, "PATCH", { available: meVol.available === false });
                      return meVol.available === false ? `${meVol.name} is on duty again.` : `${meVol.name} is off duty and will not be offered missions.`;
                    })}>
                      {meVol.available === false ? "Go on duty" : "Go off duty"}
                    </button>
                  </div>
                )}
                {volId && myVolMissions.length === 0 && (
                  <p className="mt-3 text-sm text-[#ECEAF8]/65">No missions for you right now. Offers from donors appear here.</p>
                )}
                {myVolMissions.map((m) => {
                  const d = donationOf(m.donation_id);
                  const st = ms(m) === "PICKUP_PENDING" ? "OFFERED" : ms(m);
                  const ev = m.events ?? [];
                  const me2 = nameOf(vols, m.volunteer_id);
                  const dn = d ? donorName(d.donor_id) : "the donor";
                  return (
                    <div key={m.id} className="mt-4 border-l-4 border-[#FBBF24] pl-4">
                      <p className="font-[family-name:var(--font-heading)] text-lg font-semibold">{st === "OFFERED" ? "New offer" : "Mission"} {m.donation_id}</p>
                      <p className="text-sm text-[#ECEAF8]/70">
                        {dn}: {d?.quantity_kg} kg of {d?.food_type.toLowerCase()}, to {nameOf(ngos, m.ngo_id)}.{" "}
                        {st === "OFFERED" ? `About ${m.estimated_delivery_minutes ?? "?"} min door to door.` : st === "EN_ROUTE" ? "On the way to the donor." : `On the way to ${nameOf(ngos, m.ngo_id)}.`}
                      </p>

                      {st === "OFFERED" && (
                        <div className="mt-3 flex flex-wrap gap-3">
                          <button className={btn} disabled={busy !== null} onClick={() => run(`start-${m.id}`, async () => {
                            await api(`/api/donations/${m.donation_id}/start`, "POST", {});
                            setSelectedId(m.donation_id);
                            return `You accepted the mission. Signed on Hedera by your own account. You are on the way to ${dn}.`;
                          })}>
                            {busy === `start-${m.id}` ? "Signing on Hedera\u2026" : "Accept and start"}
                          </button>
                          <button className={btnGhost} disabled={busy !== null} onClick={() => run(`decline-${m.id}`, async () => {
                            const r = await api(`/api/donations/${m.donation_id}/decline`, "POST", {});
                            return r.reoffered
                              ? `Offer declined. It was passed to ${r.offeredTo}.`
                              : "Offer declined. No other volunteer fits this NGO, so the donor will be asked to match again.";
                          })}>
                            {busy === `decline-${m.id}` ? "Declining\u2026" : "Decline"}
                          </button>
                        </div>
                      )}

                      {st === "EN_ROUTE" && (ev.includes("PICKUP_CONFIRMED") ? (
                        <p className="mt-3 text-sm">You confirmed the pickup. Waiting for {dn} to confirm the handover.</p>
                      ) : (
                        <>
                          <CodeStep value={codes["p-" + m.id] ?? ""} onChange={(v) => setCodes({ ...codes, ["p-" + m.id]: v })} />
                          <button className={`${btn} mt-3`} disabled={busy !== null || !(codes["p-" + m.id] ?? "").trim()} onClick={() => run(`pickup-${m.id}`, async () => {
                            const r = await api(`/api/donations/${m.donation_id}/pickup`, "POST", { code: codes["p-" + m.id] });
                            setSelectedId(m.donation_id);
                            return r.pickupComplete
                              ? `Pickup complete. Donor and volunteer both signed on Hedera. ${hederaText(r.hedera)}`
                              : `Pickup confirmed and signed by ${me2}. Waiting for ${dn} to confirm the handover.`;
                          })}>
                            {busy === `pickup-${m.id}` ? "Signing on Hedera\u2026" : "Confirm pickup"}
                          </button>
                        </>
                      ))}

                      {st === "PICKED_UP" && (ev.includes("DROPOFF_CONFIRMED") ? (
                        <p className="mt-3 text-sm">You confirmed the drop-off. Waiting for {nameOf(ngos, m.ngo_id)} to confirm the delivery.</p>
                      ) : (
                        <button className={`${btn} mt-3`} disabled={busy !== null} onClick={() => run(`dropoff-${m.id}`, async () => {
                          const r = await api(`/api/donations/${m.donation_id}/dropoff`, "POST", {});
                          setSelectedId(m.donation_id);
                          return r.deliveryComplete
                            ? `Delivery complete. Volunteer and NGO both signed on Hedera. ${hederaText(r.hedera)}`
                            : `Drop-off confirmed and signed by ${me2}. Waiting for ${nameOf(ngos, m.ngo_id)} to confirm the delivery.`;
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
          </>
          )}
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

Write-File 'app/login/page.tsx' @'
"use client";

import Link from "next/link";
import { useState } from "react";
import Logo from "../components/Logo";
import { btn, card, heading, input } from "../components/ui";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const res = await fetch("/api/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : "Sign-in failed");
      window.location.assign("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-in failed");
      setBusy(false);
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-[#0D0C16] px-5 py-10 text-[#ECEAF8]">
      <div className="w-full max-w-sm">
        <div className="flex items-center gap-3">
          <Logo size={46} />
          <div>
            <h1 className={`${heading} text-2xl font-semibold tracking-tight`}>RescueMesh</h1>
            <p className="text-sm text-[#ECEAF8]/60">Rescue the surplus. Prove the rescue.</p>
          </div>
        </div>

        <form onSubmit={submit} className={`${card} mt-8 space-y-4`}>
          <h2 className={`${heading} text-xl font-semibold`}>Sign in</h2>
          <label className="block text-sm">Email
            <input className={`${input} mt-1`} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label className="block text-sm">Password
            <input className={`${input} mt-1`} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
          </label>
          {error && <p role="alert" className="rounded-lg border border-[#FB7185]/50 bg-[#FB7185]/10 px-3 py-2 text-sm">{error}</p>}
          <button className={`${btn} w-full`} disabled={busy}>{busy ? "Signing in\u2026" : "Sign in"}</button>
        </form>

        <p className="mt-5 text-sm text-[#ECEAF8]/65">
          Want to help as a volunteer? <Link href="/join" className="text-[#C9BEFF] underline underline-offset-2">Apply here</Link>.
          Donors and NGOs are added by the administrator: please contact them directly.
        </p>
      </div>
    </main>
  );
}
'@

Write-File 'app/join/page.tsx' @'
"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import CityMap from "../components/CityMap";
import Logo from "../components/Logo";
import { btn, card, heading, input } from "../components/ui";

const VEHICLE_CAPACITY: Record<string, number> = { Bike: 10, Scooter: 20, Car: 60, Van: 150 };

export default function JoinPage() {
  const [signedIn, setSignedIn] = useState<{ name: string } | null>(null);
  const [checked, setChecked] = useState(false);
  const [f, setF] = useState({ name: "", email: "", password: "", vehicle: "Car", capacityKg: "60", cold: false });
  const [home, setHome] = useState<{ lat: number; lng: number } | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch("/api/me")
      .then((r) => (r.ok ? r.json() : null))
      .then((me) => { if (me) { setSignedIn({ name: me.user.name }); setF((x) => ({ ...x, name: me.user.name })); } })
      .finally(() => setChecked(true));
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!home) { setError("Click the map to set your home position"); return; }
    setBusy(true);
    setError("");
    try {
      const payload = { name: f.name.trim(), transportType: f.vehicle, capacityKg: Number(f.capacityKg), coldStorage: f.cold, latitude: home.lat, longitude: home.lng };
      const res = await fetch(signedIn ? "/api/volunteer-requests" : "/api/auth/signup", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(signedIn ? payload : { ...payload, email: f.email, password: f.password }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(typeof data.error === "string" ? data.error : "Could not send your application");
      window.location.assign("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send your application");
      setBusy(false);
    }
  }

  return (
    <main className="min-h-screen bg-[#0D0C16] px-5 py-8 text-[#ECEAF8]">
      <div className="mx-auto max-w-5xl">
        <Link href={signedIn ? "/" : "/login"} className="inline-flex items-center gap-2.5 text-sm text-[#C9BEFF] underline underline-offset-2">
          <Logo size={30} />{signedIn ? "Back to the dashboard" : "Back to sign in"}
        </Link>
        <h1 className={`${heading} mt-5 text-3xl font-semibold tracking-tight`}>Become a volunteer</h1>
        <p className="mt-1 max-w-xl text-sm text-[#ECEAF8]/65">
          Tell us about your vehicle and where you start from. An administrator reviews every application. You can sign in right away, and your missions appear once you are approved.
        </p>

        <div className="mt-8 grid gap-8 lg:grid-cols-[22rem_minmax(0,1fr)]">
          <form onSubmit={submit} className={`${card} space-y-4`}>
            <label className="block text-sm">Name
              <input className={`${input} mt-1`} required minLength={2} maxLength={40} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
            </label>
            {checked && !signedIn && (
              <>
                <label className="block text-sm">Email
                  <input className={`${input} mt-1`} type="email" autoComplete="username" required value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
                </label>
                <label className="block text-sm">Password (8 characters or more)
                  <input className={`${input} mt-1`} type="password" autoComplete="new-password" required minLength={8} value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
                </label>
              </>
            )}
            {signedIn && <p className="text-sm text-[#ECEAF8]/65">You are signed in as {signedIn.name}. This adds the volunteer role to your account.</p>}
            <div className="grid grid-cols-2 gap-3">
              <label className="block text-sm">Vehicle
                <select className={`${input} mt-1`} value={f.vehicle} onChange={(e) => setF({ ...f, vehicle: e.target.value, capacityKg: String(VEHICLE_CAPACITY[e.target.value] ?? f.capacityKg) })}>
                  {Object.keys(VEHICLE_CAPACITY).map((v) => <option key={v} value={v}>{v}</option>)}
                </select>
              </label>
              <label className="block text-sm">Capacity (kg)
                <input className={`${input} mt-1`} type="number" min={1} max={1000} required value={f.capacityKg} onChange={(e) => setF({ ...f, capacityKg: e.target.value })} />
              </label>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={f.cold} onChange={(e) => setF({ ...f, cold: e.target.checked })} />
              Refrigerated transport
            </label>
            <p className="text-sm">{home ? `Home position set (${home.lat.toFixed(4)}, ${home.lng.toFixed(4)}).` : "Click the map to set your home position."}</p>
            {error && <p role="alert" className="rounded-lg border border-[#FB7185]/50 bg-[#FB7185]/10 px-3 py-2 text-sm">{error}</p>}
            <button className={`${btn} w-full`} disabled={busy}>{busy ? "Sending\u2026" : "Send my application"}</button>
          </form>

          <div className="overflow-hidden rounded-2xl border border-[#ECEAF8]/10 bg-[#1D1B42]">
            <CityMap donors={[]} ngos={[]} volunteers={[]} selectedDonorId="" routes={[]} preview={null} onSelectDonor={() => {}}
              pick={{ active: true, point: home, onPick: (lat, lng) => setHome({ lat, lng }) }} />
          </div>
        </div>
      </div>
    </main>
  );
}
'@

Write-File 'app/admin/page.tsx' @'
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
'@

Write-File 'app/components/ui.ts' @'
// Shared class names for the sign-in, join and admin pages (same look as the dashboard).
export const btn =
  "rounded-lg bg-[#8B7CF6] px-4 py-2 text-sm font-semibold text-[#0D0C16] transition hover:bg-[#A89BFF] disabled:opacity-50 disabled:hover:bg-[#8B7CF6] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#C9BEFF]";
export const btnGhost =
  "rounded-lg border border-[#C9BEFF]/40 px-4 py-2 text-sm font-medium text-[#C9BEFF] transition hover:bg-[#8B7CF6]/10 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#C9BEFF]";
export const input =
  "w-full rounded-lg border border-[#ECEAF8]/20 bg-[#1B1A33] px-3 py-2 text-sm text-[#ECEAF8] placeholder:text-[#ECEAF8]/40 focus-visible:outline-2 focus-visible:outline-[#C9BEFF]";
export const card = "rounded-2xl border border-[#ECEAF8]/10 bg-[#16152A]/80 p-6";
export const heading = "font-[family-name:var(--font-heading)]";
'@

Write-File 'scripts/create-admin.mjs' @'
// Creates the first administrator (or adds the admin role to an existing login).
// Run:  node --env-file=.env.local scripts/create-admin.mjs you@example.com "a-strong-password" "Your Name"
import { createClient } from "@supabase/supabase-js";

const [email, password, ...nameParts] = process.argv.slice(2);
if (!email || !password) {
  console.error('Usage: node --env-file=.env.local scripts/create-admin.mjs <email> <password> ["Full name"]');
  process.exit(1);
}
const name = nameParts.join(" ") || "Administrator";
const mail = email.trim().toLowerCase();
const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });

let userId;
const created = await db.auth.admin.createUser({ email: mail, password, email_confirm: true, user_metadata: { name } });
if (created.error) {
  const { data: p } = await db.from("profiles").select("user_id").eq("email", mail).maybeSingle();
  if (!p) throw new Error(created.error.message + "  (did you run supabase/phase14.sql? If this email exists in Supabase Auth, delete it there or use another email)");
  userId = p.user_id;
  console.log("This login already exists: adding the admin role to it.");
} else {
  userId = created.data.user.id;
  const { error } = await db.from("profiles").insert({ user_id: userId, email: mail, display_name: name });
  if (error) throw new Error(error.message + "  (did you run supabase/phase14.sql?)");
}
const { error } = await db.from("memberships").upsert({ user_id: userId, role: "ADMIN", actor_id: null, status: "ACTIVE" }, { onConflict: "user_id,role" });
if (error) throw new Error(error.message);
console.log(`Administrator ready: ${mail}`);
process.exit(0);
'@

Write-File 'scripts/seed-demo-accounts.mjs' @'
// Creates one login for every existing donor, NGO and volunteer, so you can demo on several screens.
// Run:  node --env-file=.env.local scripts/seed-demo-accounts.mjs "a-shared-demo-password"
// Emails look like  carrefour-market@rescuemesh.app, hope-kitchen@rescuemesh.app, ahmed@rescuemesh.app (no email is ever sent).
import { createClient } from "@supabase/supabase-js";

const password = process.argv[2];
if (!password || password.length < 8) {
  console.error('Usage: node --env-file=.env.local scripts/seed-demo-accounts.mjs "<password, 8+ characters>"');
  process.exit(1);
}
const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
const slug = (s) => s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

const [{ data: orgs, error: e1 }, { data: vols, error: e2 }] = await Promise.all([
  db.from("organizations").select("id, name, type"),
  db.from("volunteers").select("id, name"),
]);
if (e1 || e2) throw new Error((e1 || e2).message);

const actors = [...orgs.map((o) => ({ role: o.type, id: o.id, name: o.name })), ...vols.map((v) => ({ role: "VOLUNTEER", id: v.id, name: v.name }))];
console.log("role       actor              email");
for (const a of actors) {
  const email = `${slug(a.name)}@rescuemesh.app`;
  let { data: p } = await db.from("profiles").select("user_id").eq("email", email).maybeSingle();
  if (!p) {
    const c = await db.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { name: a.name } });
    if (c.error) { console.log(`skip ${a.id}: ${c.error.message}`); continue; }
    const { error } = await db.from("profiles").insert({ user_id: c.data.user.id, email, display_name: a.name });
    if (error) throw new Error(error.message + "  (did you run supabase/phase14.sql?)");
    p = { user_id: c.data.user.id };
  } else {
    const { error } = await db.auth.admin.updateUserById(p.user_id, { password });
    if (error) throw new Error(`Could not update ${email}: ${error.message}`);
  }
  const { error } = await db.from("memberships").upsert({ user_id: p.user_id, role: a.role, actor_id: a.id, status: "ACTIVE" }, { onConflict: "user_id,role" });
  if (error) throw new Error(error.message);
  console.log(`${a.role.padEnd(10)} ${a.name.padEnd(18)} ${email}`);
}
console.log("\nAll demo logins share the password you gave. Create the administrator with scripts/create-admin.mjs.");
process.exit(0);
'@

Write-File 'DEMO_SCRIPT.md' @'
# RescueMesh: demo script (about 6 minutes, three screens)

## Before you go on stage (5 minutes)
1. Start Ollama and warm the model: `ollama run llama3.2:3b "hi"` (type /bye afterwards).
2. Create a fresh topic so HashScan only shows this demo: `node --env-file=.env.local scripts/create-topic.mjs`, paste the ID into `HEDERA_TOPIC_ID`, restart `npm run dev`. Do not rehearse on this topic.
3. Sign in as the administrator on the laptop, open **Admin console, Maintenance, Archive demo data**. Then go back to the dashboard.
4. Open the three screens and sign in on each:
   - Laptop: a **donor**, for example `urbain-food@rescuemesh.app`.
   - Phone or tab 2: a **volunteer**, for example `ahmed@rescuemesh.app`.
   - Phone or tab 3: an **NGO**, for example `hope-kitchen@rescuemesh.app`.
   (All demo logins share the password you gave to `seed-demo-accounts.mjs`. Use separate browser profiles if you use tabs, because the session cookie is per browser.)
5. Open HashScan on the topic in another window.

## The story
| Time | Screen | Do | Say |
|---|---|---|---|
| 0:00 | Laptop | Show the dashboard and the map | "Surplus food is not the problem. Coordinating it before it expires, and proving it happened, is." |
| 0:30 | Donor | Create donation | "The donor declares a surplus. It is signed by the donor's own Hedera account." |
| 1:00 | Donor | Find rescue match, then Send offer | "The backend removes everyone who cannot do the job. The AI only chooses among safe options. The match is an offer: nothing is on the ledger yet." |
| 1:40 | Volunteer | The offer appears. Show **Decline** (optional, see below), then **Accept and start** | "A real person decides. When they accept, the coordinator and the volunteer sign." |
| 2:10 | Volunteer | Enter the QR code, Confirm pickup | "A handoff needs two signatures. The volunteer has signed, the donor has not." |
| 2:30 | Donor | Confirm handover | "Now both sides signed. Only then does the food count as picked up." |
| 2:50 | Volunteer | Hand over to the NGO | "Second handoff, same rule." |
| 3:10 | NGO | Enter the code and the quantity, Confirm delivery | "The NGO confirms what it actually received." |
| 3:40 | Laptop | Impact receipt, Verify on Hedera | "Now you do not have to trust our database." |
| 4:15 | Verify page + HashScan | Show 7 verified rows and the different signer accounts | "Each step is signed by its own account. Only registered accounts can write to this topic. AI decides who should act, Hedera proves what actually happened." |

## Show the decline (optional, 30 seconds)
At the offer step, press **Decline** on Ahmed's screen. The donor screen says the offer moved to the next volunteer, whose screen now shows the offer. "If someone declines, the next best volunteer is offered the mission. If nobody fits, the donor can match again."

## Show the administrator (optional, 45 seconds)
Sign in as the administrator. Show **Volunteer applications**: approve one (a new Hedera account is created). Show **Add a donor or an NGO** (click the map) and **Accounts and roles**: one login can hold several roles.

## If something breaks
- **AI slow or Ollama down**: the match still appears and says "Deterministic fallback used". Say it out loud, it proves the backend is the authority.
- **Hedera slow or down**: the app shows "Pending verification" and the administrator can press **Retry pending Hedera events**.
- **Total failure**: open the HashScan tab and your screenshots of the previous run.
- **Clean slate**: Admin console, Maintenance, Archive demo data.

## What to point at
- The map: volunteers drive to the donor, then the NGO, then home. Several missions can run at once.
- The QR label: the receiver (volunteer, NGO) must enter or scan it. A wrong code is refused.
- The track record: built only from deliveries confirmed on Hedera. It survives an archive.
- Tamper test (optional): change one character of `payload_hash` in Supabase and reload the Verify page. That row turns red.
'@

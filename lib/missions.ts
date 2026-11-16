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
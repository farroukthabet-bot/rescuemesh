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
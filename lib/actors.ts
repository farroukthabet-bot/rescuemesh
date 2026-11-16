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
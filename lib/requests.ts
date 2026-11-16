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
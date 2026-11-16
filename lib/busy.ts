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
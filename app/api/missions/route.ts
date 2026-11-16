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
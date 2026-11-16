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
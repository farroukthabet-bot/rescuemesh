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
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
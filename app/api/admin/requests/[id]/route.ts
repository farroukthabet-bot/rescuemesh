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
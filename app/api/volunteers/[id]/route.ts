import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { busyVolunteerIds } from "@/lib/busy";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({ available: z.boolean() });

// On duty / off duty. Off-duty volunteers are not matched. Nobody can go off duty in the middle of a mission.
export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("VOLUNTEER");
  if (!g.ok) return g.res;
  const { id } = await params;
  if (g.actorId !== id) return NextResponse.json({ error: "You can only change your own duty status" }, { status: 403 });
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });

  if (!body.data.available && (await busyVolunteerIds()).has(id))
    return NextResponse.json({ error: "Finish the current mission before going off duty" }, { status: 409 });

  const { data, error } = await supabase.from("volunteers").update({ available: body.data.available }).eq("id", id).select().maybeSingle();
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  if (!data) return NextResponse.json({ error: "Volunteer not found" }, { status: 404 });
  return NextResponse.json(data);
}
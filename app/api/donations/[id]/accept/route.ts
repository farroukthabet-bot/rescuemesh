import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { acceptMission } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ ngoId: z.string().min(1), volunteerId: z.string().min(1) });

// The donor accepts the AI match: it becomes an offer to the volunteer.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("DONOR");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await acceptMission(id, body.data.ngoId, body.data.volunteerId, g.actorId);
  return NextResponse.json(res, { status: httpStatus });
}
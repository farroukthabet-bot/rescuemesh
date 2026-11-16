import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { confirmDelivery } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ quantityReceivedKg: z.number().positive(), code: z.string().min(1) });

// The NGO confirms what it received, with the QR code.
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("NGO");
  if (!g.ok || !g.actorId) return g.ok ? NextResponse.json({ error: "Your account is not linked to a place yet" }, { status: 403 }) : g.res;
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => ({})));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmDelivery(id, g.actorId, body.data.quantityReceivedKg, body.data.code, g.auth.userId);
  return NextResponse.json(res, { status: httpStatus });
}
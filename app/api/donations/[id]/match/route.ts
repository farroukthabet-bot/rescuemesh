import { NextResponse } from "next/server";
import { authorize } from "@/lib/auth";
import { findMatch } from "@/lib/ai/match";

export const dynamic = "force-dynamic";

export async function POST(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const g = await authorize("DONOR");
  if (!g.ok) return g.res;
  const { id } = await params;
  const { httpStatus, ...body } = await findMatch(id, g.actorId ?? undefined);
  return NextResponse.json(body, { status: httpStatus });
}
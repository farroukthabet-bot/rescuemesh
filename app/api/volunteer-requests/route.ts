import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { insideMap } from "@/lib/actors";
import { ApplicationFields, submitApplication } from "@/lib/requests";

export const dynamic = "force-dynamic";

const Body = z.object(ApplicationFields);

// A signed-in person (donor, NGO...) who also wants to be a volunteer.
export async function POST(req: Request) {
  const g = await authorize();
  if (!g.ok) return g.res;
  const parsed = Body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  if (!insideMap(parsed.data.latitude, parsed.data.longitude)) return NextResponse.json({ error: "Pick a home position inside the map" }, { status: 400 });

  const r = await submitApplication(g.auth.userId, parsed.data);
  if (!r.ok) return NextResponse.json({ error: r.error }, { status: r.status });
  return NextResponse.json({ ok: true }, { status: 201 });
}
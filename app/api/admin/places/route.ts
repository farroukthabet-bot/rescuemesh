import { NextResponse } from "next/server";
import { z } from "zod";
import { authorize } from "@/lib/auth";
import { createPlaceActor, insideMap } from "@/lib/actors";
import { exclusive } from "@/lib/hedera/onboard";

export const dynamic = "force-dynamic";

const Body = z.object({
  kind: z.enum(["DONOR", "NGO"]),
  name: z.string().trim().min(2).max(60),
  latitude: z.number(),
  longitude: z.number(),
  contactName: z.string().trim().max(60).optional(),
  capacityKg: z.number().positive().max(100000).optional(),
  coldStorage: z.boolean().optional(),
  demand: z.enum(["low", "medium", "high"]).optional(),
});

// Donors and NGOs are added by the administrator (people contact the administrator directly, not through the app).
export async function POST(req: Request) {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  const b = body.data;
  if (!insideMap(b.latitude, b.longitude)) return NextResponse.json({ error: "Pick a position inside the map" }, { status: 400 });
  if (b.kind === "NGO" && !b.capacityKg) return NextResponse.json({ error: "An NGO needs a storage capacity" }, { status: 400 });

  return exclusive(async () => {
    try {
      const p = await createPlaceActor(b.kind, b);
      return NextResponse.json({ ok: true, id: p.id, hederaAccountId: p.accountId, warning: p.warning }, { status: 201 });
    } catch (e) {
      return NextResponse.json({ error: e instanceof Error ? e.message : "Could not create the place" }, { status: 502 });
    }
  });
}
import { NextResponse } from "next/server";
import { countPending, retryPending } from "@/lib/hedera/events";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  return NextResponse.json({ pending: await countPending() });
}

export async function POST() {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  return NextResponse.json(await retryPending());
}
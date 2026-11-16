import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { checkPassword, setSession } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({ email: z.string().trim().toLowerCase().email(), password: z.string().min(1) });

export async function POST(req: Request) {
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Enter your email and password" }, { status: 400 });

  let userId: string | null;
  try {
    userId = await checkPassword(body.data.email, body.data.password);
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : "Sign-in is not configured" }, { status: 500 });
  }
  if (!userId) return NextResponse.json({ error: "Wrong email or password" }, { status: 401 });

  const { data: profile } = await supabase.from("profiles").select("user_id").eq("user_id", userId).maybeSingle();
  if (!profile) return NextResponse.json({ error: "This login is not set up for RescueMesh. Ask the administrator." }, { status: 403 });

  try {
    await setSession(userId);
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : "Could not start the session" }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
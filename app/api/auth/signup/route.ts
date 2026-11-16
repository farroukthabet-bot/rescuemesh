import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { createLogin, setSession } from "@/lib/auth";
import { insideMap } from "@/lib/actors";
import { ApplicationFields, submitApplication } from "@/lib/requests";

export const dynamic = "force-dynamic";

const Body = z.object({
  ...ApplicationFields,
  email: z.string().trim().toLowerCase().email(),
  password: z.string().min(8).max(72),
});

// New people can only apply to be volunteers. Donors and NGOs are added by the administrator.
export async function POST(req: Request) {
  const parsed = Body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Check the form: name, a valid email, a password of at least 8 characters, and your home position" }, { status: 400 });
  const b = parsed.data;
  if (!insideMap(b.latitude, b.longitude)) return NextResponse.json({ error: "Pick a home position inside the map" }, { status: 400 });

  const { data: taken } = await supabase.from("profiles").select("user_id").eq("email", b.email).maybeSingle();
  if (taken) return NextResponse.json({ error: "An account with this email already exists. Sign in, then apply from your account." }, { status: 409 });

  const login = await createLogin(b.email, b.password, b.name);
  if ("error" in login) return NextResponse.json({ error: login.error }, { status: 400 });

  const r = await submitApplication(login.userId, b);
  if (!r.ok) return NextResponse.json({ error: r.error }, { status: r.status });

  await setSession(login.userId);
  return NextResponse.json({ ok: true }, { status: 201 });
}
import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { authorize, createLogin } from "@/lib/auth";

export const dynamic = "force-dynamic";

const Body = z.object({
  email: z.string().trim().toLowerCase().email(),
  name: z.string().trim().min(2).max(60).optional(),
  password: z.string().min(8).max(72).optional(),
  role: z.enum(["ADMIN", "DONOR", "NGO", "VOLUNTEER"]),
  actorId: z.string().optional(),
});

// Gives a person a role. If they have no login yet, one is created (name and password needed).
// An existing login can receive more roles: one login can be donor, NGO and volunteer at once.
export async function POST(req: Request) {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: "Check the form" }, { status: 400 });
  const b = body.data;

  let actorId: string | null = null;
  if (b.role !== "ADMIN") {
    if (!b.actorId) return NextResponse.json({ error: "Choose which place or volunteer this role belongs to" }, { status: 400 });
    const found = b.role === "VOLUNTEER"
      ? (await supabase.from("volunteers").select("id").eq("id", b.actorId).maybeSingle()).data
      : (await supabase.from("organizations").select("id").eq("id", b.actorId).eq("type", b.role).maybeSingle()).data;
    if (!found) return NextResponse.json({ error: "That actor does not exist for this role" }, { status: 400 });
    actorId = b.actorId;
  }

  let { data: profile } = await supabase.from("profiles").select("*").eq("email", b.email).maybeSingle();
  let created = false;
  if (!profile) {
    if (!b.password || !b.name) return NextResponse.json({ error: "This email has no login yet: enter a name and a password (8+ characters)" }, { status: 400 });
    const l = await createLogin(b.email, b.password, b.name);
    if ("error" in l) return NextResponse.json({ error: l.error }, { status: 400 });
    profile = (await supabase.from("profiles").select("*").eq("user_id", l.userId).maybeSingle()).data;
    created = true;
  }
  if (!profile) return NextResponse.json({ error: "Could not load the account" }, { status: 500 });

  const { data: existing } = await supabase.from("memberships").select("*").eq("user_id", profile.user_id).eq("role", b.role).maybeSingle();
  const r = existing
    ? await supabase.from("memberships").update({ actor_id: actorId, status: "ACTIVE" }).eq("id", existing.id)
    : await supabase.from("memberships").insert({ user_id: profile.user_id, role: b.role, actor_id: actorId, status: "ACTIVE" });
  if (r.error) return NextResponse.json({ error: r.error.message }, { status: 500 });
  return NextResponse.json({ ok: true, createdLogin: created, email: profile.email }, { status: 201 });
}
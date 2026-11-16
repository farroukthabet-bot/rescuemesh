import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { getAuth } from "@/lib/auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const auth = await getAuth();
  if (!auth) return NextResponse.json({ error: "Please sign in" }, { status: 401 });

  const ids = auth.memberships.map((m) => m.actor_id).filter((x): x is string => !!x);
  const names = new Map<string, string>();
  if (ids.length) {
    const [{ data: orgs }, { data: vols }] = await Promise.all([
      supabase.from("organizations").select("id, name").in("id", ids),
      supabase.from("volunteers").select("id, name").in("id", ids),
    ]);
    for (const x of [...(orgs ?? []), ...(vols ?? [])]) names.set(x.id as string, x.name as string);
  }
  return NextResponse.json({
    user: { id: auth.userId, name: auth.name, email: auth.email },
    isAdmin: auth.isAdmin,
    memberships: auth.memberships.map((m) => ({
      role: m.role, status: m.status, actorId: m.actor_id, actorName: m.actor_id ? names.get(m.actor_id) ?? m.actor_id : null,
    })),
  });
}
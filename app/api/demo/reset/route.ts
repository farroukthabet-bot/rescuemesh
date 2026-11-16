import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Demo reset = archive. Rows stay in the database (so old /verify links keep working and IDs never repeat),
// they just disappear from the dashboard. HCS messages can never be deleted, and we don't pretend they can.
export async function POST() {
  const g = await authorize("ADMIN");
  if (!g.ok) return g.res;
  const { data, error } = await supabase
    .from("donations")
    .update({ archived: true })
    .eq("archived", false)
    .select("id");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ archived: data?.length ?? 0 });
}
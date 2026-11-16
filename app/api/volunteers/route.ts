import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Volunteers are no longer created here: people apply (see /join) and an administrator approves them.
export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase.from("volunteers").select("*");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
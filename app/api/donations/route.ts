import { NextResponse } from "next/server";
import { z } from "zod";
import { supabase } from "@/lib/db/supabase";
import { recordEvent } from "@/lib/hedera/events";
import { authorize } from "@/lib/auth";

export const dynamic = "force-dynamic";

const CreateDonation = z.object({
  foodType: z.string().min(1),
  quantityKg: z.number().positive(),
  storageRequirement: z.enum(["ambient", "refrigerated"]),
  expiresInMinutes: z.number().int().positive().max(1440),
});

async function nextDonationId(): Promise<string> {
  const { data } = await supabase
    .from("donations")
    .select("id")
    .order("id", { ascending: false })
    .limit(1);
  const last = data?.[0]?.id ? parseInt(data[0].id.replace("RM-", ""), 10) : 0;
  return `RM-${String(last + 1).padStart(3, "0")}`;
}

export async function GET() {
  const g = await authorize();
  if (!g.ok) return g.res;
  const { data, error } = await supabase
    .from("donations")
    .select("*")
    .eq("archived", false)
    .order("created_at", { ascending: false });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}

export async function POST(req: Request) {
  // Only a donor can create a donation, and always for their own place: the donor comes from the account.
  const g = await authorize("DONOR");
  if (!g.ok) return g.res;
  const parsed = CreateDonation.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });
  }
  const d = parsed.data;

  // The donor must exist and be a DONOR; pickup coordinates come from the database.
  const { data: donor } = await supabase
    .from("organizations")
    .select("id, latitude, longitude")
    .eq("id", g.actorId ?? "")
    .eq("type", "DONOR")
    .maybeSingle();
  if (!donor) return NextResponse.json({ error: "Unknown donor" }, { status: 400 });

  const id = await nextDonationId();
  const expiresAt = new Date(Date.now() + d.expiresInMinutes * 60_000).toISOString();

  const { data: donation, error } = await supabase
    .from("donations")
    .insert({
      id,
      donor_id: donor.id,
      food_type: d.foodType,
      quantity_kg: d.quantityKg,
      storage_requirement: d.storageRequirement,
      pickup_latitude: donor.latitude,
      pickup_longitude: donor.longitude,
      expires_at: expiresAt,
      status: "AVAILABLE",
    })
    .select()
    .single();
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // Public ledger: no personal data, only essential metadata.
  const hedera = await recordEvent(id, "DONATION_CREATED", donor.id, {
    donorId: donor.id,
    foodType: d.foodType,
    quantityKg: d.quantityKg,
    status: "AVAILABLE",
  }, g.auth.userId);

  return NextResponse.json({ donation, hedera }, { status: 201 });
}
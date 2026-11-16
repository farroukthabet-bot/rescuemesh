# RescueMesh: writes the Phase 4 files to their exact paths.
# Run from the project root (C:\Users\farou\rescuemesh):  powershell -ExecutionPolicy Bypass -File .\apply-phase4.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path

function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}

Write-File 'lib/missions.ts' @'
import { supabase } from "@/lib/db/supabase";
import { evaluate, type Donation, type Ngo, type Volunteer } from "@/lib/ai/scoring";
import { recordEvent } from "@/lib/hedera/events";

async function nextMissionId(): Promise<string> {
  const { data } = await supabase.from("missions").select("id").order("id", { ascending: false }).limit(1);
  const last = data?.[0]?.id ? parseInt(data[0].id.replace("M-", ""), 10) : 0;
  return `M-${String(last + 1).padStart(3, "0")}`;
}

const getDonation = async (id: string) =>
  (await supabase.from("donations").select("*").eq("id", id).maybeSingle()).data;

const getMission = async (donationId: string) =>
  (await supabase.from("missions").select("*").eq("donation_id", donationId).maybeSingle()).data;

/** Atomic status change: only succeeds if the donation is still in the `from` status. */
async function moveStatus(id: string, from: string, to: string) {
  const { data } = await supabase.from("donations").update({ status: to }).eq("id", id).eq("status", from).select("id");
  return (data?.length ?? 0) === 1;
}

// ---------------------------------------------------------------- ACCEPT
export async function acceptMission(donationId: string, ngoId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  if (!donation) return { httpStatus: 404, error: "Donation not found" };
  if (donation.status !== "AVAILABLE")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected AVAILABLE` };

  // Never trust the client (or the AI): re-validate the pair against fresh database data.
  const [{ data: ngos }, { data: vols }] = await Promise.all([
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], (vols ?? []) as Volunteer[]);
  const pair = ev.candidates.find((c) => c.ngo.id === ngoId && c.volunteer.id === volunteerId);
  if (!pair) return { httpStatus: 400, error: "This NGO + volunteer combination is not valid", rejected: ev.rejected };

  if (!(await moveStatus(donationId, "AVAILABLE", "PICKUP_PENDING")))
    return { httpStatus: 409, error: "Donation was just taken by another request" };

  const { data: mission, error } = await supabase
    .from("missions")
    .insert({
      id: await nextMissionId(),
      donation_id: donationId,
      ngo_id: ngoId,
      volunteer_id: volunteerId,
      match_score: pair.score,
      estimated_pickup_minutes: pair.estimatedPickupMinutes,
      estimated_delivery_minutes: pair.estimatedDeliveryMinutes,
      status: "PICKUP_PENDING",
      accepted_at: new Date().toISOString(),
    })
    .select()
    .single();
  if (error) {
    await moveStatus(donationId, "PICKUP_PENDING", "AVAILABLE"); // roll back
    return { httpStatus: 500, error: error.message };
  }

  // Sequential on purpose: keeps HCS sequence numbers in the same order as the workflow.
  const matched = await recordEvent(donationId, "NGO_MATCHED", { ngoId, volunteerId, matchScore: pair.score });
  const assigned = await recordEvent(donationId, "VOLUNTEER_ASSIGNED", { volunteerId });

  return { httpStatus: 201, mission, hedera: [matched, assigned] };
}

// ---------------------------------------------------------------- PICKUP
export async function confirmPickup(donationId: string, volunteerId: string) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKUP_PENDING")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKUP_PENDING` };
  if (mission.volunteer_id !== volunteerId)
    return { httpStatus: 403, error: "Only the assigned volunteer can confirm pickup" };

  if (!(await moveStatus(donationId, "PICKUP_PENDING", "PICKED_UP")))
    return { httpStatus: 409, error: "Pickup was already confirmed" };

  const { data: updated } = await supabase
    .from("missions")
    .update({ status: "PICKED_UP", pickup_at: new Date().toISOString() })
    .eq("id", mission.id)
    .select()
    .single();

  const hedera = await recordEvent(donationId, "PICKUP_CONFIRMED", { confirmedBy: volunteerId });
  return { httpStatus: 200, mission: updated, hedera };
}

// ---------------------------------------------------------------- DELIVERY
export async function confirmDelivery(donationId: string, ngoId: string, quantityReceivedKg: number) {
  const donation = await getDonation(donationId);
  const mission = await getMission(donationId);
  if (!donation || !mission) return { httpStatus: 404, error: "No mission for this donation" };
  if (donation.status !== "PICKED_UP")
    return { httpStatus: 409, error: `Donation is ${donation.status}, expected PICKED_UP` };
  if (mission.ngo_id !== ngoId)
    return { httpStatus: 403, error: "Only the receiving NGO can confirm delivery" };
  if (quantityReceivedKg > Number(donation.quantity_kg))
    return { httpStatus: 400, error: `Received quantity cannot exceed the donated ${donation.quantity_kg} kg` };

  if (!(await moveStatus(donationId, "PICKED_UP", "COMPLETED")))
    return { httpStatus: 409, error: "Delivery was already confirmed" };

  const { data: updated } = await supabase
    .from("missions")
    .update({ status: "COMPLETED", delivery_at: new Date().toISOString() })
    .eq("id", mission.id)
    .select()
    .single();

  const hedera = await recordEvent(donationId, "DELIVERY_CONFIRMED", { confirmedBy: ngoId, quantityReceivedKg });
  return { httpStatus: 200, mission: updated, hedera };
}
'@

Write-File 'lib/ai/coordinator.ts' @'
import { z } from "zod";
import type { Candidate } from "./scoring";

const Decision = z.object({
  ngoId: z.string(),
  volunteerId: z.string(),
  explanation: z.string().min(1),
});

// Written by hand (works with any zod version) and sent to Ollama to force valid JSON.
const DECISION_SCHEMA = {
  type: "object",
  properties: {
    ngoId: { type: "string" },
    volunteerId: { type: "string" },
    explanation: { type: "string" },
  },
  required: ["ngoId", "volunteerId", "explanation"],
};

const SYSTEM_PROMPT = `You are RescueMesh Coordinator.
Your task is to select the safest and most efficient NGO and volunteer combination for a food rescue mission.

You MUST:
1. Only use the provided data.
2. Never invent availability, capacity, distance or times.
3. Choose ONLY one of the provided candidates: ngoId and volunteerId must belong to the same candidate.
4. Prioritize successful delivery before expiration.
5. Return JSON only, with keys ngoId, volunteerId, explanation.
6. explanation: at most 2 sentences, written in English, using only facts from the chosen candidate.
7. In the explanation, refer to the NGO and the volunteer by NAME (ngoName, volunteerName), never by ID, and do not compare with candidates you did not choose.

You are making a recommendation. The backend validates every hard constraint before executing the mission.`;

export async function askCoordinator(
  donation: { quantityKg: number; foodType: string; storageRequirement: string; minutesUntilExpiration: number },
  candidates: Candidate[]
) {
  const input = {
    donation,
    candidates: candidates.map((c) => ({
      ngoId: c.ngo.id,
      ngoName: c.ngo.name,
      ngoCapacityKg: c.ngo.storage_capacity_kg,
      ngoColdStorage: c.ngo.has_cold_storage,
      ngoCurrentDemand: c.ngo.current_demand,
      volunteerId: c.volunteer.id,
      volunteerName: c.volunteer.name,
      volunteerTransport: c.volunteer.transport_type,
      volunteerCapacityKg: c.volunteer.transport_capacity_kg,
      routeKm: Math.round((c.volunteerToDonorKm + c.donorToNgoKm) * 10) / 10,
      estimatedDeliveryMinutes: c.estimatedDeliveryMinutes,
      riskLevel: c.riskLevel,
      score: c.score,
    })),
  };

  const res = await fetch(`${process.env.OLLAMA_URL ?? "http://localhost:11434"}/api/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: AbortSignal.timeout(90_000), // first call can be slow while the model loads
    body: JSON.stringify({
      model: process.env.OLLAMA_MODEL ?? "llama3.2:3b",
      stream: false,
      format: DECISION_SCHEMA,
      options: { temperature: 0 },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: JSON.stringify(input) },
      ],
    }),
  });
  if (!res.ok) throw new Error(`Ollama HTTP ${res.status}`);
  const data = await res.json();
  return Decision.parse(JSON.parse(data.message.content));
}
'@

Write-File 'app/api/donations/[id]/route.ts' @'
import { NextResponse } from "next/server";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

// Donation + mission + Hedera event references (used by the details and verification pages).
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { data: donation } = await supabase.from("donations").select("*").eq("id", id).maybeSingle();
  if (!donation) return NextResponse.json({ error: "Donation not found" }, { status: 404 });

  const [{ data: mission }, { data: events }] = await Promise.all([
    supabase.from("missions").select("*").eq("donation_id", id).maybeSingle(),
    supabase.from("hedera_events").select("*").eq("donation_id", id).order("created_at", { ascending: true }),
  ]);
  return NextResponse.json({ donation, mission, events });
}
'@

Write-File 'app/api/donations/[id]/match/route.ts' @'
import { NextResponse } from "next/server";
import { findMatch } from "@/lib/ai/match";

export const dynamic = "force-dynamic";

export async function POST(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { httpStatus, ...body } = await findMatch(id);
  return NextResponse.json(body, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/accept/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { acceptMission } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ ngoId: z.string().min(1), volunteerId: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await acceptMission(id, body.data.ngoId, body.data.volunteerId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/pickup/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { confirmPickup } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ volunteerId: z.string().min(1) });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmPickup(id, body.data.volunteerId);
  return NextResponse.json(res, { status: httpStatus });
}
'@

Write-File 'app/api/donations/[id]/deliver/route.ts' @'
import { NextResponse } from "next/server";
import { z } from "zod";
import { confirmDelivery } from "@/lib/missions";

export const dynamic = "force-dynamic";

const Body = z.object({ ngoId: z.string().min(1), quantityReceivedKg: z.number().positive() });

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = Body.safeParse(await req.json().catch(() => null));
  if (!body.success) return NextResponse.json({ error: body.error.flatten() }, { status: 400 });
  const { httpStatus, ...res } = await confirmDelivery(id, body.data.ngoId, body.data.quantityReceivedKg);
  return NextResponse.json(res, { status: httpStatus });
}
'@


Write-Host ""
Write-Host "route.ts files now in app\api (expect 8):"
[System.IO.Directory]::GetFiles("$root\app\api", "route.ts", [System.IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Replace($root + "\", "") }

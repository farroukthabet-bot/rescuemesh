import { supabase } from "@/lib/db/supabase";
import { evaluate, type Candidate, type Donation, type Ngo, type Volunteer } from "./scoring";
import { askCoordinator } from "./coordinator";
import { busyVolunteerIds } from "@/lib/busy";

const MAX_LLM_ATTEMPTS = 2;

export async function findMatch(donationId: string, donorId?: string) {
  const { data: donation } = await supabase.from("donations").select("*").eq("id", donationId).maybeSingle();
  if (!donation) return { error: "Donation not found", httpStatus: 404 as const };
  if (donorId && donation.donor_id !== donorId) return { error: "This is not your donation", httpStatus: 403 as const };
  if (donation.status !== "AVAILABLE")
    return { error: `Donation is ${donation.status}, only AVAILABLE donations can be matched`, httpStatus: 409 as const };

  const [{ data: ngos }, { data: volunteers }] = await Promise.all([
    supabase.from("organizations").select("*").eq("type", "NGO"),
    supabase.from("volunteers").select("*"),
  ]);

  // Everything the AI will see comes from the database + deterministic code.
  const busy = await busyVolunteerIds();
  const crew = (volunteers ?? []).map((v) => (busy.has(v.id) ? { ...v, available: false, busy: true } : v)) as Volunteer[];
  const ev = evaluate(donation as Donation, (ngos ?? []) as Ngo[], crew);

  if (ev.candidates.length === 0) {
    return { httpStatus: 200 as const, matched: false, donationId, analysis: { ...ev.stats, minutesUntilExpiration: ev.minutesLeft }, rejected: ev.rejected };
  }

  const shortlist = ev.candidates.slice(0, 3);
  let chosen: Candidate = shortlist[0];
  let explanation = "";
  let source: "llm" | "deterministic-fallback" = "deterministic-fallback";

  for (let attempt = 0; attempt < MAX_LLM_ATTEMPTS; attempt++) {
    try {
      const d = await askCoordinator(
        {
          quantityKg: Number(donation.quantity_kg),
          foodType: donation.food_type,
          storageRequirement: donation.storage_requirement,
          minutesUntilExpiration: ev.minutesLeft,
        },
        shortlist
      );
      // Backend validation: the AI may only pick a pair that passed every hard constraint.
      const valid = shortlist.find((c) => c.ngo.id === d.ngoId && c.volunteer.id === d.volunteerId);
      if (!valid) throw new Error(`AI decision rejected: ${d.ngoId}+${d.volunteerId} is not a valid candidate`);
      chosen = valid;
      explanation = d.explanation;
      source = "llm";
      break;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[ai] attempt ${attempt + 1} failed:`, msg);
      // A second try only helps if the model answered badly. If Ollama is down or timed out, fall back now.
      const badAnswer = err instanceof SyntaxError || (err instanceof Error && err.name === "ZodError") || msg.startsWith("AI decision rejected");
      if (!badAnswer) break;
    }
  }

  if (source === "deterministic-fallback") {
    explanation =
      `I selected ${chosen.ngo.name} because it has enough capacity` +
      (donation.storage_requirement === "refrigerated" ? " and cold storage" : "") +
      `. ${chosen.volunteer.name} can transport the full donation and the estimated delivery is within the expiration window.`;
  }

  return {
    httpStatus: 200 as const,
    matched: true,
    donationId,
    recommendation: {
      ngoId: chosen.ngo.id,
      ngoName: chosen.ngo.name,
      ngoDistanceKm: chosen.donorToNgoKm,
      volunteerId: chosen.volunteer.id,
      volunteerName: chosen.volunteer.name,
      estimatedPickupMinutes: chosen.estimatedPickupMinutes,
      estimatedDeliveryMinutes: chosen.estimatedDeliveryMinutes,
      riskLevel: chosen.riskLevel,
      matchScore: chosen.score,
      reason: chosen.reason,
      explanation,
      source,
    },
    analysis: { ...ev.stats, minutesUntilExpiration: ev.minutesLeft },
    rejected: ev.rejected,
  };
}
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
    signal: AbortSignal.timeout(60_000), // first call can be slow while the model loads
    body: JSON.stringify({
      model: process.env.OLLAMA_MODEL ?? "llama3.2:3b",
      stream: false,
      keep_alive: "30m", // keep the model in memory between demo runs
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
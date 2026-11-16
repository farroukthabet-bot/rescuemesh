// Deterministic part of the matching engine: hard constraints, ETA, risk, scoring.
// The LLM never computes any of these numbers, it only receives them.

export const MAX_ROUTE_KM = 3;    // volunteer -> donor -> NGO route limit (sized for the Centre Urbain Nord demo area)
export const SPEED_KMH = 25;      // assumed average urban speed
export const HANDLING_MIN = 5;    // loading time, and unloading time

export type Donation = {
  id: string;
  food_type: string;
  quantity_kg: number;
  storage_requirement: "ambient" | "refrigerated";
  pickup_latitude: number;
  pickup_longitude: number;
  expires_at: string;
};
export type Ngo = {
  id: string; name: string; latitude: number; longitude: number;
  storage_capacity_kg: number; has_cold_storage: boolean; current_demand: string | null;
};
export type Volunteer = {
  id: string; name: string; latitude: number; longitude: number;
  transport_type: string; transport_capacity_kg: number; has_cold_storage: boolean; available: boolean; busy?: boolean;
};

export type Candidate = {
  ngo: Ngo;
  volunteer: Volunteer;
  score: number; // 0-100
  volunteerToDonorKm: number;
  donorToNgoKm: number;
  estimatedPickupMinutes: number;
  estimatedDeliveryMinutes: number;
  riskLevel: "LOW" | "MEDIUM" | "HIGH";
  reason: string[];
};
export type Rejection = { type: "ngo" | "volunteer" | "pair"; id: string; name: string; reasons: string[] };

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number) {
  const R = 6371, rad = (d: number) => (d * Math.PI) / 180;
  const a =
    Math.sin(rad(lat2 - lat1) / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lon2 - lon1) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const round1 = (n: number) => Math.round(n * 10) / 10;
const clamp01 = (n: number) => Math.max(0, Math.min(1, n));

export function evaluate(donation: Donation, ngos: Ngo[], volunteers: Volunteer[], now = Date.now()) {
  const qty = Number(donation.quantity_kg);
  const minutesLeft = (Date.parse(donation.expires_at) - now) / 60000;
  const needCold = donation.storage_requirement === "refrigerated";
  const rejected: Rejection[] = [];

  // 1) Hard constraints per NGO
  const okNgos = ngos.filter((n) => {
    const r: string[] = [];
    if (Number(n.storage_capacity_kg) < qty) r.push(`Capacity ${n.storage_capacity_kg} kg is below ${qty} kg`);
    if (needCold && !n.has_cold_storage) r.push("No cold storage");
    if (r.length) rejected.push({ type: "ngo", id: n.id, name: n.name, reasons: r });
    return r.length === 0;
  });

  // 2) Hard constraints per volunteer
  const okVols = volunteers.filter((v) => {
    const r: string[] = [];
    if (!v.available) r.push(v.busy ? "Already on another mission" : "Not available");
    if (Number(v.transport_capacity_kg) < qty) r.push(`Transport capacity ${v.transport_capacity_kg} kg is below ${qty} kg`);
    if (needCold && !v.has_cold_storage) r.push("No refrigerated transport");
    if (r.length) rejected.push({ type: "volunteer", id: v.id, name: v.name, reasons: r });
    return r.length === 0;
  });

  // 3) Pair constraints (route length, arrival before expiration) + scoring
  const candidates: Candidate[] = [];
  for (const v of okVols) {
    for (const n of okNgos) {
      const vToD = haversineKm(v.latitude, v.longitude, donation.pickup_latitude, donation.pickup_longitude);
      const dToN = haversineKm(donation.pickup_latitude, donation.pickup_longitude, n.latitude, n.longitude);
      const pickupMin = Math.round((vToD / SPEED_KMH) * 60) + HANDLING_MIN;
      const deliveryMin = pickupMin + Math.round((dToN / SPEED_KMH) * 60) + HANDLING_MIN;

      const pairReasons: string[] = [];
      if (vToD + dToN > MAX_ROUTE_KM) pairReasons.push(`Route of ${round1(vToD + dToN)} km exceeds ${MAX_ROUTE_KM} km`);
      if (deliveryMin >= minutesLeft) pairReasons.push(`Delivery in ${deliveryMin} min is not before expiration (${Math.floor(minutesLeft)} min left)`);
      if (pairReasons.length) {
        rejected.push({ type: "pair", id: `${n.id}+${v.id}`, name: `${n.name} + ${v.name}`, reasons: pairReasons });
        continue;
      }

      const margin = (minutesLeft - deliveryMin) / minutesLeft;
      const proximity = 1 - clamp01((vToD + dToN) / MAX_ROUTE_KM);
      const capacityFit =
        (clamp01(Number(n.storage_capacity_kg) / (qty * 1.5)) + clamp01(Number(v.transport_capacity_kg) / (qty * 1.5))) / 2;
      const expirationSafety = clamp01(margin);
      const storageCompat = 1; // hard constraints already guarantee compatibility
      const score = Math.round(100 * (0.3 * proximity + 0.25 * capacityFit + 0.25 * expirationSafety + 0.2 * storageCompat));

      const reason = [
        `${n.name} has ${n.storage_capacity_kg} kg capacity for a ${qty} kg donation`,
        ...(needCold ? [`${n.name} has cold storage and ${v.name} has refrigerated transport`] : []),
        `${v.name} can carry up to ${v.transport_capacity_kg} kg by ${v.transport_type.toLowerCase()}`,
        `Estimated delivery in ${deliveryMin} min, ${Math.floor(minutesLeft - deliveryMin)} min before expiration`,
      ];

      candidates.push({
        ngo: n, volunteer: v, score,
        volunteerToDonorKm: round1(vToD), donorToNgoKm: round1(dToN),
        estimatedPickupMinutes: pickupMin, estimatedDeliveryMinutes: deliveryMin,
        riskLevel: margin >= 0.5 ? "LOW" : margin >= 0.2 ? "MEDIUM" : "HIGH",
        reason,
      });
    }
  }
  candidates.sort((a, b) => b.score - a.score);

  return {
    candidates, rejected,
    minutesLeft: Math.floor(minutesLeft),
    stats: {
      ngosConsidered: ngos.length, volunteersConsidered: volunteers.length,
      ngosEligible: okNgos.length, volunteersEligible: okVols.length,
    },
  };
}
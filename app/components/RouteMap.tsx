import { haversineKm } from "@/lib/ai/scoring";

type P = { lat: number; lng: number; label: string };

const C = { volunteer: "#1F5FBF", donor: "#C77D0A", ngo: "#1F4D3A" };

// Schematic map drawn from database coordinates. No tiles, no API key, works offline.
export default function RouteMap({ donor, volunteer, ngo }: { donor: P; volunteer: P; ngo: P }) {
  const W = 440, H = 250, PAD = 48;
  const pts = [volunteer, donor, ngo];
  const midLat = (Math.min(...pts.map((p) => p.lat)) + Math.max(...pts.map((p) => p.lat))) / 2;
  const k = Math.cos((midLat * Math.PI) / 180);
  const xs = pts.map((p) => p.lng * k);
  const ys = pts.map((p) => -p.lat);
  const minX = Math.min(...xs), minY = Math.min(...ys);
  const spanX = Math.max(Math.max(...xs) - minX, 1e-6);
  const spanY = Math.max(Math.max(...ys) - minY, 1e-6);
  const scale = Math.min((W - 2 * PAD) / spanX, (H - 2 * PAD) / spanY);
  const ox = (W - spanX * scale) / 2, oy = (H - spanY * scale) / 2;
  const proj = (p: P) => ({ x: ox + (p.lng * k - minX) * scale, y: oy + (-p.lat - minY) * scale });

  const v = proj(volunteer), d = proj(donor), n = proj(ngo);
  const toDonor = haversineKm(volunteer.lat, volunteer.lng, donor.lat, donor.lng);
  const toNgo = haversineKm(donor.lat, donor.lng, ngo.lat, ngo.lng);

  return (
    <figure>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" className="w-full max-w-md border border-[#16231C]/15 bg-white"
        aria-label={`Route: ${volunteer.label} to ${donor.label}, then to ${ngo.label}`}>
        <defs>
          <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill="#16231C" fillOpacity="0.55" />
          </marker>
        </defs>
        <line x1={v.x} y1={v.y} x2={d.x} y2={d.y} stroke={C.volunteer} strokeWidth="2" strokeDasharray="5 4" markerEnd="url(#arrow)" />
        <line x1={d.x} y1={d.y} x2={n.x} y2={n.y} stroke={C.ngo} strokeWidth="2.5" markerEnd="url(#arrow)" />
        <circle cx={v.x} cy={v.y} r="8" fill={C.volunteer} />
        <circle cx={n.x} cy={n.y} r="8" fill={C.ngo} />
        <circle cx={d.x} cy={d.y} r="8" fill={C.donor} stroke="#fff" strokeWidth="2" />
        <text x={v.x} y={v.y - 14} textAnchor="middle" fontSize="12" fill="#16231C">{volunteer.label}</text>
        <text x={d.x} y={d.y + 24} textAnchor="middle" fontSize="12" fill="#16231C">{donor.label}</text>
        <text x={n.x} y={n.y + 24} textAnchor="middle" fontSize="12" fill="#16231C">{ngo.label}</text>
      </svg>
      <figcaption className="mt-2 text-xs text-[#16231C]/60">
        Volunteer to donor {toDonor.toFixed(1)} km (dashed), donor to NGO {toNgo.toFixed(1)} km. Schematic map from stored coordinates.
      </figcaption>
    </figure>
  );
}
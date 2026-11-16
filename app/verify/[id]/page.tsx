import Link from "next/link";
import Logo from "../../components/Logo";
import { notFound } from "next/navigation";
import { createHash } from "crypto";
import { supabase } from "@/lib/db/supabase";

export const dynamic = "force-dynamic";

const MIRROR = "https://testnet.mirrornode.hedera.com/api/v1";

// Current flow: two handoffs, each needs two signatures from two different accounts.
const STEPS: [string, string][] = [
  ["DONATION_CREATED", "Donation created"],
  ["NGO_MATCHED", "NGO matched by the coordinator"],
  ["VOLUNTEER_ASSIGNED", "Volunteer accepted the mission"],
  ["DONOR_HANDOVER_CONFIRMED", "Donor confirmed the handover"],
  ["PICKUP_CONFIRMED", "Volunteer confirmed the pickup"],
  ["DROPOFF_CONFIRMED", "Volunteer confirmed the drop-off"],
  ["DELIVERY_CONFIRMED", "NGO confirmed the delivery"],
];
// Donations recorded before per-actor accounts existed.
const LEGACY_STEPS: [string, string][] = [
  ["DONATION_CREATED", "Donation created"],
  ["NGO_MATCHED", "NGO matched"],
  ["VOLUNTEER_ASSIGNED", "Volunteer assigned"],
  ["PICKUP_CONFIRMED", "Pickup confirmed"],
  ["DELIVERY_CONFIRMED", "Delivery confirmed"],
];

type EventRow = {
  event_type: string; status: string; actor_id: string | null; signer_account_id: string | null;
  hedera_topic_id: string | null; hedera_sequence_number: string | null; payload_hash: string | null;
};
type Check = { state: "verified" | "pending" | "unreachable" | "mismatch" | "missing"; consensus?: string; payer?: string };

// Read the message back from the public Mirror Node, compare its hash with the one we stored,
// and check that the account that paid for (and therefore signed) the message is the one we recorded.
async function check(ev?: EventRow): Promise<Check> {
  if (!ev) return { state: "missing" };
  if (ev.status !== "CONFIRMED") return { state: "pending" };
  try {
    const r = await fetch(`${MIRROR}/topics/${ev.hedera_topic_id}/messages/${ev.hedera_sequence_number}`, { cache: "no-store" });
    if (!r.ok) return { state: "unreachable" };
    const m = await r.json();
    const text = Buffer.from(m.message, "base64").toString("utf8");
    const hash = createHash("sha256").update(text).digest("hex");
    const payer: string | undefined = m.payer_account_id;
    const sameContent = hash === ev.payload_hash;
    const sameSigner = !ev.signer_account_id || !payer || payer === ev.signer_account_id;
    return { state: sameContent && sameSigner ? "verified" : "mismatch", consensus: m.consensus_timestamp, payer };
  } catch {
    return { state: "unreachable" };
  }
}

const time = (ts?: string) => (ts ? new Date(Number(ts.split(".")[0]) * 1000).toISOString().slice(11, 19) + " UTC" : "");
const LABEL: Record<Check["state"], string> = {
  verified: "Read back from Hedera, content and signer match",
  pending: "Pending verification",
  unreachable: "Mirror Node not reachable yet, refresh in a few seconds",
  mismatch: "Does not match the ledger (content or signer)",
  missing: "Not reached yet",
};

export default async function VerifyPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { data: donation } = await supabase.from("donations").select("*").eq("id", id).maybeSingle();
  if (!donation) notFound();

  const [{ data }, { data: orgs }, { data: vols }, { data: accts }] = await Promise.all([
    supabase.from("hedera_events").select("*").eq("donation_id", id),
    supabase.from("organizations").select("id, name"),
    supabase.from("volunteers").select("id, name"),
    supabase.from("actor_accounts").select("actor_id, hedera_account_id"),
  ]);
  const rows = (data ?? []) as EventRow[];
  const names = new Map<string, string>([...(orgs ?? []), ...(vols ?? [])].map((x) => [x.id as string, x.name as string]));
  const ownAccount = new Map<string, string>((accts ?? []).map((a) => [a.actor_id as string, a.hedera_account_id as string]));

  const legacy = rows.length > 0 && rows.every((e) => !e.actor_id);
  const steps = legacy ? LEGACY_STEPS : STEPS;
  const byType = new Map(rows.map((e) => [e.event_type, e]));
  const checks = await Promise.all(steps.map(([t]) => check(byType.get(t))));
  const allVerified = checks.every((c) => c.state === "verified");
  const topic = rows.find((e) => e.hedera_topic_id)?.hedera_topic_id;

  // Who signed: the actor's own account, or the platform acting on their behalf.
  function signer(ev: EventRow | undefined, c: Check) {
    if (!ev || !ev.actor_id) return null;
    const acct = c.payer ?? ev.signer_account_id ?? undefined;
    const who = ev.actor_id === "PLATFORM" ? "RescueMesh coordinator" : names.get(ev.actor_id) ?? ev.actor_id;
    const own = ownAccount.get(ev.actor_id);
    const onBehalf = ev.actor_id !== "PLATFORM" && (!own || (acct && own !== acct));
    return { who, acct, onBehalf };
  }

  return (
    <main className="min-h-screen bg-[#0D0C16] text-[#ECEAF8]">
      <div className="mx-auto max-w-2xl px-5 py-10">
        <Link href="/" className="inline-flex items-center gap-2.5 text-sm text-[#C9BEFF] underline underline-offset-2"><Logo size={30} />Back to dashboard</Link>
        <h1 className="mt-4 font-[family-name:var(--font-heading)] text-4xl font-semibold tracking-tight">Donation {id}</h1>
        <p className="mt-1 text-[#ECEAF8]/70">{donation.quantity_kg} kg of {String(donation.food_type).toLowerCase()}, currently {String(donation.status).toLowerCase().replace(/_/g, " ")}.</p>

        <p className={`mt-6 inline-block px-3 py-1.5 font-[family-name:var(--font-heading)] text-lg font-semibold ${allVerified ? "bg-[#34D3A0] text-[#0D0C16]" : "bg-[#FBBF24]/15 text-[#FCD34D]"}`}>
          {allVerified ? "Verified by Hedera" : "Not fully verified yet"}
        </p>

        <ol className="mt-8 border-l-2 border-[#ECEAF8]/25">
          {steps.map(([type, title], i) => {
            const c = checks[i];
            const ev = byType.get(type);
            const ok = c.state === "verified";
            const sg = signer(ev, c);
            return (
              <li key={type} className="relative pb-7 pl-6">
                <span aria-hidden className={`absolute -left-[9px] top-1 h-4 w-4 rounded-full border-2 ${ok ? "border-[#34D3A0] bg-[#34D3A0]" : "border-[#ECEAF8]/35 bg-[#0D0C16]"}`} />
                <p className="font-medium">{title}</p>
                <p className="text-sm text-[#ECEAF8]/65">
                  {c.consensus ? `${time(c.consensus)}, ` : ""}{LABEL[c.state]}
                </p>
                {sg && (
                  <p className="text-sm text-[#ECEAF8]/65">
                    {sg.onBehalf ? `Signed by the platform on behalf of ${sg.who}` : `Signed by ${sg.who}`}
                    {sg.acct && (
                      <>
                        {" "}(<a className="font-mono text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/account/${sg.acct}`} target="_blank" rel="noreferrer">{sg.acct}</a>)
                      </>
                    )}
                  </p>
                )}
                {ev?.hedera_sequence_number && (
                  <p className="mt-0.5 font-mono text-xs text-[#ECEAF8]/55">sequence {ev.hedera_sequence_number}</p>
                )}
              </li>
            );
          })}
        </ol>

        <div className="mt-2 border-t border-[#ECEAF8]/15 pt-5 text-sm">
          <p>
            Each row was fetched from the public Hedera Mirror Node. Its content hash is compared with the hash saved by RescueMesh,
            and the account that signed it is compared with the one we recorded, so this page does not rely on our database alone.
          </p>
          {!legacy && (
            <p className="mt-3">
              Each handoff needs two signatures from two different accounts: donor and volunteer at pickup, volunteer and NGO at delivery.
              Only registered accounts can write to the topic.
            </p>
          )}
          {topic && (
            <p className="mt-3">
              Hedera Consensus Service topic <span className="font-mono">{topic}</span>{" "}
              <a className="text-[#C9BEFF] underline underline-offset-2" href={`https://hashscan.io/testnet/topic/${topic}`} target="_blank" rel="noreferrer">
                Open on HashScan
              </a>
            </p>
          )}
        </div>
      </div>
    </main>
  );
}
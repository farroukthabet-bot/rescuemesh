import crypto from "crypto";
import { PrivateKey } from "@hashgraph/sdk";
import { supabase } from "@/lib/db/supabase";

export type Signer = { actorId: string; accountId: string; key: PrivateKey; viaPlatform: boolean };

// Each actor (donor, NGO, volunteer) has its OWN Hedera account. Its private key is stored encrypted
// (AES-256-GCM) in the actor_accounts table. In this demo the server decrypts the key to sign for the actor
// (custodial). In production the key would live in the actor's own wallet and the signature would come from there.

function secret(): Buffer {
  const hex = process.env.KEY_ENCRYPTION_SECRET ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("KEY_ENCRYPTION_SECRET must be 64 hex characters (see .env.local)");
  return Buffer.from(hex, "hex");
}

// Format: iv:authTag:ciphertext (base64). Must match scripts/setup-actors.mjs.
export function encryptSecret(plain: string): string {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", secret(), iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString("base64")).join(":");
}

export function decryptSecret(blob: string): string {
  const [iv, tag, enc] = blob.split(":").map((p) => Buffer.from(p, "base64"));
  const d = crypto.createDecipheriv("aes-256-gcm", secret(), iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]).toString("utf8");
}

function platform(): Signer {
  return {
    actorId: "PLATFORM",
    accountId: process.env.HEDERA_ACCOUNT_ID!,
    key: PrivateKey.fromStringECDSA(process.env.HEDERA_PRIVATE_KEY!),
    viaPlatform: false,
  };
}

const cache = new Map<string, Signer>();

/** Who signs for this actor. PLATFORM = the coordinator account from .env.local. */
export async function getSigner(actorId: string): Promise<Signer> {
  if (actorId === "PLATFORM") return platform();
  const hit = cache.get(actorId);
  if (hit) return hit;

  const { data } = await supabase.from("actor_accounts").select("*").eq("actor_id", actorId).maybeSingle();
  // Actor without its own account (setup not run yet): fall back to the platform account and say so.
  if (!data) return { ...platform(), actorId, viaPlatform: true };

  const signer: Signer = {
    actorId,
    accountId: data.hedera_account_id,
    key: PrivateKey.fromStringDer(decryptSecret(data.encrypted_private_key)),
    viaPlatform: false,
  };
  cache.set(actorId, signer);
  return signer;
}
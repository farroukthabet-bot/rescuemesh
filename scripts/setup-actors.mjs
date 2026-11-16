// Creates one Hedera testnet account per actor (donors, NGOs, volunteers) and stores the keys encrypted.
// Run once:  node --env-file=.env.local scripts/setup-actors.mjs
// Safe to re-run: actors that already have an account are skipped.
import crypto from "node:crypto";
import { AccountCreateTransaction, Client, Hbar, PrivateKey } from "@hashgraph/sdk";
import { createClient } from "@supabase/supabase-js";

const need = (k) => { if (!process.env[k]) throw new Error(`${k} is missing in .env.local`); return process.env[k]; };
const secretHex = need("KEY_ENCRYPTION_SECRET");
if (!/^[0-9a-fA-F]{64}$/.test(secretHex)) throw new Error("KEY_ENCRYPTION_SECRET must be 64 hex characters");
const secret = Buffer.from(secretHex, "hex");

const client = Client.forTestnet().setOperator(need("HEDERA_ACCOUNT_ID"), PrivateKey.fromStringECDSA(need("HEDERA_PRIVATE_KEY")));
const db = createClient(need("SUPABASE_URL"), need("SUPABASE_SERVICE_KEY"), { auth: { persistSession: false } });

// Format: iv:authTag:ciphertext (base64). Must match lib/hedera/keystore.ts.
function encrypt(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", secret, iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString("base64")).join(":");
}

const [{ data: orgs, error: e1 }, { data: vols, error: e2 }, { data: have, error: e3 }] = await Promise.all([
  db.from("organizations").select("id, name"),
  db.from("volunteers").select("id, name"),
  db.from("actor_accounts").select("actor_id"),
]);
if (e1 || e2 || e3) throw new Error((e1 || e2 || e3).message + "  (did you run supabase/phase12.sql?)");

const done = new Set(have.map((h) => h.actor_id));
const actors = [...orgs, ...vols];

for (const a of actors) {
  if (done.has(a.id)) { console.log("skip   ", a.id, "(already has an account)"); continue; }
  const key = PrivateKey.generateECDSA();
  const tx = await new AccountCreateTransaction()
    .setKeyWithoutAlias(key.publicKey)
    .setInitialBalance(new Hbar(3))                  // testnet HBAR, plenty for thousands of messages
    .setAccountMemo(`RescueMesh ${a.id}`)            // IDs only: real business names are not put on a public ledger
    .execute(client);
  const accountId = (await tx.getReceipt(client)).accountId.toString();
  const { error } = await db.from("actor_accounts").insert({
    actor_id: a.id,
    hedera_account_id: accountId,
    public_key: key.publicKey.toStringDer(),
    encrypted_private_key: encrypt(key.toStringDer()),
  });
  if (error) throw new Error(error.message);
  console.log("created ", a.id.padEnd(9), "->", accountId);
}
console.log("\nDone. Now create the restricted topic:  node --env-file=.env.local scripts/create-topic.mjs");
process.exit(0);
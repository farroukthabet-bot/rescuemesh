// Creates the RescueMesh HCS topic.
// If actor accounts exist (scripts/setup-actors.mjs), the topic gets a SUBMIT KEY: only the platform account and
// the registered actors can write to it. Otherwise it is an open topic (anyone can post).
// Run:  node --env-file=.env.local scripts/create-topic.mjs
import { Client, KeyList, PrivateKey, PublicKey, TopicCreateTransaction } from "@hashgraph/sdk";
import { createClient } from "@supabase/supabase-js";

const need = (k) => { if (!process.env[k]) throw new Error(`${k} is missing in .env.local`); return process.env[k]; };
const operatorKey = PrivateKey.fromStringECDSA(need("HEDERA_PRIVATE_KEY"));
const client = Client.forTestnet().setOperator(need("HEDERA_ACCOUNT_ID"), operatorKey);
const db = createClient(need("SUPABASE_URL"), need("SUPABASE_SERVICE_KEY"), { auth: { persistSession: false } });

const { data: actors } = await db.from("actor_accounts").select("actor_id, public_key");

let tx = new TopicCreateTransaction()
  .setTopicMemo("RescueMesh Events")
  .setAdminKey(operatorKey.publicKey); // the platform can update the list of allowed writers later

if (actors && actors.length > 0) {
  const keys = [operatorKey.publicKey, ...actors.map((a) => PublicKey.fromString(a.public_key))];
  tx = tx.setSubmitKey(new KeyList(keys, 1)); // threshold 1: a message is accepted if ANY ONE of these accounts signs it
  console.log(`Submit key: platform + ${actors.length} registered actors (any one of them may post).`);
} else {
  console.warn("WARNING: no actor accounts found, creating an OPEN topic. Run scripts/setup-actors.mjs first.");
}

const receipt = await (await tx.execute(client)).getReceipt(client);
console.log("HEDERA_TOPIC_ID=" + receipt.topicId.toString());
process.exit(0);
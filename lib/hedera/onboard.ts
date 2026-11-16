import { AccountCreateTransaction, Hbar, KeyList, PrivateKey, PublicKey, TopicUpdateTransaction } from "@hashgraph/sdk";
import { supabase } from "@/lib/db/supabase";
import { clientFor } from "./hcs";
import { encryptSecret, getSigner } from "./keystore";

let queue: Promise<unknown> = Promise.resolve();
/** Run onboarding jobs one at a time, so two sign-ups can never overwrite each other's topic key list. */
export function exclusive<T>(job: () => Promise<T>): Promise<T> {
  const run = queue.then(job, job);
  queue = run.catch(() => undefined);
  return run;
}

/** Creates a Hedera account for a new actor (paid by the platform with test HBAR) and stores its key encrypted. */
export async function createActorAccount(actorId: string): Promise<string> {
  const platform = await getSigner("PLATFORM");
  const client = clientFor(platform);
  const key = PrivateKey.generateECDSA();
  const tx = await new AccountCreateTransaction()
    .setKeyWithoutAlias(key.publicKey)
    .setInitialBalance(new Hbar(3))
    .setAccountMemo(`RescueMesh ${actorId}`) // IDs only on the public ledger
    .execute(client);
  const accountId = (await tx.getReceipt(client)).accountId!.toString();

  const { error } = await supabase.from("actor_accounts").insert({
    actor_id: actorId,
    hedera_account_id: accountId,
    public_key: key.publicKey.toStringDer(),
    encrypted_private_key: encryptSecret(key.toStringDer()),
  });
  if (error) throw new Error(error.message);
  return accountId;
}

/** Adds every registered actor to the topic's submit key (threshold 1 of N). Needs the topic's admin key (the platform). */
export async function refreshSubmitKey() {
  const topicId = process.env.HEDERA_TOPIC_ID;
  if (!topicId) throw new Error("HEDERA_TOPIC_ID is not set");
  const platform = await getSigner("PLATFORM");
  const client = clientFor(platform);
  const { data } = await supabase.from("actor_accounts").select("public_key");
  const keys = [platform.key.publicKey, ...(data ?? []).map((a) => PublicKey.fromString(a.public_key as string))];
  const tx = await new TopicUpdateTransaction().setTopicId(topicId).setSubmitKey(new KeyList(keys, 1)).execute(client);
  await tx.getReceipt(client);
}
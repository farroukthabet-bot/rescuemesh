import { Client, TopicMessageSubmitTransaction } from "@hashgraph/sdk";
import { createHash } from "crypto";
import type { Signer } from "./keystore";

const clients = new Map<string, Client>();

// One client per signing account: the transaction is paid and signed by the actor's own account.
export function clientFor(s: Signer): Client {
  let c = clients.get(s.accountId);
  if (!c) {
    c = Client.forTestnet().setOperator(s.accountId, s.key);
    clients.set(s.accountId, c);
  }
  return c;
}

/** Submit one JSON message to the RescueMesh HCS topic, signed and paid by `signer`. */
export async function submitToTopic(payload: Record<string, unknown>, signer: Signer) {
  const topicId = process.env.HEDERA_TOPIC_ID;
  if (!topicId) throw new Error("HEDERA_TOPIC_ID is not set in .env.local");

  const message = JSON.stringify(payload);
  const c = clientFor(signer);

  const tx = await new TopicMessageSubmitTransaction({ topicId, message }).execute(c);
  const record = await tx.getRecord(c); // record includes the consensus timestamp

  return {
    topicId,
    sequenceNumber: record.receipt.topicSequenceNumber!.toString(),
    consensusTimestamp: record.consensusTimestamp.toDate().toISOString(),
    transactionId: tx.transactionId.toString(),
    payloadHash: createHash("sha256").update(message).digest("hex"),
    signerAccountId: signer.accountId,
  };
}
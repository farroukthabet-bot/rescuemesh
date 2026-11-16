# RescueMesh: demo script (about 6 minutes, three screens)

## Before you go on stage (5 minutes)
1. Start Ollama and warm the model: `ollama run llama3.2:3b "hi"` (type /bye afterwards).
2. Create a fresh topic so HashScan only shows this demo: `node --env-file=.env.local scripts/create-topic.mjs`, paste the ID into `HEDERA_TOPIC_ID`, restart `npm run dev`. Do not rehearse on this topic.
3. Sign in as the administrator on the laptop, open **Admin console, Maintenance, Archive demo data**. Then go back to the dashboard.
4. Open the three screens and sign in on each:
   - Laptop: a **donor**, for example `urbain-food@rescuemesh.app`.
   - Phone or tab 2: a **volunteer**, for example `ahmed@rescuemesh.app`.
   - Phone or tab 3: an **NGO**, for example `hope-kitchen@rescuemesh.app`.
   (All demo logins share the password you gave to `seed-demo-accounts.mjs`. Use separate browser profiles if you use tabs, because the session cookie is per browser.)
5. Open HashScan on the topic in another window.

## The story
| Time | Screen | Do | Say |
|---|---|---|---|
| 0:00 | Laptop | Show the dashboard and the map | "Surplus food is not the problem. Coordinating it before it expires, and proving it happened, is." |
| 0:30 | Donor | Create donation | "The donor declares a surplus. It is signed by the donor's own Hedera account." |
| 1:00 | Donor | Find rescue match, then Send offer | "The backend removes everyone who cannot do the job. The AI only chooses among safe options. The match is an offer: nothing is on the ledger yet." |
| 1:40 | Volunteer | The offer appears. Show **Decline** (optional, see below), then **Accept and start** | "A real person decides. When they accept, the coordinator and the volunteer sign." |
| 2:10 | Volunteer | Enter the QR code, Confirm pickup | "A handoff needs two signatures. The volunteer has signed, the donor has not." |
| 2:30 | Donor | Confirm handover | "Now both sides signed. Only then does the food count as picked up." |
| 2:50 | Volunteer | Hand over to the NGO | "Second handoff, same rule." |
| 3:10 | NGO | Enter the code and the quantity, Confirm delivery | "The NGO confirms what it actually received." |
| 3:40 | Laptop | Impact receipt, Verify on Hedera | "Now you do not have to trust our database." |
| 4:15 | Verify page + HashScan | Show 7 verified rows and the different signer accounts | "Each step is signed by its own account. Only registered accounts can write to this topic. AI decides who should act, Hedera proves what actually happened." |

## Show the decline (optional, 30 seconds)
At the offer step, press **Decline** on Ahmed's screen. The donor screen says the offer moved to the next volunteer, whose screen now shows the offer. "If someone declines, the next best volunteer is offered the mission. If nobody fits, the donor can match again."

## Show the administrator (optional, 45 seconds)
Sign in as the administrator. Show **Volunteer applications**: approve one (a new Hedera account is created). Show **Add a donor or an NGO** (click the map) and **Accounts and roles**: one login can hold several roles.

## If something breaks
- **AI slow or Ollama down**: the match still appears and says "Deterministic fallback used". Say it out loud, it proves the backend is the authority.
- **Hedera slow or down**: the app shows "Pending verification" and the administrator can press **Retry pending Hedera events**.
- **Total failure**: open the HashScan tab and your screenshots of the previous run.
- **Clean slate**: Admin console, Maintenance, Archive demo data.

## What to point at
- The map: volunteers drive to the donor, then the NGO, then home. Several missions can run at once.
- The QR label: the receiver (volunteer, NGO) must enter or scan it. A wrong code is refused.
- The track record: built only from deliveries confirmed on Hedera. It survives an archive.
- Tamper test (optional): change one character of `payload_hash` in Supabase and reload the Verify page. That row turns red.
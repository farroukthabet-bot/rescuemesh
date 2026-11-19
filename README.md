# RescueMesh

**Rescue the surplus. Prove the rescue.**

RescueMesh is an AI-assisted food rescue network. It connects shops with surplus food to NGOs and volunteers who can save it before it expires, and it records every critical step on the Hedera network, so anyone can verify what really happened.

Built by team Falous Meyet for the Hedera Cross Campus Challenge 2026 (HCCC 2026), INSAT Campus Edition.

> AI decides who should act. Hedera proves what actually happened.

This is a proof of concept. Read the [Honest limits](#honest-limits) section before you judge it.

## Table of contents

- [About the app](#about-the-app)
- [How a rescue works](#how-a-rescue-works)
- [The AI coordinator](#the-ai-coordinator)
- [The trust layer on Hedera](#the-trust-layer-on-hedera)
- [Tech stack](#tech-stack)
- [Run it on your own PC](#run-it-on-your-own-pc)
- [Demo accounts and scenario](#demo-accounts-and-scenario)
- [Troubleshooting](#troubleshooting)
- [Honest limits](#honest-limits)
- [Learn more](#learn-more)

## About the app

The surplus is not the real problem, coordination is. A donation fails when no NGO is found in time, transport is too slow, the NGO has no capacity or no cold storage, the food expires on the way, nobody knows who accepted, collected or received it, everyone has to trust one central database, and the real impact is hard to verify.

RescueMesh has three kinds of actors, and each one is a different color on the map:

| Actor | Who they are | Color |
|---|---|---|
| Donor | Shops and restaurants with surplus food | Coral |
| NGO | Associations that receive the food | Mint |
| Volunteer | People with a vehicle who carry it | Lavender |

There is also an administrator who adds places on the map and approves volunteers.

- Donors and NGOs never register themselves. They contact the administrator directly, which is a deliberate step of real-world vetting.
- Anyone can apply to be a volunteer, and the administrator approves.
- One login can hold several roles (donor, NGO and volunteer at once).
- A handoff always needs two different people. The system refuses one login signing both sides.

What you see in the app: a dark, map-first dashboard of Centre Urbain Nord (Tunis), a big "Food rescued" counter, a "Signed steps" timeline where you can click a step to see who signed it and open it on HashScan, a track record built only from verified deliveries, an Impact Receipt, a public Verify page, and an admin console.

## How a rescue works

- Step 1, declare. A donor declares a surplus (type, quantity, storage need, time left). It is signed by the donor's own Hedera account.
- Step 2, match. The matching engine finds the safest NGO and volunteer combination, and the donor sends an offer to the volunteer.
- Step 3, accept or decline. The volunteer decides. If they decline, the offer passes to the next best volunteer. If nobody fits, the donor can match again. Nothing is on the ledger until someone accepts, because only confirmed facts belong on a permanent record.
- Step 4, signed match. When the volunteer accepts, the coordinator signs the match with the platform account and the volunteer signs their acceptance with their own account.
- Step 5, first handoff. Donor to volunteer, with two signatures: the donor confirms the handover, and the volunteer confirms the pickup by entering or scanning the package's QR label.
- Step 6, second handoff. Volunteer to NGO, with two signatures: the volunteer confirms the drop-off, and the NGO confirms what it actually received (quantity and QR).
- Step 7, proof. An Impact Receipt is generated, and a public Verify page proves every step.

## The AI coordinator

The AI never makes the decision alone. The rule is: the AI recommends, the backend decides, Hedera records.

- Filter (backend code). Removes every option that cannot work: NGO capacity, cold storage, volunteer vehicle capacity, refrigerated transport, availability, route length, and whether delivery arrives before expiry. Every rejection has a human-readable reason.
- Score (backend code). Ranks what remains: 30% proximity, 25% capacity fit, 25% expiration safety, 20% storage compatibility. Times, risk level and score are computed by code.
- Explain (local LLM). Llama 3.2 3B, running through Ollama, receives only the top 3 valid candidates, picks one and writes the human explanation. It cannot invent data.
- Validate (backend code). The backend checks the AI's choice. If the model is down or answers badly, a deterministic fallback takes over, and the screen says "Deterministic fallback used".

It runs locally, so it is free, private, and needs no API key. The AI never touches the database or Hedera.

## The trust layer on Hedera

RescueMesh uses the Hedera Consensus Service (HCS) on testnet.

- One public topic is the shared timeline of all rescues.
- Every actor has its own Hedera account and signs its own steps.
- The topic has a submit key, so only registered accounts can write to it.
- Each message carries only IDs and essential data. No names, no coordinates, no contact details.
- The Verify page reads each message back from Hedera's public Mirror Node, recomputes its hash, compares it with the stored one, checks the signing account, and shows the network's consensus timestamp. A tampered database row turns red.

Why Hedera: ordered, timestamped, tamper-evident messages with low fixed fees and finality in seconds. An audit trail needs no smart contract. On Hedera's published price, a message costs about $0.0008, and a rescue writes 7 messages, so a rescue costs less than one cent to record.

## Tech stack

- Next.js and TypeScript
- Tailwind CSS
- Supabase (PostgreSQL and Auth)
- Hedera Consensus Service (testnet), with the official JavaScript SDK and the Mirror Node
- Ollama with Llama 3.2 3B
- An SVG map over a restyled Google Maps image of Centre Urbain Nord, with QR codes for handoffs

## Run it on your own PC

These steps work on Windows, macOS and Linux. Where a command differs, both versions are shown. Do each step in order. This takes about 30 to 45 minutes the first time, mostly downloads.

### Step 1: Install the tools

You need four things on your PC.

- Node.js version 20.6 or newer. Download the LTS version from https://nodejs.org and run the installer with the default options. The version matters because the scripts use the `--env-file` flag.
- Git. Download from https://git-scm.com and run the installer with the default options.
- Ollama, for the local AI. Download from https://ollama.com and run the installer.
- A code editor such as Visual Studio Code (optional, but it makes editing the environment file easier).

Check that everything installed. Open a terminal (on Windows, open PowerShell) and run these one at a time:

```
node --version
git --version
ollama --version
```

Each one should print a version number. If one says "command not found" or "not recognized", close the terminal, open a new one, and try again. If it still fails, reinstall that tool.

### Step 2: Get the code

In the terminal, go to the folder where you keep your projects, then clone the repository:

```
git clone [REPOSITORY URL]
cd [PROJECT FOLDER NAME]
```

### Step 3: Install the dependencies

Inside the project folder, run:

```
npm install
```

This downloads everything the app needs. It can take a few minutes and prints a lot of text. Warnings are normal. Errors are not.

### Step 4: Create your Supabase project

Supabase stores the app's data and handles logins.

- Go to https://supabase.com and create a free account.
- Click New project, give it a name, choose a database password and save it somewhere, then choose the region closest to you. Wait until the project finishes setting up.
- Open Project Settings, then API. Keep this page open, you need three values from it in Step 6: the Project URL, the anon public key, and the service role key.
- Create the database tables. Open the SQL Editor in the Supabase sidebar, click New query, paste the contents of [PATH TO SQL SCHEMA FILE] from this repository, and click Run.

The service role key is secret. Never commit it to Git and never share it.

### Step 5: Create your Hedera testnet account

Hedera testnet is a practice network with free test coins. No real money is involved.

- Go to https://portal.hedera.com and create a free account.
- Switch to the Testnet network and create a testnet account. Keep the account ID (it looks like 0.0.12345) and the private key. The key is secret.

### Step 6: Create your environment file

The app reads its settings from a file called `.env.local` in the project root.

Copy the example file. On macOS and Linux:

```
cp .env.example .env.local
```

On Windows PowerShell:

```
copy .env.example .env.local
```

Open `.env.local` in your editor and fill in each value. The exact variable names are in `.env.example`, use those. The values you need are:

| What | Where it comes from |
|---|---|
| Supabase URL | Supabase, Project Settings, API, Project URL |
| Supabase anon key | Supabase, Project Settings, API, anon public key |
| Supabase service role key | Supabase, Project Settings, API, service role key |
| Hedera operator account ID | Step 5 |
| Hedera operator private key | Step 5 |
| Hedera topic ID | Created in Step 8 |
| Key encryption secret | Any long random string you make up |

[CHECK AGAINST .env.example: the exact variable names, and whether there is an Ollama URL or model setting]

### Step 7: Start the local AI

In a terminal, download the model once. It is a download of roughly 2 GB:

```
ollama pull llama3.2:3b
```

Then warm it up so the first match is fast:

```
ollama run llama3.2:3b "hi"
```

Wait for it to answer, then type `/bye` to leave. Ollama keeps running in the background after that. If you skip this step, the app still works, it just says "Deterministic fallback used" instead of using the AI.

### Step 8: Create the Hedera topic

The topic is the shared public timeline. Create it with the project script:

```
node --env-file=.env.local scripts/create-topic.mjs
```

The script prints a topic ID. Copy it into `.env.local` as the Hedera topic ID. Create a new topic whenever you want a clean timeline, for example before a demo.

### Step 9: Create the demo accounts

This adds the demo donors, NGOs and volunteers, each with their own Hedera account:

```
node --env-file=.env.local scripts/seed-demo-accounts.mjs [PASSWORD]
```

[CHECK: how the password is passed to this script, and how the administrator account is created]

All demo logins share the password you choose here.

### Step 10: Start the app

```
npm run dev
```

Open http://localhost:3000 in your browser. You should see the dashboard. Stop the server any time with Ctrl and C in the terminal.

You can also use `yarn dev`, `pnpm dev` or `bun dev` if you prefer another package manager. Use the same manager you installed with.

## Demo accounts and scenario

All demo logins use the email pattern below and the password from Step 9.

| Role | Name | Email |
|---|---|---|
| Donor | Carrefour Market | carrefour-market@rescuemesh.app |
| Donor | Patisserie Takacim | patisserie-takacim@rescuemesh.app |
| Donor | Smile Market | smile-market@rescuemesh.app |
| Donor | Urbain Food | urbain-food@rescuemesh.app |
| NGO | Hope Kitchen | hope-kitchen@rescuemesh.app |
| NGO | Tunis Food Bank | tunis-food-bank@rescuemesh.app |
| NGO | Helping Hands | helping-hands@rescuemesh.app |
| Volunteer | Sami | sami@rescuemesh.app |
| Volunteer | Ahmed | ahmed@rescuemesh.app |
| Volunteer | Leila | leila@rescuemesh.app |
| Volunteer | Youssef | youssef@rescuemesh.app |

The donors are real places used as simulated demo donors. The NGOs are fictional.

Main scenario: Urbain Food declares 50 kg of refrigerated prepared meals expiring in 2 hours. The system rejects the NGO that is too small (Tunis Food Bank, 30 kg, no cold storage), the volunteers without refrigerated transport, and the one who is off duty. It proposes Hope Kitchen and Ahmed, with low risk.

To try it, open three browser profiles (the session cookie is per browser) and sign in as a donor, a volunteer and an NGO.

- Donor: create the donation, click Find rescue match, then Send offer.
- Volunteer: accept the offer, enter the QR code, confirm the pickup.
- Donor: confirm the handover.
- Volunteer: hand over to the NGO.
- NGO: enter the code and the quantity, confirm the delivery.
- Anyone: open the Impact receipt, then the Verify page, then HashScan.

To reset between runs, sign in as the administrator and use Admin console, Maintenance, Archive demo data. The track record survives an archive.

Optional tamper test: change one character of `payload_hash` in Supabase and reload the Verify page. That row turns red.

## Troubleshooting

- The match says "Deterministic fallback used". Ollama is not running or the model is not downloaded. Run `ollama pull llama3.2:3b` and check that Ollama is open. The app still works.
- A step shows "Pending verification". Hedera was slow or unreachable. Sign in as the administrator and press Retry pending Hedera events.
- `node: bad option: --env-file`. Your Node.js is older than 20.6. Install the current LTS version.
- Port 3000 is already in use. Stop the other program, or run `npm run dev -- -p 3001` and open http://localhost:3001.
- Login fails for a demo account. Run Step 9 again and make sure you use the same password you are typing.
- A wrong QR code is refused. This is intended. The receiver has to enter or scan the real label.

## Honest limits

- It runs on Hedera testnet, with no real money, and no real business has joined. The donors are simulated.
- In the demo, the server holds the actors' keys (encrypted) and signs for them. This is custodial. The next step is non-custodial signing in each actor's own wallet. The ledger structure stays the same.
- The QR label is a handoff check, not fraud-proof security. Hedera proves what was recorded and when, not that food physically moved. Next: signed QR tokens, geolocation at scan, photos, temperature sensors.
- Meals are an estimate (0.5 kg per meal), not a measurement.
- Distances are straight lines at a fixed speed for the demo. A real routing service comes later.
- Passwords and sessions are basic. There is no password reset and no 2-factor authentication yet.

## Learn more

About RescueMesh and the technology behind it:

- [Hedera documentation](https://docs.hedera.com)
- [Hedera Consensus Service](https://docs.hedera.com/hedera/sdks-and-apis/sdks/consensus-service)
- [HashScan testnet explorer](https://hashscan.io/testnet)
- [Supabase documentation](https://supabase.com/docs)
- [Ollama](https://ollama.com)

About Next.js, the framework this project is built on (bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app)):

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.
- [The Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome.

To deploy a Next.js app, the easiest way is the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme). See the [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for details. Note that RescueMesh relies on a local Ollama model for its AI step, so a hosted deployment would use the deterministic fallback unless Ollama is reachable.

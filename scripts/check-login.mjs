import { createClient } from "@supabase/supabase-js";

const [emailArg, password] = process.argv.slice(2);
const email = emailArg?.trim().toLowerCase();

if (!email || !password) {
  console.error('Usage: node --env-file=.env.local scripts/check-login.mjs "<email>" "<password>"');
  process.exit(1);
}

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_ANON_KEY || !process.env.SUPABASE_SERVICE_KEY) {
  console.error("SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_KEY are required in .env.local");
  process.exit(1);
}

const auth = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});

const { data, error } = await auth.auth.signInWithPassword({ email, password });
if (error || !data.user) {
  console.error(`Login failed: ${error?.message ?? "Supabase returned no user"}`);
  process.exit(2);
}

const { data: profile, error: profileError } = await db
  .from("profiles")
  .select("user_id, email, display_name")
  .eq("user_id", data.user.id)
  .maybeSingle();

if (profileError) {
  console.error(`Login succeeded, but the RescueMesh profile could not be checked: ${profileError.message}`);
  process.exit(3);
}

if (!profile) {
  console.error("Login succeeded, but this account has no RescueMesh profile");
  process.exit(4);
}

console.log(`Login OK: ${profile.email} (${profile.display_name ?? "unnamed"})`);
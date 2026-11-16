// Creates the first administrator (or adds the admin role to an existing login).
// Run:  node --env-file=.env.local scripts/create-admin.mjs you@example.com "a-strong-password" "Your Name"
import { createClient } from "@supabase/supabase-js";

const [email, password, ...nameParts] = process.argv.slice(2);
if (!email || !password) {
  console.error('Usage: node --env-file=.env.local scripts/create-admin.mjs <email> <password> ["Full name"]');
  process.exit(1);
}
const name = nameParts.join(" ") || "Administrator";
const mail = email.trim().toLowerCase();
const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });

let userId;
const created = await db.auth.admin.createUser({ email: mail, password, email_confirm: true, user_metadata: { name } });
if (created.error) {
  const { data: p } = await db.from("profiles").select("user_id").eq("email", mail).maybeSingle();
  if (!p) throw new Error(created.error.message + "  (did you run supabase/phase14.sql? If this email exists in Supabase Auth, delete it there or use another email)");
  userId = p.user_id;
  console.log("This login already exists: adding the admin role to it.");
} else {
  userId = created.data.user.id;
  const { error } = await db.from("profiles").insert({ user_id: userId, email: mail, display_name: name });
  if (error) throw new Error(error.message + "  (did you run supabase/phase14.sql?)");
}
const { error } = await db.from("memberships").upsert({ user_id: userId, role: "ADMIN", actor_id: null, status: "ACTIVE" }, { onConflict: "user_id,role" });
if (error) throw new Error(error.message);
console.log(`Administrator ready: ${mail}`);
process.exit(0);
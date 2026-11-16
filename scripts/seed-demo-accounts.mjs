// Creates one login for every existing donor, NGO and volunteer, so you can demo on several screens.
// Run:  node --env-file=.env.local scripts/seed-demo-accounts.mjs "a-shared-demo-password"
// Emails look like  carrefour-market@rescuemesh.app, hope-kitchen@rescuemesh.app, ahmed@rescuemesh.app (no email is ever sent).
import { createClient } from "@supabase/supabase-js";

const password = process.argv[2];
if (!password || password.length < 8) {
  console.error('Usage: node --env-file=.env.local scripts/seed-demo-accounts.mjs "<password, 8+ characters>"');
  process.exit(1);
}
const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
const slug = (s) => s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

const [{ data: orgs, error: e1 }, { data: vols, error: e2 }] = await Promise.all([
  db.from("organizations").select("id, name, type"),
  db.from("volunteers").select("id, name"),
]);
if (e1 || e2) throw new Error((e1 || e2).message);

const actors = [...orgs.map((o) => ({ role: o.type, id: o.id, name: o.name })), ...vols.map((v) => ({ role: "VOLUNTEER", id: v.id, name: v.name }))];
console.log("role       actor              email");
for (const a of actors) {
  const email = `${slug(a.name)}@rescuemesh.app`;
  let { data: p } = await db.from("profiles").select("user_id").eq("email", email).maybeSingle();
  if (!p) {
    const c = await db.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { name: a.name } });
    if (c.error) { console.log(`skip ${a.id}: ${c.error.message}`); continue; }
    const { error } = await db.from("profiles").insert({ user_id: c.data.user.id, email, display_name: a.name });
    if (error) throw new Error(error.message + "  (did you run supabase/phase14.sql?)");
    p = { user_id: c.data.user.id };
  } else {
    const { error } = await db.auth.admin.updateUserById(p.user_id, { password });
    if (error) throw new Error(`Could not update ${email}: ${error.message}`);
  }
  const { error } = await db.from("memberships").upsert({ user_id: p.user_id, role: a.role, actor_id: a.id, status: "ACTIVE" }, { onConflict: "user_id,role" });
  if (error) throw new Error(error.message);
  console.log(`${a.role.padEnd(10)} ${a.name.padEnd(18)} ${email}`);
}
console.log("\nAll demo logins share the password you gave. Create the administrator with scripts/create-admin.mjs.");
process.exit(0);
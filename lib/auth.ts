import crypto from "crypto";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { supabase } from "@/lib/db/supabase";

export type Role = "ADMIN" | "DONOR" | "NGO" | "VOLUNTEER";
export type Membership = { id: number; role: Role; actor_id: string | null; status: "PENDING" | "ACTIVE" | "REJECTED" };
export type AuthInfo = { userId: string; email: string; name: string; isAdmin: boolean; memberships: Membership[] };

// Passwords are checked by Supabase Auth. After that we only keep a small signed cookie (HMAC-SHA256, 7 days).
const COOKIE = "rm_session";
const MAX_AGE = 60 * 60 * 24 * 7;

function secret(): Buffer {
  const hex = process.env.SESSION_SECRET ?? "";
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("SESSION_SECRET must be 64 hex characters (see .env.local)");
  return Buffer.from(hex, "hex");
}
const sign = (body: string) => crypto.createHmac("sha256", secret()).update(body).digest("base64url");

function makeToken(userId: string): string {
  const body = Buffer.from(JSON.stringify({ u: userId, e: Math.floor(Date.now() / 1000) + MAX_AGE })).toString("base64url");
  return `${body}.${sign(body)}`;
}

function readToken(token: string | undefined): string | null {
  if (!token) return null;
  const [body, mac] = token.split(".");
  if (!body || !mac) return null;
  const a = Buffer.from(mac), b = Buffer.from(sign(body));
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const p = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    return typeof p.u === "string" && p.e > Date.now() / 1000 ? p.u : null;
  } catch {
    return null;
  }
}

export async function setSession(userId: string) {
  (await cookies()).set(COOKIE, makeToken(userId), {
    httpOnly: true, sameSite: "lax", secure: process.env.NODE_ENV === "production", path: "/", maxAge: MAX_AGE,
  });
}
export async function clearSession() { (await cookies()).delete(COOKIE); }

/** The signed-in person, with their roles, or null. Always read from the database, never from the browser. */
export async function getAuth(): Promise<AuthInfo | null> {
  const uid = readToken((await cookies()).get(COOKIE)?.value);
  if (!uid) return null;
  const [{ data: profile }, { data: ms }] = await Promise.all([
    supabase.from("profiles").select("*").eq("user_id", uid).maybeSingle(),
    supabase.from("memberships").select("*").eq("user_id", uid),
  ]);
  if (!profile) return null;
  const memberships = (ms ?? []) as Membership[];
  return {
    userId: uid, email: profile.email, name: profile.display_name,
    isAdmin: memberships.some((m) => m.role === "ADMIN" && m.status === "ACTIVE"),
    memberships,
  };
}

type Gate = { ok: true; auth: AuthInfo; actorId: string | null } | { ok: false; res: NextResponse };

/** Use at the top of every API route. `role` = the role this action needs. The actor id comes from the account, never from the request. */
export async function authorize(role?: Role): Promise<Gate> {
  const auth = await getAuth();
  if (!auth) return { ok: false, res: NextResponse.json({ error: "Please sign in" }, { status: 401 }) };
  if (!role) return { ok: true, auth, actorId: null };
  const m = auth.memberships.find((x) => x.role === role && x.status === "ACTIVE");
  if (!m) return { ok: false, res: NextResponse.json({ error: `This action needs the ${role.toLowerCase()} role` }, { status: 403 }) };
  return { ok: true, auth, actorId: m.actor_id };
}

/** Returns the user id if the email and password are right, otherwise null. */
export async function checkPassword(email: string, password: string): Promise<string | null> {
  const key = process.env.SUPABASE_ANON_KEY;
  if (!key) throw new Error("SUPABASE_ANON_KEY is missing in .env.local (the publishable key)");
  const anon = createClient(process.env.SUPABASE_URL!, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await anon.auth.signInWithPassword({ email, password });
  return error || !data.user ? null : data.user.id;
}

/** Creates a confirmed login (no email is sent) and its profile. */
export async function createLogin(email: string, password: string, name: string): Promise<{ userId: string } | { error: string }> {
  const mail = email.trim().toLowerCase();
  const { data, error } = await supabase.auth.admin.createUser({ email: mail, password, email_confirm: true, user_metadata: { name } });
  if (error || !data.user) return { error: error?.message ?? "Could not create the account" };
  const { error: pErr } = await supabase.from("profiles").insert({ user_id: data.user.id, email: mail, display_name: name });
  if (pErr) {
    await supabase.auth.admin.deleteUser(data.user.id);
    return { error: pErr.message };
  }
  return { userId: data.user.id };
}
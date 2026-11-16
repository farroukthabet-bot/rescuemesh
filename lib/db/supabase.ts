import { createClient } from "@supabase/supabase-js";

// SERVER-SIDE ONLY. Never import this file from a client component.
export const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_KEY!,
  { auth: { persistSession: false } }
);
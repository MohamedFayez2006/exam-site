// الصق هذا الكود مكان كود الدالة الحالية (Edge Functions → الدالة → Code) ثم Deploy
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const PASSWORD_PREFIX = "ex-";
const EMAIL_DOMAIN = "students.example.com";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).single();
    if (me?.role !== "admin") return json({ error: "forbidden" }, 403);

    const body = await req.json();
    const action = body.action ?? "add";

    if (action === "add") {
      const { students } = body;
      if (!Array.isArray(students) || !students.length || students.length > 200) return json({ error: "invalid_input" }, 400);
      const results = [];
      for (const s of students) {
        const full_name = String(s.full_name ?? "").trim();
        const username = String(s.username ?? "").trim().toLowerCase();
        const seat_number = String(s.seat_number ?? "").trim();
        const grade = String(s.grade ?? "").trim();
        if (!full_name || !seat_number || !/^[a-z0-9._-]{3,30}$/.test(username)) {
          results.push({ username, ok: false, error: "invalid_fields" }); continue;
        }
        const { data: c, error } = await admin.auth.admin.createUser({
          email: `${username}@${EMAIL_DOMAIN}`, password: PASSWORD_PREFIX + seat_number, email_confirm: true,
        });
        if (error || !c.user) { results.push({ username, ok: false, error: error?.message ?? "create_failed" }); continue; }
        const { error: pErr } = await admin.from("profiles").insert({
          id: c.user.id, full_name, username, seat_number, grade, role: "student",
        });
        if (pErr) { await admin.auth.admin.deleteUser(c.user.id); results.push({ username, ok: false, error: pErr.message }); continue; }
        results.push({ username, ok: true });
      }
      return json({ results });
    }

    // update / delete: لازم الهدف يكون طالب
    const id = String(body.id ?? "");
    const { data: t } = await admin.from("profiles").select("role").eq("id", id).single();
    if (t?.role !== "student") return json({ error: "not_a_student" }, 400);

    if (action === "update") {
      const upd: Record<string, unknown> = {};
      if (body.full_name !== undefined) upd.full_name = String(body.full_name).trim();
      if (body.grade !== undefined) upd.grade = String(body.grade).trim();
      if (body.seat_number) upd.seat_number = String(body.seat_number).trim();
      if (body.is_active !== undefined) upd.is_active = !!body.is_active;
      const { error } = await admin.from("profiles").update(upd).eq("id", id);
      if (error) return json({ error: error.message }, 400);
      const authUpd: Record<string, unknown> = {};
      if (upd.seat_number) authUpd.password = PASSWORD_PREFIX + upd.seat_number;
      if (body.is_active !== undefined) authUpd.ban_duration = body.is_active ? "none" : "876000h";
      if (Object.keys(authUpd).length) {
        const { error: e2 } = await admin.auth.admin.updateUserById(id, authUpd);
        if (e2) return json({ error: e2.message }, 400);
      }
      return json({ ok: true });
    }

    if (action === "delete") {
      const { error } = await admin.auth.admin.deleteUser(id);
      if (error) return json({ error: "الطالب له محاولات مسجلة، عطّله بدل الحذف" }, 400);
      return json({ ok: true });
    }
    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

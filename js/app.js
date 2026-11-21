const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const $ = (sel, root = document) => root.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function requireRole(role) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { location.replace("index.html"); return null; }
  const { data: p } = await sb.from("profiles")
    .select("id, full_name, grade, role").eq("id", session.user.id).single();
  if (!p || p.role !== role) { location.replace("index.html"); return null; }
  return p;
}

async function logout() {
  await sb.auth.signOut();
  location.replace("index.html");
}

function idleLogout(minutes = 30) {
  let t;
  const reset = () => { clearTimeout(t); t = setTimeout(logout, minutes * 60000); };
  ["click", "keydown", "mousemove", "touchstart"].forEach((e) =>
    addEventListener(e, reset, { passive: true }));
  reset();
}

function show(el, text, good = false) {
  el.textContent = text;
  el.classList.toggle("good", good);
}

async function fnError(e) {
  try { return (await e.context.json()).error || e.message; }
  catch { return e.message; }
}

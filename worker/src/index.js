// Wallpad router.
//
// Each office Mac mini (the "agent") reports its current local address every minute.
// A QR code under a TV points at /t/<id>#<secret>. That page asks /api/where/<id>
// whether the phone is on the same network as the TV's Mac (same public IP as the
// Mac's last report: the office Wi-Fi shares one), then hands the phone over to the
// remote the Mac serves on the local network. The secret stays in the URL fragment,
// so it never reaches Cloudflare.
//
// Keys: ADMIN_KEY (a secret) mints one-time enrollment codes (POST /api/enroll); a Mac's installer trades
// one for that TV's own key (POST /api/register).
// Reports are signed with the TV's key, whose SHA-256 is all the router stores. Addresses must be private
// (RFC 1918) so a stolen key can't point a TV's QR code at a server on the internet.

const ONLINE_MS = 3 * 60 * 1000;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const ip = req.headers.get("CF-Connecting-IP") || "";

    // admin: a one-time enrollment code for one Mac's install command (1 hour, single use)
    if (req.method === "POST" && url.pathname === "/api/enroll") {
      if (!env.ADMIN_KEY || !(await safeEqual(bearer(req), env.ADMIN_KEY))) return json({ error: "unauthorized" }, 401);
      const code = randomKey();
      await env.TVS.put("enroll:" + (await sha256(code)), "1", { expirationTtl: 3600 });
      return json({ code });
    }

    if (req.method === "POST" && url.pathname === "/api/register") {
      const auth = bearer(req), enrollKey = "enroll:" + (await sha256(auth));
      const ok = (env.ADMIN_KEY && (await safeEqual(auth, env.ADMIN_KEY))) || (auth && (await env.TVS.get(enrollKey)));
      if (!ok) return json({ error: "unauthorized" }, 401);
      await env.TVS.delete(enrollKey);
      const b = await req.json().catch(() => null);
      if (!b || !ID.test(b.id || "")) return json({ error: "bad id" }, 400);
      const key = randomKey();
      const prev = JSON.parse((await env.TVS.get(b.id)) || "{}");
      await env.TVS.put(b.id, JSON.stringify({ ...prev, keyHash: await sha256(key), at: prev.at || 0 }));
      return json({ key });
    }

    if (req.method === "POST" && url.pathname === "/api/report") {
      const b = await req.json().catch(() => null);
      if (!b || !ID.test(b.id || "") || !isPrivateV4(String(b.ip || "")) || !(Number(b.port) >= 1024 && Number(b.port) < 65535))
        return json({ error: "bad report" }, 400);
      const prev = JSON.parse((await env.TVS.get(b.id)) || "null");
      if (!prev?.keyHash || !(await safeEqual(await sha256(bearer(req)), prev.keyHash))) return json({ error: "unauthorized" }, 401);
      const rec = {
        ...prev,
        name: String(b.name || b.id).slice(0, 80),
        ip: String(b.ip), port: Number(b.port),
        // the Mac reports over IPv4 and IPv6 separately; keep the latest public address of each
        pub4: isV6(ip) ? prev.pub4 : ip,
        pub6: isV6(ip) ? ip : prev.pub6,
        at: Date.now(),
      };
      await env.TVS.put(b.id, JSON.stringify(rec));
      return json({ ok: true });
    }

    let m = url.pathname.match(/^\/api\/where\/([a-z0-9-]{4,40})$/);
    if (m) {
      const rec = JSON.parse((await env.TVS.get(m[1])) || "null");
      if (!rec || !rec.ip) return json({ found: false });
      const online = Date.now() - rec.at < ONLINE_MS;
      const same = sameNetwork(ip, rec);   // true / false / null (can't tell)
      return json({
        found: true, name: rec.name, online, same,
        // the local address only goes to phones that look like they're on that network
        url: same === false ? null : `http://${rec.ip}:${rec.port}`,
      });
    }

    m = url.pathname.match(/^\/t\/([a-z0-9-]{4,40})$/);
    if (m) return new Response(routerPage(m[1]), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });

    if (url.pathname === "/") return Response.redirect("https://github.com/Altimor/wallpad", 302);
    return new Response("Not found", { status: 404 });
  },
};

const ID = /^[a-z0-9-]{4,40}$/;

function isV6(ip) { return ip.includes(":"); }

function isPrivateV4(ip) {
  const m = ip.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m || m.slice(1).some((x) => Number(x) > 255)) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

function bearer(req) { return (req.headers.get("Authorization") || "").replace(/^Bearer /, ""); }

function randomKey() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/// Compares two strings without leaking where they differ (hash both, then compare in constant time).
async function safeEqual(a, b) {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0 && a.length > 0;
}

/// IPv4: the office shares one public address. IPv6: every device has its own, so compare the /64 network.
function sameNetwork(ip, rec) {
  if (!ip) return null;
  if (isV6(ip)) {
    if (!rec.pub6) return null;
    return prefix64(ip) === prefix64(rec.pub6);
  }
  if (!rec.pub4) return null;
  return ip === rec.pub4;
}

function prefix64(ip) {
  const [head, tail = ""] = ip.split("::");
  const h = head ? head.split(":") : [], t = tail ? tail.split(":") : [];
  const full = ip.includes("::") ? [...h, ...Array(8 - h.length - t.length).fill("0"), ...t] : h;
  return full.slice(0, 4).map((x) => parseInt(x || "0", 16)).join(":");
}

function json(o, status = 200) {
  return new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

function routerPage(id) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#000">
<title>Wallpad</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100dvh; background: #000; color: #f5f5f7; font: 17px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
         display: grid; place-items: center; padding: 24px; text-align: center; -webkit-font-smoothing: antialiased; }
  main { max-width: 340px; display: grid; gap: 14px; justify-items: center; }
  .icon { width: 72px; height: 72px; border-radius: 20px; background: #1c1c1e; display: grid; place-items: center; }
  h1 { font-size: 22px; font-weight: 600; margin: 6px 0 0; letter-spacing: -0.01em; text-wrap: balance; }
  p { margin: 0; color: #a1a1a6; text-wrap: pretty; }
  button { margin-top: 10px; border: 0; border-radius: 999px; padding: 13px 26px; background: #2c2c2e; color: #f5f5f7; font: 600 16px/1 inherit; }
  .spin { width: 22px; height: 22px; border: 2.5px solid #3a3a3c; border-top-color: #f5f5f7; border-radius: 50%; animation: s 0.8s linear infinite; }
  @keyframes s { to { transform: rotate(360deg); } }
  [hidden] { display: none !important; }
</style></head>
<body><main>
  <div class="icon" id="icon"><div class="spin"></div></div>
  <h1 id="title">Connecting…</h1>
  <p id="body">Finding the TV on this network.</p>
  <button id="retry" hidden onclick="go()">Try again</button>
</main>
<script>
  const id = ${JSON.stringify(id)};
  const token = location.hash.slice(1);
  const $ = (x) => document.getElementById(x);
  const wifi = '<svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#f5f5f7" stroke-width="1.8" stroke-linecap="round"><path d="M2 8.8a15 15 0 0 1 20 0"/><path d="M5.3 12.3a10 10 0 0 1 13.4 0"/><path d="M8.6 15.8a5 5 0 0 1 6.8 0"/><circle cx="12" cy="19.2" r="1.1" fill="#f5f5f7" stroke="none"/></svg>';
  const tv = '<svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#f5f5f7" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8 21h8"/></svg>';
  function show(icon, title, body, retry) {
    $("icon").innerHTML = icon; $("title").textContent = title; $("body").textContent = body; $("retry").hidden = !retry;
  }
  async function go() {
    show('<div class="spin"></div>', "Connecting…", "Finding the TV on this network.", false);
    let r;
    try { r = await (await fetch("/api/where/" + id, { cache: "no-store" })).json(); }
    catch { return show(wifi, "No internet connection", "Connect to the office Wi‑Fi, then try again.", true); }
    if (!r.found) return show(tv, "Unknown TV", "This code isn’t set up yet. Run the setup on the TV’s Mac.", false);
    if (r.same === false) return show(wifi, "Join the office Wi‑Fi", "You’re on a different network than " + r.name + ". Connect to the same Wi‑Fi as the TV, then try again.", true);
    if (!r.online) return show(tv, r.name + " is offline", "Its Mac hasn’t checked in for a few minutes. Make sure it’s on and awake.", true);
    location.replace(r.url + "/#" + token);
  }
  go();
</script>
</body></html>`;
}

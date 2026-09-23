// The web page's testable half (T09, DESIGN §2.2): the pure request-building and response-reading
// logic from web/app.js, the static-serving path through the router, and a drift guard that the
// embedded copy (src/webAssets.ts, build:web) still matches the files under web/. The DOM wiring
// and the real Google sign-in are not here — they need a browser and a real account, hand-verified
// in T10 (DESIGN §5.1).

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, it, expect, beforeEach } from "vitest";
import {
  grantRequest,
  pairCodeRequest,
  pairStatusRequest,
  unpairRequest,
  sessionEstablishRequest,
  signOutRequest,
  describeGrantResult,
  describePairResult,
  describePairStatusResult,
  describeSessionEstablish,
  describeUnpairResult,
  initialSignedIn,
  sessionLost,
  UNPAIR_CONFIRM,
  amountButtonsDisabled,
  AMOUNTS,
} from "../web/app.js";
import { webAssets } from "../src/webAssets.js";
import { route } from "../src/router.js";
import { InMemoryRepo } from "../src/repo.js";
import { hashToken, mintSessionToken } from "../src/auth.js";
import { SESSION_TTL_SECONDS } from "../src/handlers/session.js";
import type { Deps } from "../src/handlers/deps.js";
import { makeEvent, stubVerify, epoch, sessionTokenFromResult, ALLOWLIST, PARENT_EMAIL } from "./helpers.js";

const CLIENT_ID = "test-client-id.apps.googleusercontent.com";

let deps: Deps;
beforeEach(() => {
  deps = { repo: new InMemoryRepo(), verifyGoogle: stubVerify, allowlist: ALLOWLIST, googleClientId: CLIENT_ID };
});

describe("request building (web/app.js) — the wire the page speaks", () => {
  it("the three amounts are exactly 15 / 30 / 60 (DESIGN §2.2)", () => {
    expect(AMOUNTS).toEqual([15, 30, 60]);
  });

  it("grantRequest → POST /grant, Bearer ID token, {minutes} body", () => {
    const { url, options } = grantRequest("id-token-abc", 30);
    expect(url).toBe("/grant"); // relative: same origin as the page
    expect(options.method).toBe("POST");
    expect(options.headers.authorization).toBe("Bearer id-token-abc");
    expect(options.headers["content-type"]).toBe("application/json");
    expect(JSON.parse(options.body)).toEqual({ minutes: 30 });
  });

  it("pairCodeRequest → POST /pair/code, Bearer ID token, no body", () => {
    const { url, options } = pairCodeRequest("id-token-abc");
    expect(url).toBe("/pair/code");
    expect(options.method).toBe("POST");
    expect(options.headers.authorization).toBe("Bearer id-token-abc");
    expect("body" in options).toBe(false); // the parent's identity is the whole request
  });

  it("pairStatusRequest → GET /pair/status, Bearer ID token, no body (T12)", () => {
    const { url, options } = pairStatusRequest("id-token-abc");
    expect(url).toBe("/pair/status");
    expect(options.method).toBe("GET");
    expect(options.headers.authorization).toBe("Bearer id-token-abc");
    expect("body" in options).toBe(false);
  });

  it("in cookie mode (no token) the create requests carry NO Authorization header", () => {
    // The saved-session cookie rides the same-origin fetch instead; a "Bearer undefined" must never
    // be sent (DESIGN §2.2 amendment 2026-09-22).
    expect(grantRequest(undefined, 30).options.headers.authorization).toBeUndefined();
    expect(grantRequest(undefined, 30).options.headers["content-type"]).toBe("application/json");
    expect(pairCodeRequest().options.headers.authorization).toBeUndefined();
    expect(pairStatusRequest().options.headers.authorization).toBeUndefined();
  });

  it("sessionEstablishRequest → POST /session, Bearer ID token, no body", () => {
    const { url, options } = sessionEstablishRequest("id-token-abc");
    expect(url).toBe("/session");
    expect(options.method).toBe("POST");
    expect(options.headers.authorization).toBe("Bearer id-token-abc");
    expect("body" in options).toBe(false);
  });

  it("signOutRequest → DELETE /session", () => {
    const { url, options } = signOutRequest();
    expect(url).toBe("/session");
    expect(options.method).toBe("DELETE");
  });
});

describe("reading the session responses (DESIGN §2.2 amendment) — stay signed in", () => {
  it("the server-rendered state: only the exact string 'true' is signed in", () => {
    expect(initialSignedIn("true")).toBe(true);
    for (const v of ["false", "", undefined, "__SIGNED_IN__", "TRUE"]) expect(initialSignedIn(v)).toBe(false);
  });

  it("a 401 means the saved session is gone; other statuses do not", () => {
    expect(sessionLost(401)).toBe(true);
    for (const status of [200, 201, 400, 403, 500]) expect(sessionLost(status)).toBe(false);
  });

  it("POST /session 200 → ok and 'Signed in.'; anything else → not ok, with the reason", () => {
    expect(describeSessionEstablish(200, { signedIn: true })).toEqual({ ok: true, message: "Signed in." });
    const bad = describeSessionEstablish(403, { error: "not authorized" });
    expect(bad.ok).toBe(false);
    expect(bad.message).toContain("not authorized");
  });
});

describe("reading the response — success and every failure is shown, none grants", () => {
  it("201 → an 'added' line naming the minutes", () => {
    expect(describeGrantResult(201, { minutes: 30 })).toEqual({ ok: true, message: "Added 30 minutes." });
  });

  it("a non-201 (403, 500, …) → not ok, with the server's reason", () => {
    expect(describeGrantResult(403, { error: "not authorized" })).toEqual({
      ok: false,
      message: "Couldn't add minutes: not authorized.",
    });
    expect(describeGrantResult(500, undefined).ok).toBe(false);
  });

  it("200 with a code → the code to display", () => {
    expect(describePairResult(200, { code: "ABCD2345" })).toEqual({ ok: true, code: "ABCD2345" });
  });

  it("a pairing error → not ok, no code", () => {
    const r = describePairResult(401, { error: "missing credential" });
    expect(r.ok).toBe(false);
    expect(r.code).toBeUndefined();
  });
});

describe("the paired-state panel (T12) — read GET /pair/status, decide the note", () => {
  it("200 { paired: true } → ok and paired", () => {
    expect(describePairStatusResult(200, { paired: true })).toEqual({ ok: true, paired: true });
  });

  it("200 { paired: false } → ok and not paired", () => {
    expect(describePairStatusResult(200, { paired: false })).toEqual({ ok: true, paired: false });
  });

  it("a non-200, a missing field, or a non-boolean → not ok (panel is left as it was)", () => {
    expect(describePairStatusResult(401, { error: "missing credential" })).toEqual({ ok: false });
    expect(describePairStatusResult(200, {}).ok).toBe(false);
    expect(describePairStatusResult(200, { paired: "yes" }).ok).toBe(false);
    expect(describePairStatusResult(200, undefined).ok).toBe(false);
  });

});

describe("unpair (DESIGN §2.4 amendment 2026-09-23)", () => {
  it("unpairRequest → POST /pair/unpair, no body; Bearer only when a token is given", () => {
    const { url, options } = unpairRequest();
    expect(url).toBe("/pair/unpair");
    expect(options.method).toBe("POST");
    expect(options.headers.authorization).toBeUndefined();
    expect("body" in options).toBe(false);
    expect(unpairRequest("id-token-abc").options.headers.authorization).toBe("Bearer id-token-abc");
  });

  it("200 { paired: false } → ok; anything else → not ok, with the server's reason", () => {
    expect(describeUnpairResult(200, { paired: false })).toEqual({ ok: true, message: "Unpaired." });
    const bad = describeUnpairResult(403, { error: "not authorized" });
    expect(bad.ok).toBe(false);
    expect(bad.message).toContain("not authorized");
    expect(describeUnpairResult(200, {}).ok).toBe(false);
  });

  it("the confirmation says the Mac stops receiving minutes and re-pairing is at the Mac", () => {
    expect(UNPAIR_CONFIRM).toMatch(/stops receiving minutes/);
    expect(UNPAIR_CONFIRM).toMatch(/Settings/);
  });

  it("a pairing code result carries expiresInSeconds when the server sends it", () => {
    expect(describePairResult(200, { code: "ABCD2345", expiresInSeconds: 600 })).toEqual({
      ok: true,
      code: "ABCD2345",
      expiresInSeconds: 600,
    });
  });
});

describe("the signed-out rule (DESIGN §2.2)", () => {
  it("a signed-out page (no ID token) does not enable the amount buttons", () => {
    expect(amountButtonsDisabled(null)).toBe(true);
    expect(amountButtonsDisabled("")).toBe(true);
    expect(amountButtonsDisabled(undefined)).toBe(true);
  });

  it("once signed in (a token in hand) the amount buttons are enabled", () => {
    expect(amountButtonsDisabled("id-token-abc")).toBe(false);
  });
});

describe("serving the static page same-origin (DESIGN §3.6)", () => {
  it("GET / → 200 HTML with the OAuth client id injected, no placeholder left", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/" }), deps);
    expect(res.statusCode).toBe(200);
    expect(res.headers?.["content-type"]).toMatch(/text\/html/);
    expect(res.body).toContain(CLIENT_ID);
    expect(res.body).not.toContain("__GOOGLE_CLIENT_ID__");
  });

  it("GET /app.js → 200 JavaScript", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/app.js" }), deps);
    expect(res.statusCode).toBe(200);
    expect(res.headers?.["content-type"]).toMatch(/javascript/);
    expect(res.body).toContain("grantRequest");
  });

  it("an unpaired serving deps (no client id) still serves, placeholder emptied", async () => {
    const bare: Deps = { repo: new InMemoryRepo(), verifyGoogle: stubVerify, allowlist: ALLOWLIST };
    const res = await route(makeEvent({ method: "GET", path: "/" }), bare);
    expect(res.statusCode).toBe(200);
    expect(res.body).not.toContain("__GOOGLE_CLIENT_ID__");
  });

  it("a non-asset GET still falls through to 404 (unchanged routing)", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/nope" }), deps);
    expect(res.statusCode).toBe(404);
  });
});

describe("GET / is rendered with the session and paired state already decided (2026-09-23)", () => {
  // Sign in straight into the store and return the cookie value, so each test controls the ttl.
  async function session(ttl = epoch(SESSION_TTL_SECONDS), email = PARENT_EMAIL): Promise<string> {
    const token = mintSessionToken();
    await deps.repo.putSession({ tokenHash: hashToken(token), email, ttl });
    return token;
  }
  // The tag itself, with attributes — not the words "<body>" in the stylesheet's comment.
  const bodyTag = (html: string | undefined) => /<body\s[^>]*>/.exec(html ?? "")?.[0] ?? "";

  it("no cookie → rendered signed out, not paired; no placeholder left; never cached", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/" }), deps);
    expect(bodyTag(res.body)).toBe('<body data-signed-in="false" data-paired="false">');
    expect(res.body).not.toContain("__SIGNED_IN__");
    expect(res.body).not.toContain("__PAIRED__");
    expect(res.headers?.["cache-control"]).toBe("no-store");
  });

  it("a live session, no Mac → signed in, not paired", async () => {
    const token = await session();
    const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), deps);
    expect(bodyTag(res.body)).toBe('<body data-signed-in="true" data-paired="false">');
  });

  it("a live session with a Mac paired → signed in and paired, so Connect never shows", async () => {
    const token = await session();
    await deps.repo.putDeviceToken({ tokenHash: "h", issuedAt: "2026-09-23T08:00:00Z" });
    const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), deps);
    expect(bodyTag(res.body)).toBe('<body data-signed-in="true" data-paired="true">');
  });

  it("signed out never reveals the paired state", async () => {
    await deps.repo.putDeviceToken({ tokenHash: "h", issuedAt: "2026-09-23T08:00:00Z" });
    const res = await route(makeEvent({ method: "GET", path: "/" }), deps);
    expect(bodyTag(res.body)).toBe('<body data-signed-in="false" data-paired="false">');
  });

  it("an expired session, or one whose email left the allowlist → rendered signed out", async () => {
    const expired = await session(epoch(-1));
    const removed = await session(epoch(SESSION_TTL_SECONDS), "former@example.com");
    for (const token of [expired, removed]) {
      const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), deps);
      expect(bodyTag(res.body)).toContain('data-signed-in="false"');
    }
  });

  it("the page still serves, signed out, when the session store fails", async () => {
    const token = await session();
    const broken: Deps = {
      ...deps,
      repo: Object.assign(Object.create(deps.repo), {
        getSession: async () => {
          throw new Error("table down");
        },
      }),
    };
    const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), broken);
    expect(res.statusCode).toBe(200);
    expect(bodyTag(res.body)).toContain('data-signed-in="false"');
  });

  it("rolling expiry: a load more than a day after the last extension pushes it 30 days out", async () => {
    const token = await session(epoch(SESSION_TTL_SECONDS - 3 * 24 * 60 * 60)); // extended 3 days ago
    const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), deps);
    // The browser gets the same token with a fresh 30-day Max-Age…
    expect(sessionTokenFromResult(res)).toBe(token);
    expect((res.cookies ?? [])[0]).toContain(`Max-Age=${SESSION_TTL_SECONDS}`);
    // …and the server row is extended to match.
    const row = await deps.repo.getSession(hashToken(token));
    expect(row?.ttl).toBeGreaterThanOrEqual(epoch(SESSION_TTL_SECONDS) - 5);
  });

  it("rolling expiry is written at most once a day: a fresh session is left alone", async () => {
    const token = await session(); // extended just now
    const res = await route(makeEvent({ method: "GET", path: "/", sessionCookie: token }), deps);
    expect(res.cookies).toBeUndefined();
  });

  it("the markup's amount buttons match AMOUNTS, so the page and the script cannot disagree", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/" }), deps);
    const minutes = [...(res.body ?? "").matchAll(/data-minutes="(\d+)"/g)].map((m) => Number(m[1]));
    expect(minutes).toEqual(AMOUNTS);
  });

  it("Google's library is not in the markup — the script loads it only when signing in", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/" }), deps);
    expect(res.body).not.toContain("accounts.google.com/gsi/client");
  });
});

describe("drift guard — the embedded page matches the source files (build:web)", () => {
  const web = (name: string) => readFileSync(fileURLToPath(new URL(`../web/${name}`, import.meta.url)), "utf8");

  it("src/webAssets.ts is regenerated whenever web/ changes", () => {
    expect(webAssets["/"]?.body).toBe(web("index.html"));
    expect(webAssets["/app.js"]?.body).toBe(web("app.js"));
  });
});

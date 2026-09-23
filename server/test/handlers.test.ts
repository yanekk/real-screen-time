// The endpoint suite (DESIGN §3.6, §2.3), driven through the router against an in-memory Repo and
// a stubbed Google verifier — no AWS, no network (DESIGN §4). It covers the whole T08 test list:
// the create side locked to the parent, the read-only device-token side, and the pairing
// lifecycle with its single-use, expiry and re-pair-revokes rules.

import { describe, it, expect, beforeEach } from "vitest";
import { route } from "../src/router.js";
import { InMemoryRepo } from "../src/repo.js";
import { mintDeviceToken, mintSessionToken, hashToken } from "../src/auth.js";
import type { Deps } from "../src/handlers/deps.js";
import {
  makeEvent,
  bodyOf,
  epoch,
  stubVerify,
  sessionTokenFromResult,
  ALLOWLIST,
  PARENT_TOKEN,
  PARENT_EMAIL,
  STRANGER_TOKEN,
  UNVERIFIED_TOKEN,
} from "./helpers.js";

let repo: InMemoryRepo;
let deps: Deps;

beforeEach(() => {
  repo = new InMemoryRepo();
  deps = { repo, verifyGoogle: stubVerify, allowlist: ALLOWLIST };
});

// Pair a Mac the way a real one does — put a code, redeem it through the endpoint — and return
// the device token. Proves the redeem path while giving the GET/consume tests a valid token.
async function pairDevice(code = "PAIRCODE"): Promise<string> {
  await repo.putPairingCode({ code, ttl: epoch(600) });
  const res = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code } }), deps);
  expect(res.statusCode).toBe(200);
  return bodyOf(res).token as string;
}

describe("POST /grant — create side, parent-only (DESIGN §2.3)", () => {
  it("with a valid parent ID token → 201 and one grant is queued", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(201);
    expect(bodyOf(res)).toMatchObject({ minutes: 30 });
    const grants = await repo.listGrants();
    expect(grants).toHaveLength(1);
    expect(grants[0]?.minutes).toBe(30);
  });

  it("stamps issuedAt as ISO-8601 with no fractional seconds (the wire contract, T03)", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 15 } }),
      deps,
    );
    expect(bodyOf(res).issuedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });

  it("with a non-parent (allowlist miss) → 403 and nothing queued", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: STRANGER_TOKEN, body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(403);
    expect(await repo.listGrants()).toEqual([]);
  });

  it("with an unverified email → 403 and nothing queued", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: UNVERIFIED_TOKEN, body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(403);
    expect(await repo.listGrants()).toEqual([]);
  });

  it("with an expired / malformed / wrong-audience ID token → 401", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: "not-a-real-token", body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(401);
    expect(await repo.listGrants()).toEqual([]);
  });

  it("with no credential → 401", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/grant", body: { minutes: 30 } }), deps);
    expect(res.statusCode).toBe(401);
  });

  it("presented with a DEVICE token → 403 (device tokens cannot create)", async () => {
    const token = await pairDevice();
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token, body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(403);
    expect(await repo.listGrants()).toEqual([]);
  });

  it("even a random device-shaped token → 403, never reaching Google verify", async () => {
    const res = await route(
      makeEvent({ method: "POST", path: "/grant", token: mintDeviceToken(), body: { minutes: 30 } }),
      deps,
    );
    expect(res.statusCode).toBe(403);
  });

  it("with missing or non-positive minutes → 400", async () => {
    for (const minutes of [undefined, 0, -5, 2.5, "30"]) {
      const body = minutes === undefined ? {} : { minutes };
      const res = await route(
        makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body }),
        deps,
      );
      expect(res.statusCode).toBe(400);
    }
    expect(await repo.listGrants()).toEqual([]);
  });

  it("two calls queue two grants — the server does not merge (DESIGN §2.1)", async () => {
    await route(makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 15 } }), deps);
    await route(makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 60 } }), deps);
    const grants = await repo.listGrants();
    expect(grants).toHaveLength(2);
    expect(grants.map((g) => g.minutes).sort((a, b) => a - b)).toEqual([15, 60]);
    // Distinct ids, so the Mac dedupes correctly.
    expect(new Set(grants.map((g) => g.id)).size).toBe(2);
  });
});

describe("GET /grants — read side, device token (DESIGN §3.6)", () => {
  it("with a valid device token → the unconsumed grants as a bare array", async () => {
    const token = await pairDevice();
    await route(makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 30 } }), deps);

    const res = await route(makeEvent({ method: "GET", path: "/grants", token }), deps);
    expect(res.statusCode).toBe(200);
    const arr = bodyOf(res);
    expect(Array.isArray(arr)).toBe(true);
    expect(arr).toHaveLength(1);
    // Exactly the wire shape: id, minutes, issuedAt — and no internal ttl leaks out.
    expect(Object.keys(arr[0]).sort()).toEqual(["id", "issuedAt", "minutes"]);
  });

  it("with an unknown token → 401", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/grants", token: mintDeviceToken() }), deps);
    expect(res.statusCode).toBe(401);
  });

  it("with no token → 401", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/grants" }), deps);
    expect(res.statusCode).toBe(401);
  });

  it("omits items past their ttl (staleness/day-boundary is the Mac's job)", async () => {
    const token = await pairDevice();
    // A grant already past its ttl, inserted straight into the store.
    await repo.putGrant({ id: "stale", minutes: 30, issuedAt: "2026-09-22T10:00:00Z", ttl: epoch(-1) });
    const res = await route(makeEvent({ method: "GET", path: "/grants", token }), deps);
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res)).toEqual([]);
  });
});

describe("POST /grants/{id}/consume — device token (DESIGN §3.6, §2.7)", () => {
  it("removes the grant; a second consume is an idempotent no-op", async () => {
    const token = await pairDevice();
    const created = bodyOf(
      await route(makeEvent({ method: "POST", path: "/grant", token: PARENT_TOKEN, body: { minutes: 30 } }), deps),
    );
    const id: string = created.id;

    const first = await route(makeEvent({ method: "POST", path: `/grants/${id}/consume`, token }), deps);
    expect(first.statusCode).toBe(200);
    expect(await repo.listGrants()).toEqual([]);

    // Re-served or retried consume must not error (at-least-once delivery, DESIGN §2.7).
    const second = await route(makeEvent({ method: "POST", path: `/grants/${id}/consume`, token }), deps);
    expect(second.statusCode).toBe(200);
  });

  it("percent-encoded ids in the path are decoded before delete", async () => {
    const token = await pairDevice();
    await repo.putGrant({ id: "a b/c", minutes: 30, issuedAt: "2026-09-22T10:00:00Z", ttl: epoch(600) });
    const res = await route(
      makeEvent({ method: "POST", path: `/grants/${encodeURIComponent("a b/c")}/consume`, token }),
      deps,
    );
    expect(res.statusCode).toBe(200);
    expect(await repo.listGrants()).toEqual([]);
  });

  it("with an unknown token → 401 and the grant survives", async () => {
    await pairDevice();
    await repo.putGrant({ id: "keep", minutes: 30, issuedAt: "2026-09-22T10:00:00Z", ttl: epoch(600) });
    const res = await route(
      makeEvent({ method: "POST", path: "/grants/keep/consume", token: mintDeviceToken() }),
      deps,
    );
    expect(res.statusCode).toBe(401);
    expect(await repo.listGrants()).toHaveLength(1);
  });
});

describe("POST /pair/code — parent-only, mints an expiring single-use code (DESIGN §2.4)", () => {
  it("with a valid parent token → a code that is then redeemable", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/code", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
    const { code, expiresInSeconds } = bodyOf(res);
    expect(code).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    expect(expiresInSeconds).toBeGreaterThan(0);

    // The code the parent was shown redeems into a device token.
    const redeem = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code } }), deps);
    expect(redeem.statusCode).toBe(200);
    expect(bodyOf(redeem).token).toMatch(/^[0-9a-f]{64}$/);
  });

  it("with a non-parent token → 403 and no code minted", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/code", token: STRANGER_TOKEN }), deps);
    expect(res.statusCode).toBe(403);
  });

  it("with a device token → 403 (a device token cannot mint a code)", async () => {
    const token = await pairDevice();
    const res = await route(makeEvent({ method: "POST", path: "/pair/code", token }), deps);
    expect(res.statusCode).toBe(403);
  });

  it("with no credential → 401", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/code" }), deps);
    expect(res.statusCode).toBe(401);
  });
});

describe("POST /pair/redeem — the code is the credential (DESIGN §2.4)", () => {
  it("a fresh code → a device token; the same code again → refused (single-use)", async () => {
    await repo.putPairingCode({ code: "FRESH234", ttl: epoch(600) });

    const first = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code: "FRESH234" } }), deps);
    expect(first.statusCode).toBe(200);
    expect(bodyOf(first).token).toMatch(/^[0-9a-f]{64}$/);

    const second = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code: "FRESH234" } }), deps);
    expect(second.statusCode).toBe(400);
  });

  it("an expired code → refused", async () => {
    await repo.putPairingCode({ code: "EXPIRED2", ttl: epoch(-1) });
    const res = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code: "EXPIRED2" } }), deps);
    expect(res.statusCode).toBe(400);
  });

  it("an unknown code → refused", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code: "NOSUCH23" } }), deps);
    expect(res.statusCode).toBe(400);
  });

  it("a typed code is normalized (case and separators) before lookup", async () => {
    await repo.putPairingCode({ code: "ABCD2345", ttl: epoch(600) });
    const res = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: { code: "abcd-2345" } }), deps);
    expect(res.statusCode).toBe(200);
  });

  it("with a missing code → 400", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/redeem", body: {} }), deps);
    expect(res.statusCode).toBe(400);
  });

  it("re-pairing replaces the active token: the first Mac's token then 401s (DESIGN §2.4)", async () => {
    const first = await pairDevice("CODEONE2");
    // Prove the first token works before the re-pair.
    expect((await route(makeEvent({ method: "GET", path: "/grants", token: first }), deps)).statusCode).toBe(200);

    const second = await pairDevice("CODETWO2");
    expect(second).not.toBe(first);

    // The old token no longer validates — this is how re-pairing revokes the previous Mac.
    expect((await route(makeEvent({ method: "GET", path: "/grants", token: first }), deps)).statusCode).toBe(401);
    expect((await route(makeEvent({ method: "GET", path: "/grants", token: second }), deps)).statusCode).toBe(200);
  });
});

describe("GET /pair/status — parent-only, reports only whether a Mac is paired (DESIGN §2.3, T12)", () => {
  it("with a valid parent token and no Mac paired → 200 { paired: false }", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/pair/status", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res)).toEqual({ paired: false });
  });

  it("with a valid parent token and a Mac paired → 200 { paired: true }, and no token leaks", async () => {
    await pairDevice();
    const res = await route(makeEvent({ method: "GET", path: "/pair/status", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
    const body = bodyOf(res);
    expect(body).toEqual({ paired: true }); // exactly {paired}: no token, no hash, no issuedAt
  });

  it("presented with a DEVICE token → 403 (the read side cannot reach the create-side gate)", async () => {
    const token = await pairDevice();
    const res = await route(makeEvent({ method: "GET", path: "/pair/status", token }), deps);
    expect(res.statusCode).toBe(403);
  });

  it("with a non-parent (allowlist miss) → 403", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/pair/status", token: STRANGER_TOKEN }), deps);
    expect(res.statusCode).toBe(403);
  });

  it("with no credential → 401", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/pair/status" }), deps);
    expect(res.statusCode).toBe(401);
  });

  it("is a GET the static page never swallows — /pair/status is not an asset path", async () => {
    // With serving deps that carry a client id, GET / still serves the page; GET /pair/status must
    // reach the handler, not fall into serveStatic (router orders it ahead of the static match).
    const servingDeps: Deps = { ...deps, googleClientId: "cid" };
    const res = await route(makeEvent({ method: "GET", path: "/pair/status", token: PARENT_TOKEN }), servingDeps);
    expect(res.statusCode).toBe(200);
    expect(res.headers?.["content-type"]).toMatch(/json/);
  });
});

describe("POST /pair/unpair — parent-only, revokes the paired Mac (DESIGN §2.4 amendment 2026-09-23)", () => {
  it("with a parent token → 200 { paired: false }; the Mac's token then 401s and status reads unpaired", async () => {
    const device = await pairDevice();
    const res = await route(makeEvent({ method: "POST", path: "/pair/unpair", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res)).toEqual({ paired: false });
    // The Mac's next poll is refused, which is what makes its Settings show "re-pair".
    expect((await route(makeEvent({ method: "GET", path: "/grants", token: device }), deps)).statusCode).toBe(401);
    const status = await route(makeEvent({ method: "GET", path: "/pair/status", token: PARENT_TOKEN }), deps);
    expect(bodyOf(status)).toEqual({ paired: false });
  });

  it("then a fresh code pairs again", async () => {
    await pairDevice("FIRST234");
    await route(makeEvent({ method: "POST", path: "/pair/unpair", token: PARENT_TOKEN }), deps);
    const again = await pairDevice("SECOND23");
    expect((await route(makeEvent({ method: "GET", path: "/grants", token: again }), deps)).statusCode).toBe(200);
  });

  it("with nothing paired → still 200 (idempotent)", async () => {
    const res = await route(makeEvent({ method: "POST", path: "/pair/unpair", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
  });

  it("works with only the saved-session cookie", async () => {
    await pairDevice();
    const signIn = await route(makeEvent({ method: "POST", path: "/session", token: PARENT_TOKEN }), deps);
    const cookie = sessionTokenFromResult(signIn);
    const res = await route(makeEvent({ method: "POST", path: "/pair/unpair", sessionCookie: cookie }), deps);
    expect(res.statusCode).toBe(200);
    expect(await repo.hasAnyDeviceToken()).toBe(false);
  });

  it("with the Mac's own device token → 403, and the Mac stays paired", async () => {
    const device = await pairDevice();
    const res = await route(makeEvent({ method: "POST", path: "/pair/unpair", token: device }), deps);
    expect(res.statusCode).toBe(403);
    expect(await repo.hasAnyDeviceToken()).toBe(true);
  });

  it("with a non-parent → 403; with no credential → 401; the Mac stays paired", async () => {
    await pairDevice();
    expect((await route(makeEvent({ method: "POST", path: "/pair/unpair", token: STRANGER_TOKEN }), deps)).statusCode).toBe(403);
    expect((await route(makeEvent({ method: "POST", path: "/pair/unpair" }), deps)).statusCode).toBe(401);
    expect(await repo.hasAnyDeviceToken()).toBe(true);
  });
});

describe("the saved session — stay signed in (DESIGN §2.2 amendment 2026-09-22)", () => {
  // Sign in the way the web page does — POST /session with a parent Google token — and return the
  // session cookie value the browser would then carry on every later request.
  async function signIn(): Promise<string> {
    const res = await route(makeEvent({ method: "POST", path: "/session", token: PARENT_TOKEN }), deps);
    expect(res.statusCode).toBe(200);
    expect(bodyOf(res)).toEqual({ signedIn: true, email: PARENT_EMAIL });
    const token = sessionTokenFromResult(res);
    expect(token).toMatch(/^[0-9a-f]{64}$/);
    return token;
  }

  describe("POST /session — mint a session, same create-side gate as /grant", () => {
    it("with a valid parent token → 200, a hardened Set-Cookie, and the parent's email", async () => {
      const res = await route(makeEvent({ method: "POST", path: "/session", token: PARENT_TOKEN }), deps);
      expect(res.statusCode).toBe(200);
      const cookie = (res.cookies ?? [])[0] ?? "";
      expect(cookie).toContain("rst_session=");
      expect(cookie).toContain("HttpOnly");
      expect(cookie).toContain("Secure");
      expect(cookie).toContain("SameSite=Lax");
      expect(cookie).toMatch(/Max-Age=\d+/);
    });

    it("with a non-parent → 403 and no session cookie", async () => {
      const res = await route(makeEvent({ method: "POST", path: "/session", token: STRANGER_TOKEN }), deps);
      expect(res.statusCode).toBe(403);
      expect(sessionTokenFromResult(res)).toBe("");
    });

    it("with a device token → 403 (a read-only credential cannot become a session)", async () => {
      const token = await pairDevice();
      const res = await route(makeEvent({ method: "POST", path: "/session", token }), deps);
      expect(res.statusCode).toBe(403);
    });

    it("with no credential → 401", async () => {
      const res = await route(makeEvent({ method: "POST", path: "/session" }), deps);
      expect(res.statusCode).toBe(401);
    });
  });

  describe("GET /session — the cookie is the credential", () => {
    it("with a live session cookie → 200 { signedIn: true }", async () => {
      const token = await signIn();
      const res = await route(makeEvent({ method: "GET", path: "/session", sessionCookie: token }), deps);
      expect(res.statusCode).toBe(200);
      expect(bodyOf(res)).toEqual({ signedIn: true, email: PARENT_EMAIL });
    });

    it("with no cookie → 401 { signedIn: false }", async () => {
      const res = await route(makeEvent({ method: "GET", path: "/session" }), deps);
      expect(res.statusCode).toBe(401);
      expect(bodyOf(res)).toEqual({ signedIn: false });
    });

    it("with an unknown cookie → 401", async () => {
      const res = await route(makeEvent({ method: "GET", path: "/session", sessionCookie: mintSessionToken() }), deps);
      expect(res.statusCode).toBe(401);
    });

    it("with a session whose email was taken off the allowlist → 401", async () => {
      const token = mintSessionToken();
      await repo.putSession({ tokenHash: hashToken(token), email: "former@example.com", ttl: epoch(600) });
      const res = await route(makeEvent({ method: "GET", path: "/session", sessionCookie: token }), deps);
      expect(res.statusCode).toBe(401);
      const grant = await route(
        makeEvent({ method: "POST", path: "/grant", sessionCookie: token, body: { minutes: 15 } }),
        deps,
      );
      expect(grant.statusCode).toBe(401);
    });

    it("with an expired session → 401 (fails closed on the ttl filter)", async () => {
      const token = mintSessionToken();
      await repo.putSession({ tokenHash: hashToken(token), email: PARENT_EMAIL, ttl: epoch(-1) });
      const res = await route(makeEvent({ method: "GET", path: "/session", sessionCookie: token }), deps);
      expect(res.statusCode).toBe(401);
    });
  });

  describe("DELETE /session — sign out", () => {
    it("clears the cookie and the session then stops validating", async () => {
      const token = await signIn();
      const out = await route(makeEvent({ method: "DELETE", path: "/session", sessionCookie: token }), deps);
      expect(out.statusCode).toBe(200);
      expect(bodyOf(out)).toEqual({ signedIn: false });
      // The Set-Cookie clears the value (Max-Age=0), and the server-side row is gone.
      expect(sessionTokenFromResult(out)).toBe("");
      const after = await route(makeEvent({ method: "GET", path: "/session", sessionCookie: token }), deps);
      expect(after.statusCode).toBe(401);
    });

    it("with no cookie → still 200 (idempotent)", async () => {
      const res = await route(makeEvent({ method: "DELETE", path: "/session" }), deps);
      expect(res.statusCode).toBe(200);
    });
  });

  describe("the create side accepts the session cookie in place of a Google token", () => {
    it("POST /grant with only a session cookie → 201 and the grant is queued", async () => {
      const token = await signIn();
      const res = await route(
        makeEvent({ method: "POST", path: "/grant", sessionCookie: token, body: { minutes: 30 } }),
        deps,
      );
      expect(res.statusCode).toBe(201);
      expect(await repo.listGrants()).toHaveLength(1);
    });

    it("POST /pair/code and GET /pair/status work with only a session cookie", async () => {
      const token = await signIn();
      const code = await route(makeEvent({ method: "POST", path: "/pair/code", sessionCookie: token }), deps);
      expect(code.statusCode).toBe(200);
      const status = await route(makeEvent({ method: "GET", path: "/pair/status", sessionCookie: token }), deps);
      expect(status.statusCode).toBe(200);
      expect(bodyOf(status)).toEqual({ paired: false });
    });

    it("an expired session cookie does NOT authorize a grant → 401, nothing queued", async () => {
      const token = mintSessionToken();
      await repo.putSession({ tokenHash: hashToken(token), email: PARENT_EMAIL, ttl: epoch(-1) });
      const res = await route(
        makeEvent({ method: "POST", path: "/grant", sessionCookie: token, body: { minutes: 30 } }),
        deps,
      );
      expect(res.statusCode).toBe(401);
      expect(await repo.listGrants()).toEqual([]);
    });

    it("a device-shaped token in the Authorization header is still refused even with a session cookie present", async () => {
      // The Bearer is checked first; a device-shaped Bearer is 403 regardless of any cookie.
      const token = await signIn();
      const res = await route(
        makeEvent({ method: "POST", path: "/grant", token: mintDeviceToken(), sessionCookie: token, body: { minutes: 30 } }),
        deps,
      );
      expect(res.statusCode).toBe(403);
    });
  });
});

describe("routing", () => {
  it("an unknown path → 404", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/nope" }), deps);
    expect(res.statusCode).toBe(404);
  });

  it("a wrong method on a known path → 404", async () => {
    const res = await route(makeEvent({ method: "GET", path: "/grant" }), deps);
    expect(res.statusCode).toBe(404);
  });

  it("tolerates a trailing slash", async () => {
    const token = await pairDevice();
    const res = await route(makeEvent({ method: "GET", path: "/grants/", token }), deps);
    expect(res.statusCode).toBe(200);
  });
});

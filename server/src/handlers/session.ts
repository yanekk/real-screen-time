// POST /session, GET /session, DELETE /session — the saved parent web session (DESIGN §2.2
// amendment 2026-09-22). This is what makes "stay signed in" work: the page trades a fresh Google
// sign-in for a long-lived cookie, so a refresh comes up signed in with no Google prompt.
//
//   POST   /session  parent-only (Google ID token in the Bearer, the same gate as /grant): mint a
//                    session token, store its hash + the parent's email, and return it in a
//                    hardened Set-Cookie. This is the ONE place a Google sign-in becomes a session.
//   GET    /session  the cookie is the credential: report whether it names a live session, so the
//                    page can render signed-in on load without touching Google.
//   DELETE /session  sign out: delete the session row and clear the cookie.
//
// The create side (grant, pair/code, pair/status) accepts this cookie too — see requireParent —
// so once signed in the page needs no Google token to grant.

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import {
  json,
  jsonWithCookies,
  sessionCookie,
  setSessionCookie,
  clearSessionCookie,
} from "../http.js";
import { mintSessionToken, hashToken } from "../auth.js";
import type { Deps } from "./deps.js";
import { requireParent, resolveSession } from "./parent.js";
import type { PageView } from "./static.js";

// How long a saved session lives without use: 30 days, rolling (DESIGN §2.2 amendment
// 2026-09-23) — every page load pushes it 30 days out, so a parent who opens the page at least
// once a month never sees a sign-in again, and an abandoned browser still forgets. DynamoDB
// self-expires the row on the same `ttl`, and `getSession` also filters on it, so an expired
// cookie fails closed.
export const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;

// The rolling refresh is written at most once a day per session: a page load within a day of the
// last refresh changes nothing, so reloads do not each cost a table write and a Set-Cookie.
const SESSION_REFRESH_AFTER_SECONDS = 24 * 60 * 60;

export async function createSession(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  // Same create-side gate as /grant: a real, verified, allowlisted parent (a Google Bearer, or an
  // existing session cookie being refreshed). A device token or a stranger never reaches here.
  const auth = await requireParent(event, deps);
  if (!auth.ok) return auth.response;

  const token = mintSessionToken();
  const ttl = Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS;
  await deps.repo.putSession({
    tokenHash: hashToken(token),
    email: auth.identity.email,
    ttl,
  });
  // The raw token is returned once, only in the cookie — it is never recoverable from the store.
  return jsonWithCookies(
    200,
    { signedIn: true, email: auth.identity.email },
    [setSessionCookie(token, SESSION_TTL_SECONDS)],
  );
}

/**
 * The page serve's view of the session (router, `GET /`): whether to render the page signed in,
 * and — for the rolling expiry — a refreshed Set-Cookie when the session was last extended more
 * than a day ago. The server decides signed-in-ness here, before the page exists, so the page
 * arrives in its final state: no sign-in button flashes for a signed-in parent and no second
 * round-trip asks "am I signed in?" (DESIGN §2.2 amendment 2026-09-23).
 */
export async function sessionForPage(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<PageView & { cookies: string[] }> {
  // The page must always serve: a table read failing renders signed out (the Google button is the
  // way back in), never a 500 in place of the page.
  let session;
  try {
    session = await resolveSession(event, deps);
  } catch (e) {
    console.error("session lookup failed while serving the page", e);
    return { signedIn: false, paired: "false", cookies: [] };
  }
  if (!session) return { signedIn: false, paired: "false", cookies: [] };

  // Rendered into the page too, so a paired parent never sees "Connect a Mac" flash. Unreadable →
  // "unknown", which shows Connect and has the page ask /pair/status itself.
  let paired: PageView["paired"];
  try {
    paired = (await deps.repo.hasAnyDeviceToken()) ? "true" : "false";
  } catch (e) {
    console.error("paired-state lookup failed while serving the page", e);
    paired = "unknown";
  }

  const now = Math.floor(Date.now() / 1000);
  const extendedAt = session.ttl - SESSION_TTL_SECONDS;
  if (now - extendedAt < SESSION_REFRESH_AFTER_SECONDS) return { signedIn: true, paired, cookies: [] };

  try {
    await deps.repo.putSession({ ...session, ttl: now + SESSION_TTL_SECONDS });
  } catch (e) {
    // Not extending this once is harmless — the session is still valid; the next load retries.
    console.error("rolling session refresh failed", e);
    return { signedIn: true, paired, cookies: [] };
  }
  // Re-issue the same token with a fresh Max-Age; the browser's copy would otherwise still lapse
  // 30 days after sign-in even though the server row was extended.
  return {
    signedIn: true,
    paired,
    cookies: [setSessionCookie(sessionCookie(event), SESSION_TTL_SECONDS)],
  };
}

export async function readSession(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  const session = await resolveSession(event, deps);
  if (!session) return json(401, { signedIn: false });
  return json(200, { signedIn: true, email: session.email });
}

export async function endSession(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  // Delete the row so the token stops validating everywhere, and clear the cookie in the browser.
  // Both are best-effort and idempotent: signing out twice, or with no cookie, still returns 200.
  const token = sessionCookie(event);
  if (token) await deps.repo.deleteSession(hashToken(token));
  return jsonWithCookies(200, { signedIn: false }, [clearSessionCookie()]);
}

// Method + path routing for the five endpoints (DESIGN §3.6). Kept separate from the Lambda
// entry (handler.ts) so the whole routing surface is unit-tested against an in-memory Repo and a
// stubbed Google verifier, with no AWS and no network (DESIGN §4). handler.ts only builds the
// real Deps from the environment and calls this.

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { methodOf, pathOf, json } from "./http.js";
import type { Deps } from "./handlers/deps.js";
import { createGrant } from "./handlers/grant.js";
import { listGrants, consumeGrant } from "./handlers/grants.js";
import { createPairingCode, redeemPairingCode, pairStatus, unpair } from "./handlers/pair.js";
import { createSession, readSession, endSession, sessionForPage } from "./handlers/session.js";
import { serveStatic } from "./handlers/static.js";

// `/grants/{id}/consume` with the id captured. The Mac percent-encodes the id into the path
// (RemoteClient.consumeGrant), so the captured segment is decoded before use.
const CONSUME_RE = /^\/grants\/([^/]+)\/consume$/;

export async function route(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  const method = methodOf(event);
  // Tolerate one trailing slash so `/grants/` routes like `/grants`; never collapse to empty.
  const path = pathOf(event).replace(/\/+$/, "") || "/";

  try {
    // The one API GET (T12), matched ahead of the static page so it can never be swallowed by
    // serveStatic. It is parent-authed and returns only whether a Mac is paired (DESIGN §2.3).
    if (method === "GET" && path === "/pair/status") return await pairStatus(event, deps);

    // The saved-session read (DESIGN §2.2 amendment 2026-09-22), matched ahead of the static page
    // so the page can ask "am I still signed in?" on load. The cookie is the credential.
    if (method === "GET" && path === "/session") return await readSession(event, deps);

    // The static page (T09), served same-origin ahead of the API routes. Only GET, and only the
    // page's own paths match inside serveStatic; anything else falls through (DESIGN §3.6).
    // GET / is rendered with the session already decided (sessionForPage), so a signed-in parent
    // never sees the sign-in state; only the page itself pays the session lookup, not /app.js.
    if (method === "GET" && path === "/") {
      const view = await sessionForPage(event, deps);
      const page = serveStatic(path, deps.googleClientId ?? "", view);
      if (page) return view.cookies.length > 0 ? { ...page, cookies: view.cookies } : page;
    }
    if (method === "GET") {
      const asset = serveStatic(path, deps.googleClientId ?? "");
      if (asset) return asset;
    }

    if (method === "POST" && path === "/session") return await createSession(event, deps);
    if (method === "DELETE" && path === "/session") return await endSession(event, deps);
    if (method === "POST" && path === "/grant") return await createGrant(event, deps);
    if (method === "GET" && path === "/grants") return await listGrants(event, deps);
    if (method === "POST" && path === "/pair/code") return await createPairingCode(event, deps);
    if (method === "POST" && path === "/pair/redeem") return await redeemPairingCode(event, deps);
    if (method === "POST" && path === "/pair/unpair") return await unpair(event, deps);

    const consume = CONSUME_RE.exec(path);
    if (method === "POST" && consume) {
      return await consumeGrant(event, deps, decodeURIComponent(consume[1] ?? ""));
    }

    return json(404, { error: "not found", method, path });
  } catch (e) {
    // A handler is not expected to throw — they return typed responses — but if one does, fail
    // closed with a 500 rather than letting the Lambda surface a stack trace. The Mac reads any
    // 5xx as "do nothing, cover stays up" (DESIGN §2.7).
    console.error("unhandled error routing request", e);
    return json(500, { error: "server error" });
  }
}

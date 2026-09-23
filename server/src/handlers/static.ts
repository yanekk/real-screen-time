// GET / and GET /app.js — the static page, served by the same Lambda that owns the API so the
// whole thing is one origin with no CORS (DESIGN §3.6, FINDINGS 2026-09-22). handler.ts calls the
// page out to T09; this is it. The bytes live in the generated webAssets module (build:web),
// embedded because the SAM esbuild build ships only bundled code, no loose files.
//
// The one thing done at serve time rather than build time is the OAuth client id: index.html
// carries a `__GOOGLE_CLIENT_ID__` placeholder, and the Lambda fills it from its own
// GOOGLE_CLIENT_ID (Deps.googleClientId). So the page the parent loads and the backend that
// verifies the token she gets back always name the same audience, with nothing to configure in the
// page itself — T10 sets one deploy parameter and both sides follow it.

import type { APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { webAssets } from "../webAssets.js";

const CLIENT_ID_PLACEHOLDER = "__GOOGLE_CLIENT_ID__";
// index.html carries `<body data-signed-in="__SIGNED_IN__" data-paired="__PAIRED__">`; the router
// fills them from the request's session and the table, and the page's stylesheet derives what is
// visible from them, so the first paint is already the final state (DESIGN §2.2 amendment
// 2026-09-23).
const SIGNED_IN_PLACEHOLDER = "__SIGNED_IN__";
const PAIRED_PLACEHOLDER = "__PAIRED__";

/** What the page is rendered as. `paired` is "unknown" when the table could not be read. */
export interface PageView {
  signedIn: boolean;
  paired: "true" | "false" | "unknown";
}

const SIGNED_OUT: PageView = { signedIn: false, paired: "false" };

/**
 * The static response for `path`, or `undefined` if `path` is not a served asset (the router then
 * falls through to the API routes / 404). Only the page's own paths — "/" and "/app.js" — match.
 */
export function serveStatic(
  path: string,
  googleClientId: string,
  view: PageView = SIGNED_OUT,
): APIGatewayProxyStructuredResultV2 | undefined {
  const asset = webAssets[path];
  if (!asset) return undefined;

  // Fill the placeholders only where they exist (index.html); app.js has none, so this is a no-op
  // there. `split/join` replaces every occurrence without regex-escaping the id.
  const body = asset.body
    .split(CLIENT_ID_PLACEHOLDER)
    .join(googleClientId)
    .split(SIGNED_IN_PLACEHOLDER)
    .join(view.signedIn ? "true" : "false")
    .split(PAIRED_PLACEHOLDER)
    .join(view.signedIn ? view.paired : "false");

  const personalised = asset.body.includes(SIGNED_IN_PLACEHOLDER);
  return {
    statusCode: 200,
    // The page now differs per visitor (signed in or not), so no browser or proxy may cache it.
    headers: personalised
      ? { "content-type": asset.contentType, "cache-control": "no-store" }
      : { "content-type": asset.contentType },
    body,
  };
}

// POST /pair/code, POST /pair/redeem, GET /pair/status — the pairing lifecycle (DESIGN §2.4, §3.6).
//
//   /pair/code   parent-only (Google ID token): mint a short-lived, single-use code and show it.
//   /pair/redeem the code IS the credential (no auth header): exchange it for a device token,
//                REPLACING the single active token, so any prior Mac's token stops validating
//                (re-pair revokes, DESIGN §2.4).
//   /pair/status parent-only: report only WHETHER a Mac is currently paired, so the web app can
//                show "A Mac is paired" (T12). Existence, never the token — stays inside the
//                create-side gate and leaks nothing (DESIGN §2.3).
//   /pair/unpair parent-only: delete the active device token (the web app's Unpair, DESIGN §2.4
//                amendment 2026-09-23). The paired Mac's token stops validating at once, and the
//                Mac shows "re-pair" in Settings on its next poll.

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { json, parseJsonBody, isoNoFraction } from "../http.js";
import {
  mintPairingCode,
  normalizePairingCode,
  mintDeviceToken,
  hashToken,
} from "../auth.js";
import type { Deps } from "./deps.js";
import { requireParent } from "./parent.js";

// How long a pairing code lives. Long enough to read it off the web page and type it into the
// Mac's Settings; short enough that a code seen over a shoulder is worthless before long
// (DESIGN §2.4). It is single-use regardless, so this only bounds an unredeemed code.
const PAIR_CODE_TTL_SECONDS = 600;

export async function createPairingCode(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  const auth = await requireParent(event, deps);
  if (!auth.ok) return auth.response;

  const code = mintPairingCode();
  const ttl = Math.floor(Date.now() / 1000) + PAIR_CODE_TTL_SECONDS;
  await deps.repo.putPairingCode({ code, ttl });
  return json(200, { code, expiresInSeconds: PAIR_CODE_TTL_SECONDS });
}

export async function redeemPairingCode(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseJsonBody(event) as { code?: unknown } | undefined;
  const raw = body?.code;
  if (typeof raw !== "string" || raw.length === 0) {
    return json(400, { error: "missing code" });
  }

  // Single-use and atomic: the Repo removes the code and reports whether it was there and unexpired
  // (repo.ts). A used, expired, or unknown code all come back false → 400.
  const ok = await deps.repo.takePairingCode(normalizePairingCode(raw));
  if (!ok) return json(400, { error: "unknown, used, or expired code" });

  const token = mintDeviceToken();
  // Store only the hash, and overwrite the singleton — this is what makes re-pairing revoke the
  // previous Mac (DESIGN §2.4): its token's hash no longer matches, so it 401s on the next poll.
  await deps.repo.putDeviceToken({
    tokenHash: hashToken(token),
    issuedAt: isoNoFraction(new Date()),
  });
  // Return the token itself once, here; it is never recoverable from the store again.
  return json(200, { token });
}

export async function pairStatus(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  // Same create-side gate as POST /pair/code: a device token is refused (it carries no create
  // scope), a foreign email is refused, only the parent gets an answer. What it returns is only
  // whether a token exists — no token, no hash — so the gate leaks nothing (DESIGN §2.3, T12).
  const auth = await requireParent(event, deps);
  if (!auth.ok) return auth.response;

  const paired = await deps.repo.hasAnyDeviceToken();
  return json(200, { paired });
}

export async function unpair(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  // Same create-side gate as /pair/code: only the parent can cut a Mac off. Idempotent — unpairing
  // with nothing paired is still 200, so a double tap or a stale page never shows an error.
  const auth = await requireParent(event, deps);
  if (!auth.ok) return auth.response;

  await deps.repo.deleteDeviceToken();
  return json(200, { paired: false });
}

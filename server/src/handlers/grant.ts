// POST /grant — the create side (DESIGN §3.6). Parent-only: a Google ID token on the allowlist,
// never a device token. Body {minutes}; creates exactly one grant and returns it.

import crypto from "node:crypto";
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { json, parseJsonBody, isoNoFraction } from "../http.js";
import type { Deps } from "./deps.js";
import { requireParent } from "./parent.js";

// The DynamoDB self-expiry on a grant. It is only garbage collection: the Mac re-judges
// staleness against its own TTL (default 15 min, DESIGN §2.6, §3.5) and is authoritative, so
// this only bounds how long an unconsumed grant lingers in the table. Matched to the Mac's
// default so the server never drops a grant the Mac would still have honoured.
const GRANT_TTL_SECONDS = 900;

export async function createGrant(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  const auth = await requireParent(event, deps);
  if (!auth.ok) return auth.response;

  const body = parseJsonBody(event) as { minutes?: unknown } | undefined;
  const minutes = body?.minutes;
  if (typeof minutes !== "number" || !Number.isInteger(minutes) || minutes <= 0) {
    return json(400, { error: "minutes must be a positive integer" });
  }

  const now = new Date();
  const grant = {
    id: crypto.randomUUID(),
    minutes,
    issuedAt: isoNoFraction(now),
    ttl: Math.floor(now.getTime() / 1000) + GRANT_TTL_SECONDS,
  };
  await deps.repo.putGrant(grant);

  // 201 with the created grant. The web page (T09) does not need the body, but returning it keeps
  // the create call self-describing and mirrors what `GET /grants` will hand the Mac.
  return json(201, { id: grant.id, minutes: grant.minutes, issuedAt: grant.issuedAt });
}

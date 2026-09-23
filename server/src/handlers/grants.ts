// GET /grants and POST /grants/{id}/consume — the receive side (DESIGN §3.6). Both are gated by
// the read-only device token: fetch the unconsumed grants, or consume one. Neither can create.

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { json, bearerToken } from "../http.js";
import { hashToken } from "../auth.js";
import type { Deps } from "./deps.js";

/**
 * The device-token gate: hash the presented Bearer and check it against the single active token
 * (DESIGN §2.4). A missing, unknown, or superseded token — including the previous Mac's after a
 * re-pair — fails, and the caller answers 401 (DESIGN §2.7).
 */
async function deviceAuthorized(event: APIGatewayProxyEventV2, deps: Deps): Promise<boolean> {
  const token = bearerToken(event);
  if (!token) return false;
  return deps.repo.hasDeviceToken(hashToken(token));
}

export async function listGrants(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!(await deviceAuthorized(event, deps))) {
    return json(401, { error: "unknown device token" });
  }
  // The Repo already drops items past their TTL (repo.ts); the day-boundary and staleness
  // judgement is the Mac's alone (DESIGN §2.6, §3.6). The wire contract (T03) is a BARE array of
  // {id, minutes, issuedAt} — the internal `ttl` is not sent.
  const grants = await deps.repo.listGrants();
  return json(
    200,
    grants.map((g) => ({ id: g.id, minutes: g.minutes, issuedAt: g.issuedAt })),
  );
}

export async function consumeGrant(
  event: APIGatewayProxyEventV2,
  deps: Deps,
  id: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!(await deviceAuthorized(event, deps))) {
    return json(401, { error: "unknown device token" });
  }
  // Idempotent by design: deleting an already-consumed or unknown grant is a no-op success.
  // Delivery is at-least-once and the Mac dedupes (DESIGN §2.6, §2.7), so a second consume — a
  // retry, or a re-served grant — must not error.
  await deps.repo.deleteGrant(id);
  return json(200, { ok: true });
}

// The create-side gate, shared by the endpoints only the parent may reach — `POST /grant`,
// `POST /pair/code` and the read-only `GET /pair/status` (DESIGN §2.3, §3.6). It is the whole
// security model in one function: a device token is refused by shape (403, it carries no create
// scope), a Google ID token is verified (401 if bad), and the verified email must be on the
// allowlist (403 otherwise).

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { json, bearerToken, sessionCookie } from "../http.js";
import { isAuthorized, looksLikeDeviceToken, hashToken, type GoogleIdentity } from "../auth.js";
import type { Session } from "../repo.js";
import type { Deps } from "./deps.js";

/** Either the verified parent identity, or the exact error response to return. */
export type ParentAuth =
  | { ok: true; identity: GoogleIdentity }
  | { ok: false; response: APIGatewayProxyStructuredResultV2 };

/**
 * The saved session named by the request's `rst_session` cookie, if it exists, is unexpired, and
 * still belongs to an allowlisted email; else undefined. Shared by `requireParent` (cookie as an
 * alternative to a Google token), the page serve (rendered signed-in or not) and sign-out. The
 * presented cookie is hashed before the store lookup — the table holds only hashes (DESIGN §2.2
 * amendment 2026-09-22). The allowlist is re-checked on every use, so removing an email from
 * `AUTHORIZED_EMAILS` ends that parent's saved sessions at the next deploy, not 30 days later.
 */
export async function resolveSession(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<Session | undefined> {
  const token = sessionCookie(event);
  if (!token) return undefined;
  const session = await deps.repo.getSession(hashToken(token));
  if (!session || !isAuthorized(session.email, deps.allowlist)) return undefined;
  return session;
}

export async function requireParent(
  event: APIGatewayProxyEventV2,
  deps: Deps,
): Promise<ParentAuth> {
  const token = bearerToken(event);
  if (!token) {
    // No Google token in hand — this is the "stay signed in" path. A valid saved-session cookie
    // names the parent without another Google round-trip (DESIGN §2.2 amendment 2026-09-22). The
    // session was only ever minted after a verified, allowlisted Google sign-in, and resolveSession
    // re-checks the allowlist, so trusting its stored email here does not widen who can create.
    const session = await resolveSession(event, deps);
    if (session) return { ok: true, identity: { email: session.email, emailVerified: true } };
    return { ok: false, response: json(401, { error: "missing credential" }) };
  }

  // A device token can never create (DESIGN §2.3). It is opaque 64-hex; a Google ID token is a
  // JWT, so the shape tells them apart and the read-only credential is turned away 403 without
  // ever being sent to Google.
  if (looksLikeDeviceToken(token)) {
    return { ok: false, response: json(403, { error: "device tokens cannot create" }) };
  }

  let identity: GoogleIdentity;
  try {
    identity = await deps.verifyGoogle(token);
  } catch {
    // Expired, malformed, or wrong-audience token — authentication failed.
    return { ok: false, response: json(401, { error: "invalid Google token" }) };
  }

  if (!identity.emailVerified) {
    return { ok: false, response: json(403, { error: "email not verified" }) };
  }
  if (!isAuthorized(identity.email, deps.allowlist)) {
    // Authenticated as someone, but not the parent — the allowlist is the authorization.
    return { ok: false, response: json(403, { error: "not authorized" }) };
  }
  return { ok: true, identity };
}

// Shared test helpers: build the HTTP API v2 event shape the handlers read, and a stubbed
// Google verifier so no test touches the network (DESIGN §4).

import type { APIGatewayProxyEventV2 } from "aws-lambda";
import type { GoogleVerifier, GoogleIdentity } from "../src/auth.js";

/** Seconds-from-epoch, `n` seconds from now — for building fresh or already-expired ttl values. */
export function epoch(offsetSeconds = 0): number {
  return Math.floor(Date.now() / 1000) + offsetSeconds;
}

export interface EventOpts {
  method: string;
  path: string;
  /** Sent as `Authorization: Bearer <token>`. */
  token?: string;
  /** The session cookie value, delivered the way HTTP API v2 delivers cookies (`event.cookies`). */
  sessionCookie?: string;
  /** JSON-encoded into the body. */
  body?: unknown;
}

export function makeEvent(opts: EventOpts): APIGatewayProxyEventV2 {
  const headers: Record<string, string> = {};
  if (opts.token !== undefined) headers["authorization"] = `Bearer ${opts.token}`;
  const cookies = opts.sessionCookie !== undefined ? [`rst_session=${opts.sessionCookie}`] : undefined;
  return {
    version: "2.0",
    routeKey: "$default",
    rawPath: opts.path,
    rawQueryString: "",
    headers,
    cookies,
    requestContext: {
      http: { method: opts.method, path: opts.path, protocol: "HTTP/1.1", sourceIp: "127.0.0.1", userAgent: "test" },
    } as APIGatewayProxyEventV2["requestContext"],
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    isBase64Encoded: false,
  } as APIGatewayProxyEventV2;
}

/** The `rst_session` token from a handler's `Set-Cookie` list, or "" if none/cleared. */
export function sessionTokenFromResult(result: { cookies?: string[] }): string {
  const set = (result.cookies ?? []).find((c) => c.startsWith("rst_session="));
  if (!set) return "";
  const value = set.slice("rst_session=".length).split(";")[0] ?? "";
  return value; // "" for a cleared cookie (Max-Age=0), the token otherwise
}

// Fixed identities the stub returns for known tokens. The parent is on the allowlist the tests
// build; the stranger authenticates fine but is not authorized. Any other token string throws,
// standing in for an expired / malformed / wrong-audience token.
export const PARENT_TOKEN = "google-id-token.parent";
export const STRANGER_TOKEN = "google-id-token.stranger";
export const UNVERIFIED_TOKEN = "google-id-token.unverified";

export const PARENT_EMAIL = "parent@example.com";
export const STRANGER_EMAIL = "stranger@example.com";
export const ALLOWLIST = [PARENT_EMAIL];

export const stubVerify: GoogleVerifier = async (idToken: string): Promise<GoogleIdentity> => {
  switch (idToken) {
    case PARENT_TOKEN:
      return { email: PARENT_EMAIL, emailVerified: true };
    case STRANGER_TOKEN:
      return { email: STRANGER_EMAIL, emailVerified: true };
    case UNVERIFIED_TOKEN:
      return { email: PARENT_EMAIL, emailVerified: false };
    default:
      throw new Error("invalid Google token");
  }
};

/** Parse a handler's JSON body. Handlers always return the structured (object) result form. */
export function bodyOf(result: { body?: string }): any {
  return JSON.parse(result.body ?? "{}");
}

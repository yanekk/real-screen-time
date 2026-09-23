// Small request/response helpers shared by the handlers, kept in one place so the wire contract
// (T03, pinned in RemoteClient.swift) is honoured identically everywhere: Bearer auth, ISO-8601
// dates with no fractional seconds, JSON bodies.

import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyStructuredResultV2,
} from "aws-lambda";

/** A JSON response with the given status. */
export function json(statusCode: number, body: unknown): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

/**
 * A JSON response that also sets one or more cookies. HTTP API v2 (payload format 2.0) turns each
 * string in `cookies` into its own `Set-Cookie` header, so this is how the saved-session endpoints
 * hand the browser its session cookie (DESIGN §2.2 amendment 2026-09-22).
 */
export function jsonWithCookies(
  statusCode: number,
  body: unknown,
  cookies: string[],
): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    cookies,
    body: JSON.stringify(body),
  };
}

// The saved-session cookie. Its value is an opaque token (never a Google token); the server only
// ever stores its hash (repo.ts), so a leaked cookie store is useless. Attributes, always together:
//   HttpOnly     — scripts cannot read it, so an XSS on the page cannot steal the session
//   Secure       — sent only over HTTPS (the API is HTTPS-only)
//   SameSite=Lax — the standard for a session cookie. It rides a top-level GET navigation, so
//                  opening the page from a link (mail, chat) still arrives signed in; it is never
//                  sent on a cross-site POST/DELETE, and every state change here is one of those,
//                  so that is the CSRF defence. (Strict dropped it on link-opened loads, which
//                  rendered a signed-in parent as signed out — 2026-09-23.)
//   Path=/       — one cookie for the whole origin (page + API share it)
export const SESSION_COOKIE = "rst_session";

/**
 * Read the session token from the request's `rst_session` cookie, or "" when absent. HTTP API v2
 * delivers cookies as an array of `name=value` strings (`event.cookies`); a raw `Cookie` header is
 * read too, defensively. Every caller reads "" as "no saved session".
 */
export function sessionCookie(event: APIGatewayProxyEventV2): string {
  const prefix = `${SESSION_COOKIE}=`;
  const fromArray = (event.cookies ?? []).find((c) => c.startsWith(prefix));
  if (fromArray) return fromArray.slice(prefix.length);
  const header = event.headers?.["cookie"] ?? event.headers?.["Cookie"] ?? "";
  const m = new RegExp(`(?:^|;\\s*)${SESSION_COOKIE}=([^;]+)`).exec(header);
  return m?.[1] ?? "";
}

/** The `Set-Cookie` value that saves the session for `maxAgeSeconds`. */
export function setSessionCookie(token: string, maxAgeSeconds: number): string {
  return `${SESSION_COOKIE}=${token}; Max-Age=${maxAgeSeconds}; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

/** The `Set-Cookie` value that clears the session immediately (sign-out). */
export function clearSessionCookie(): string {
  return `${SESSION_COOKIE}=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

export function methodOf(event: APIGatewayProxyEventV2): string {
  return event.requestContext?.http?.method ?? "";
}

export function pathOf(event: APIGatewayProxyEventV2): string {
  return event.rawPath || "/";
}

/**
 * Extract the token from `Authorization: Bearer <token>` — the header the wire contract (T03)
 * uses on `GET /grants` and consume, and that the web page (T09) will use to carry the Google ID
 * token on `POST /grant` and `POST /pair/code`. Returns "" when the header is absent or malformed;
 * every caller reads "" as unauthenticated. API Gateway lowercases header names, but the lookup is
 * defensive about casing.
 */
export function bearerToken(event: APIGatewayProxyEventV2): string {
  const headers = event.headers ?? {};
  const raw = headers["authorization"] ?? headers["Authorization"] ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return m?.[1]?.trim() ?? "";
}

/**
 * Parse a JSON request body, or `undefined` when it is absent or unparseable — the caller decides
 * which is an error. Handles API Gateway's base64 encoding of bodies.
 */
export function parseJsonBody(event: APIGatewayProxyEventV2): unknown {
  if (!event.body) return undefined;
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body, "base64").toString("utf8")
      : event.body;
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

/**
 * ISO-8601 with a `Z` zone and NO fractional seconds (`2026-09-22T14:03:00Z`). The Mac decodes
 * dates with `JSONDecoder.iso8601`, which rejects milliseconds (T03 wire contract), so every
 * date the backend emits must be trimmed of the `.123` that `Date.toISOString()` includes.
 */
export function isoNoFraction(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

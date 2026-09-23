// The auth primitives the endpoints (T08) stand on, split so the unit suite never needs a
// network or the Google library. Two things live here:
//
//   - The email allowlist logic (DESIGN §2.2: authentication proves who you are, the allowlist
//     is the authorization). Ported verbatim from the T00 spike, which proved it cleanly refuses
//     a second, non-parent Google account (FINDINGS 2026-09-22).
//   - Device-token and pairing-code minting, hashing and shape-checking.
//
// Everything here is pure (node:crypto and strings only), so it carries no third-party import
// and the handler tests exercise it directly. The one part that DOES need google-auth-library —
// verifying a real ID token — is isolated in ./google.ts and injected, so tests mock it (DESIGN
// §4) and the library is only ever loaded on the real Lambda.

import crypto from "node:crypto";

/** The identity a verified Google ID token yields — the only fields the allowlist check needs. */
export interface GoogleIdentity {
  email: string;
  emailVerified: boolean;
}

/**
 * Verify a Google ID token and return its identity, or throw if it is invalid, expired, or has
 * the wrong audience. The real implementation is in ./google.ts; the handlers take it as a
 * dependency so tests pass a stub and the backend suite touches no network (DESIGN §4).
 */
export type GoogleVerifier = (idToken: string) => Promise<GoogleIdentity>;

// MARK: - The allowlist (the authorization, DESIGN §2.2)

export function normalizeEmail(email: string | undefined): string {
  return String(email ?? "").trim().toLowerCase();
}

/** Parse `AUTHORIZED_EMAILS` (comma-separated) into a normalized allowlist. */
export function parseAllowlist(csv: string | undefined): string[] {
  return String(csv ?? "")
    .split(",")
    .map(normalizeEmail)
    .filter(Boolean);
}

export function isAuthorized(email: string | undefined, allowlist: string[]): boolean {
  const n = normalizeEmail(email);
  return n.length > 0 && allowlist.includes(n);
}

// MARK: - Device tokens

/**
 * A fresh device token: 32 random bytes as 64 hex chars — the shape the T00 spike pinned. It is
 * handed to the Mac once, at redemption, and never stored server-side in the clear (see
 * `hashToken`).
 */
export function mintDeviceToken(): string {
  return crypto.randomBytes(32).toString("hex");
}

/**
 * The SHA-256 of a token, hex. The table stores only this, never the token itself (repo.ts): a
 * leaked store is then useless to fetch grants with. The presented Bearer is hashed and compared
 * against the stored hash.
 */
export function hashToken(token: string): string {
  return crypto.createHash("sha256").update(token).digest("hex");
}

/**
 * A fresh saved-session token: 32 random bytes as 64 hex chars, the same strength as a device
 * token. It lives only in the parent's `rst_session` cookie and is stored server-side as a hash
 * (see `hashToken`), never in the clear. It never travels in an Authorization header, so it cannot
 * collide with the device-token shape check on the create side (DESIGN §2.2 amendment 2026-09-22).
 */
export function mintSessionToken(): string {
  return crypto.randomBytes(32).toString("hex");
}

const DEVICE_TOKEN_RE = /^[0-9a-f]{64}$/;

/**
 * True when a Bearer token has the *shape* of a device token (64 lowercase hex chars). This is
 * how `POST /grant` refuses a device token (DESIGN §2.3) without sending it to Google: a Google
 * ID token is a JWT with dots and never matches, so the shape alone tells the read-only
 * credential apart from a create credential. It intentionally does not consult the store — a
 * device-shaped token is turned away whether or not it is the live one, because it can never
 * carry create scope.
 */
export function looksLikeDeviceToken(token: string): boolean {
  return DEVICE_TOKEN_RE.test(token);
}

// MARK: - Pairing codes

// An alphabet with no visually ambiguous characters (no I, L, O, 0, 1), so a code read off the
// web page and typed into the Mac's Settings cannot be misread. Eight chars over 31 symbols is
// ~10^12 combinations — far more than a short-lived, single-use code needs.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;

/** A fresh pairing code in canonical form (uppercase, alphabet-only). */
export function mintPairingCode(): string {
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
  }
  return out;
}

/**
 * Fold a typed code to the canonical form codes are minted and stored in: uppercase, with any
 * separator or stray whitespace dropped. The parent reads a code off the web page and types it
 * into Settings, so redeem is forgiving of case and of a grouping dash it may show — a minted
 * code is already canonical, so this only ever rescues a mistype, never changes a valid code.
 */
export function normalizePairingCode(code: string | undefined): string {
  return String(code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

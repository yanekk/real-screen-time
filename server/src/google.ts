// The one place google-auth-library is loaded. Isolated from ./auth.ts so the pure allowlist and
// token logic — and every handler test — stay free of the library and of any network: the tests
// inject a stub `GoogleVerifier` (DESIGN §4), and this real one only ever runs on the Lambda.
//
// The T00 spike proved this exact call verifies a real Google Identity Services ID token and that
// checking the returned `email` against the allowlist refuses a non-parent account (FINDINGS
// 2026-09-22), so T08 keeps the hand-rolled verify rather than reaching for Cognito.

import { OAuth2Client } from "google-auth-library";
import type { GoogleIdentity, GoogleVerifier } from "./auth.js";

/**
 * Build the real Google ID-token verifier bound to this deployment's OAuth client id. It throws
 * on an invalid, expired, or wrong-audience token; the handlers catch that and answer 401.
 */
export function makeGoogleVerifier(clientId: string): GoogleVerifier {
  const client = new OAuth2Client(clientId);
  return async (idToken: string): Promise<GoogleIdentity> => {
    // `audience` pins the token to our client id, so a token minted for another app is rejected.
    const ticket = await client.verifyIdToken({ idToken, audience: clientId });
    const payload = ticket.getPayload();
    if (!payload) throw new Error("verified token had no payload");
    return {
      email: payload.email ?? "",
      emailVerified: payload.email_verified ?? false,
    };
  };
}

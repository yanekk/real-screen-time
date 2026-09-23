// What every endpoint handler needs, injected rather than reached for, so the unit suite runs
// against an in-memory Repo and a stubbed Google verifier with no AWS and no network (DESIGN §4).

import type { Repo } from "../repo.js";
import type { GoogleVerifier } from "../auth.js";

export interface Deps {
  repo: Repo;
  /** Verifies a Google ID token; the real one is `makeGoogleVerifier` (google.ts), tests stub it. */
  verifyGoogle: GoogleVerifier;
  /** The parent's allowed emails (from `AUTHORIZED_EMAILS`) — the authorization (DESIGN §2.2). */
  allowlist: string[];
  /**
   * The OAuth client id (from `GOOGLE_CLIENT_ID`), injected into the served page so it and the
   * token-verifying backend share one audience (static.ts). Optional: absent, the page still
   * serves but sign-in is inert — only the static-serving path reads it, never the API handlers.
   */
  googleClientId?: string;
}

// The single Lambda behind the HTTP API (DESIGN §3.6). It builds the real dependencies from the
// environment once — reused across warm invocations — and delegates all routing to ./router.ts,
// which the unit suite exercises directly with an in-memory Repo and a stubbed Google verifier.
//
// The web page (GET / and /app.js) is served by the router from the embedded webAssets (T09).
// Config comes from Lambda env, never the repo (DESIGN §3.6): GOOGLE_CLIENT_ID, AUTHORIZED_EMAILS,
// TABLE_NAME.

import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { DynamoRepo } from "./repo.js";
import { parseAllowlist } from "./auth.js";
import { makeGoogleVerifier } from "./google.js";
import { route } from "./router.js";
import type { Deps } from "./handlers/deps.js";

let cached: Deps | undefined;

// Built lazily and memoised, so the DynamoDB client and the Google OAuth client are created once
// per warm container rather than on every request.
function deps(): Deps {
  if (!cached) {
    cached = {
      repo: new DynamoRepo(process.env.TABLE_NAME ?? ""),
      verifyGoogle: makeGoogleVerifier(process.env.GOOGLE_CLIENT_ID ?? ""),
      allowlist: parseAllowlist(process.env.AUTHORIZED_EMAILS),
      // Same env value the verifier closes over — injected into the served page so its sign-in and
      // this backend's verify name one audience (static.ts, DESIGN §3.6).
      googleClientId: process.env.GOOGLE_CLIENT_ID ?? "",
    };
  }
  return cached;
}

export async function handler(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyResultV2> {
  return route(event, deps());
}

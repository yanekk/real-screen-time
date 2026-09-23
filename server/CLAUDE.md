# CLAUDE.md — the web app and its backend (`server/`)

The parent's web page and the remote-grant backend: one HTTP API → one Lambda → one DynamoDB
table on the parent's AWS account (`remote-grant` plan, DESIGN §3.6). TypeScript on Node, not
Swift, and it meets the Mac app only over HTTP. [README.md](README.md) is the reference for the
layout, the endpoints and the auth model; this file holds the rules for working here.

**The repo-root [CLAUDE.md](../CLAUDE.md) still binds everything here** — who decides what,
writing to the parent in plain English, strict scope, and that anything only a person can see
is verified with them, not asserted. The Swift-only rules there (Core/App boundary, no
third-party dependencies, `make test`) do not apply to this folder: `google-auth-library` is
a deliberate runtime dependency.

## Commands (run in `server/`)

```bash
npm test               # vitest, headless, no AWS, no network — always safe
npm run typecheck      # tsc --noEmit
npm run build:web      # web/ → src/webAssets.ts; required after any edit under web/
npm run deploy:web     # build:web, sam build, sam deploy --profile admin
```

`web/` is the source of truth for the page; `src/webAssets.ts` is generated and never
hand-edited. `test/web.test.ts` fails if the two drift.

## Deploying — you may do it on your own

**You have the parent's standing permission to deploy with `npm run deploy:web`** without
asking first (granted 2026-09-23). A deploy is an in-place update of the one
`real-screen-time` stack at the same URL, and it is reversible: the previous commit redeploys
the same way. Say in one line afterwards that you deployed and what changed.

Before every deploy, in this order:

1. `npm test` and `npm run typecheck` are green. Never deploy a red suite.
2. **Check the credentials first:** `aws sts get-caller-identity --profile admin`. If it
   fails (no session, or an expired one), do not try to log in and do not use another profile.
   Stop and ask the parent to run `aws sso login --profile admin`, then check again.
3. `npm run deploy:web`.
4. Confirm the live stack answers, on both the `WebUrl` and the `ApiUrl` outputs: `GET /` → 200
   with the real client id in the page, and `GET /grants` with no token → 401.

**Nothing specific to the family goes in the repo** (the parent's rule, 2026-09-23): not the
domain, the DNS zone, the Google client id, the emails, the account id, nor the execute-api
address. They live in SSM Parameter Store under `/real-screen-time/` (README.md lists them);
the template resolves them at deploy time and `make bundle` reads the domain for the Mac app.
`samconfig.toml` holds only their names. Refer to them by parameter name in code, docs, plans
and commit messages; changing a value is a `put-parameter` plus a redeploy, and is the
parent's call.

**The permission covers `npm run deploy:web` and nothing wider.** These stay the parent's call,
asked before, every time:

- `sam delete`, or anything that removes or replaces the stack or the table. That is not
  reversible: the table holds the pairing and any saved sessions, and a new stack gets a new
  URL, which breaks the Google sign-in origin and the Mac's pinned endpoint.
- Changing `template.yaml` resources, the stack's parameters (Google client id, authorized
  emails), or anything in the Google Cloud console.
- Deploying from a branch or checkout other than the one the parent is working on.

A deploy proves the code is live, not that the page works. Anything in a browser or on the
Mac — sign-in, a grant dropping the cover, pairing — is still handed to the parent to check.

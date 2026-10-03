# Real Screen Time — backend

The remote-grant backend (DESIGN §3.6): one HTTP API → one Lambda → one DynamoDB table, on
the **parent's** AWS account. The parent signs in with Google to create grants; the child's
Mac holds a read-only device token to fetch and consume them. It shares no code with the Swift
app and meets it only over HTTP.

T08 adds the five endpoints and the auth behind them (DESIGN §3.6, §2.3); the web page is T09
and the real deploy is T10.

## Layout

```
src/handler.ts       the Lambda entry: builds Deps from env (once, reused) and calls the router
src/router.ts        method + path → one of the five endpoint handlers, or the static page
src/handlers/        the endpoints: grant.ts, grants.ts, pair.ts; parent.ts is the shared
                     create-side gate; static.ts serves the page; deps.ts is what they are injected
src/auth.ts          pure auth primitives: allowlist, device-token mint/hash/shape, code mint/normalize
src/google.ts        the one place google-auth-library is loaded (real ID-token verify); injected,
                     so the test suite mocks it and never touches the network
src/http.ts          request/response helpers: Bearer, JSON body, ISO-8601 (no fractional seconds)
src/repo.ts          the data-access interface + a DynamoDB and an in-memory implementation
src/webAssets.ts     GENERATED (build:web) — web/ embedded so the bundle serves it; do not hand-edit
web/                 the parent's static page: index.html + app.js (source of truth, edit here)
test/                vitest suites; they run only against InMemoryRepo with a stubbed verifier, never AWS
template.yaml        AWS SAM: the table, the Lambda, the HTTP API
```

### The web page (T09)

The parent's whole interface (DESIGN §2.2): sign in with Google, tap 15 / 30 / 60, and — when
connecting a Mac — show a pairing code. It is a plain static page under `web/` (no framework),
served **same-origin by the same Lambda** that owns the API, so its calls are relative paths with
no CORS (FINDINGS 2026-09-22). `router.ts` serves `GET /` (index.html) and `GET /app.js`, filling
the `__GOOGLE_CLIENT_ID__` placeholder from the Lambda's `GOOGLE_CLIENT_ID` at serve time — so the
page and the token-verifying backend always share one OAuth audience and the deploy sets one param,
not two.

The SAM build bundles only `src/handler.ts` with esbuild, which copies no loose files, so the page
is embedded as code in `src/webAssets.ts`. **After editing anything under `web/`, regenerate it:**

```bash
cd server && npm run build:web    # web/ → src/webAssets.ts
```

`test/web.test.ts` fails if the embedded copy has drifted from `web/`, so a forgotten regenerate is
caught by `make server-test`. The page's DOM wiring is tested in `test/web-dom.test.ts`, which runs
the real page in happy-dom (a simulated DOM) with fetch, confirm and Google stubbed; see CLAUDE.md.
Only real Google sign-in and a real browser's rendering are left to hand-verify (DESIGN §5.1).

### The auth model, in one line each

- **Create side** (`POST /grant`, `POST /pair/code`): a Google ID token as `Authorization: Bearer`,
  verified, its email on `AUTHORIZED_EMAILS`. A device token — recognizable as 64-hex — is refused
  403 here: it carries no create scope (DESIGN §2.3). A valid **saved-session cookie** is accepted
  in place of the Google token (see below), so a signed-in parent grants without a fresh sign-in.
- **Saved session** (`POST` / `GET` / `DELETE /session`, DESIGN §2.2 amendments): `POST /session`
  trades a create-side Google token for a rolling 30-day server session, returned in an
  `HttpOnly`, `Secure`, `SameSite=Lax` `rst_session` cookie (the store holds only its hash).
  `GET /` reads that cookie and renders the page already signed in or out, and paired or not,
  extending the session once a day; `GET /session` reports the same as JSON; `DELETE /session`
  signs out. A session counts only while its email is still on `AUTHORIZED_EMAILS`.
- **Receive side** (`GET /grants`, `POST /grants/{id}/consume`): the read-only device token, checked
  by hash against the single active token. Consume is idempotent.
- **Pairing** (`POST /pair/redeem`): the code in the body is the credential; redeeming replaces the
  single active device token, so re-pairing revokes the previous Mac (DESIGN §2.4).
- **Unpair** (`POST /pair/unpair`, create side): deletes the active device token, so the paired
  Mac's next poll is refused and its Settings shows "re-pair" (DESIGN §2.4 amendment 2026-09-23).

## Test — runs here, headless, no AWS

```bash
make server-test          # from the repo root; or, in this dir: FORCE_COLOR=0 npm test
```

It runs vitest in run mode with colour forced off: one summary line per file on green, full
detail on any failure, and a non-zero exit when anything fails. Colour is forced off in the
command because `FORCE_COLOR`/`CI` would otherwise re-enable it in a piped run.

**To see per-test detail** (when debugging a failure):

```bash
cd server && npm test -- --reporter=verbose
```

Type-check without running tests: `cd server && npm run typecheck`.

## Deploy and teardown — the parent's account only (a person, DESIGN §5.1)

Neither the parent's AWS credentials nor their Google OAuth client is on the build machine, so
these are hand-run. The full Google-console walkthrough is inherited from the T00 spike runbook.

```bash
cd server
npm run build:web            # only if web/ changed since src/webAssets.ts was generated
sam validate --lint          # template syntax only; runs here, no account needed
PATH="$PWD/node_modules/.bin:$PATH" sam build   # esbuild bundles src/handler.ts (page embedded)
sam deploy --guided          # first time: set GoogleClientId + AuthorizedEmails, save config
sam deploy                   # subsequent deploys reuse samconfig.toml
```

`sam build` uses the esbuild BuildMethod and needs the `esbuild` binary reachable. It is a
devDependency (`node_modules/.bin/esbuild`) but SAM looks on the host PATH, so prefix the command
with `node_modules/.bin` as above (or install esbuild globally). Without it the build fails with
"Cannot find esbuild".

After the first deploy, register the `ApiUrl` output (no trailing slash) as an Authorized
JavaScript origin on the Google OAuth client.

### Deployment settings live in Parameter Store, not the repo

Nothing specific to the family is committed: no domain, DNS zone, Google client id or email.
They are four SSM Parameter Store entries (plain `String`, region `eu-central-1`), which
CloudFormation resolves at deploy time and `make bundle` reads for the Mac app:

| Parameter | Holds |
|---|---|
| `/real-screen-time/google-client-id` | the Google OAuth web client id |
| `/real-screen-time/authorized-emails` | comma-separated parent emails allowed to create |
| `/real-screen-time/custom-domain-name` | the web app's domain (no scheme); also the Mac's backend |
| `/real-screen-time/hosted-zone-id` | the Route 53 zone, in this account, that owns the domain |

`samconfig.toml` only names them, so it is committed. To seed a new account, before the first
deploy:

```bash
aws ssm put-parameter --profile admin --region eu-central-1 --type String \
  --name /real-screen-time/custom-domain-name --value <domain>    # and the other three
```

Changing a value takes effect on the next deploy (and, for the domain, the next `make bundle`).

### The web app's own domain

From `custom-domain-name` and `hosted-zone-id` the stack owns an ACM certificate
(DNS-validated automatically), an API Gateway custom domain mapped to the existing API, and one
`A` alias record in the zone. The record is CloudFormation's; do not edit it by hand. The
`ApiUrl` keeps serving too. The `WebUrl` output must be an Authorized JavaScript origin on the
Google OAuth client, next to `ApiUrl`, or sign-in fails on it.

### The Mac app's backend address (set at bundle time)

The child's Mac does **not** type the backend URL into a field, and the source holds none
(DESIGN §2.4, §8). `make bundle` reads `custom-domain-name` from Parameter Store and stamps
`https://<domain>` into the bundle's `Info.plist` as `RSTRemoteEndpoint`, which
`RemoteClient.productionEndpoint` reads. So `make bundle` / `make install` need the admin profile
signed in (`aws sso login --profile admin`); `make bundle REMOTE_ENDPOINT=https://...` points a
build at another backend without AWS.

Pairing stores the endpoint in `config.json`, so a reinstalled app keeps talking to whatever it
was paired against until it is re-paired. A `swift run` has no bundle plist: use
`RST_REMOTE_ENDPOINT=<url>` (DESIGN §5.2), or a pair attempt fails closed.

### Smoke-test the deployed stack (no browser)

Once the stack is up, confirm the backend answers correctly before pairing the real Mac. Sign
in to the web page as the parent, choose "connect a Mac", read the pairing code it shows, then:

```bash
server/scripts/smoke.sh <ApiUrl> <pairing-code>
```

It redeems the code for a device token, lists grants with it, confirms `POST /grant` is refused
`403` for a device token (create is parent-only, DESIGN §2.3), and confirms an unknown token is
refused `401` on the receive side (DESIGN §2.7). Exit 0 means all four passed. It needs only
`curl`; `jq` just pretty-prints the grant list when present.

Two things it does that matter: the pairing code is **single-use** (DESIGN §2.4), so mint a
fresh one per run; and the device token it obtains is real, so running the smoke test **re-pairs
and revokes** whatever Mac was paired before. Run it before pairing the real Mac, or re-pair the
Mac afterwards.

**Teardown** (the seatbelt for any deploy done to verify — DESIGN §5.2):

```bash
sam delete
```

## Dependencies

`google-auth-library` (for verifying Google ID tokens) is the one runtime dependency; it is
bundled into the Lambda by esbuild. The AWS SDK v3 is **provided by the nodejs runtime**, so it is
a dev-only dependency here and is marked `External` in the esbuild bundle (`template.yaml`) rather
than shipped.

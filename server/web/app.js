// The parent's whole interface, in one file (DESIGN §2.2): sign in with Google, tap 15 / 30 / 60
// to add minutes, and — when connecting a Mac — show a pairing code. No framework: it is a page,
// not an app. Loaded as an ES module by index.html; talks to the T08 endpoints on the same origin
// (the page is served by the Lambda that owns the API, so every call is a relative path and there
// is no CORS — FINDINGS 2026-09-22, template.yaml).
//
// English throughout: this is the parent's side of the product, behind the same wall as Settings
// (initial-build §2.4.2). The child never sees it.
//
// The file has two halves. The exported functions at the top are pure request-building and
// response-reading logic, unit-tested in node (test/web.test.ts) with no DOM. The DOM wiring at
// the bottom runs only in a browser (guarded on `document`), so importing this module in a test
// touches nothing on screen and needs no Google. The wiring itself — Google sign-in and the live
// buttons — is confirmed by hand in T10, the only place a real Google account and a real screen
// exist (DESIGN §5.1).

// The three amounts, hard-coded to the app's default extension_options (DESIGN §2.2, §8). Syncing
// them with the Mac's config is deliberately out of scope; they are a constant here.
export const AMOUNTS = [15, 30, 60];

// The create-side auth header. Two callers use these requests: right after a Google sign-in, with
// the Google ID token in hand (Bearer); and on every later visit, signed in only by the saved
// session cookie, with no token (`idToken` omitted) — the cookie rides along on the same-origin
// fetch and the backend accepts it (requireParent). So the Bearer is included only when present.
function bearerHeader(idToken) {
  return idToken ? { authorization: `Bearer ${idToken}` } : {};
}

/**
 * The `POST /grant` call for `minutes` (the create-side wire, FINDINGS 2026-09-22). `idToken` is
 * optional: with it, the Google token authenticates; without it, the saved-session cookie does.
 * Relative URL: same origin, so the cookie is sent.
 */
export function grantRequest(idToken, minutes) {
  return {
    url: "/grant",
    options: {
      method: "POST",
      headers: { ...bearerHeader(idToken), "content-type": "application/json" },
      body: JSON.stringify({ minutes }),
    },
  };
}

/**
 * The `POST /pair/code` call — no body (the parent's identity is the whole request). Google token
 * or saved-session cookie, as above. Returns `{ code, expiresInSeconds }` to show the parent.
 */
export function pairCodeRequest(idToken) {
  return {
    url: "/pair/code",
    options: {
      method: "POST",
      headers: bearerHeader(idToken),
    },
  };
}

/**
 * The `GET /pair/status` call (T12) — no body. Google token or saved-session cookie. The backend
 * returns `{ paired: boolean }`, whether a Mac is currently paired, exposing no token (DESIGN §2.3).
 */
export function pairStatusRequest(idToken) {
  return {
    url: "/pair/status",
    options: {
      method: "GET",
      headers: bearerHeader(idToken),
    },
  };
}

/**
 * The `POST /pair/unpair` call (DESIGN §2.4 amendment 2026-09-23) — no body. Google token or
 * saved-session cookie. The backend deletes the active device token, so the paired Mac stops
 * receiving minutes and shows "re-pair" in its Settings on its next poll.
 */
export function unpairRequest(idToken) {
  return {
    url: "/pair/unpair",
    options: {
      method: "POST",
      headers: bearerHeader(idToken),
    },
  };
}

/**
 * The `POST /session` call: trade the Google ID token for a saved session (DESIGN §2.2 amendment
 * 2026-09-22). Sent once, right after a Google sign-in; the backend replies with a Set-Cookie the
 * browser then carries on every later visit, so a refresh stays signed in with no Google prompt.
 */
export function sessionEstablishRequest(idToken) {
  return {
    url: "/session",
    options: {
      method: "POST",
      headers: bearerHeader(idToken),
    },
  };
}

/** The `DELETE /session` call — sign out. The cookie identifies the session; the backend clears it. */
export function signOutRequest() {
  return { url: "/session", options: { method: "DELETE" } };
}

/**
 * Turn a `POST /grant` response into a line for the parent. 201 → added; anything else is an
 * error, and the cover on the child's Mac stays up regardless (the web app only ever asks; the
 * Mac decides — DESIGN §2.6). The server's `{error}` text is English and safe to show.
 */
export function describeGrantResult(status, body) {
  if (status === 201) {
    const m = body && typeof body.minutes === "number" ? body.minutes : null;
    return { ok: true, message: m === null ? "Added." : `Added ${m} minutes.` };
  }
  return { ok: false, message: errorLine("Couldn't add minutes", status, body) };
}

/**
 * Turn a `POST /pair/code` response into either the code to display or an error line.
 */
export function describePairResult(status, body) {
  if (status === 200 && body && typeof body.code === "string" && body.code.length > 0) {
    // expiresInSeconds bounds how long the page watches for the Mac to redeem the code.
    return typeof body.expiresInSeconds === "number"
      ? { ok: true, code: body.code, expiresInSeconds: body.expiresInSeconds }
      : { ok: true, code: body.code };
  }
  return { ok: false, message: errorLine("Couldn't get a pairing code", status, body) };
}

function errorLine(prefix, status, body) {
  const detail = body && typeof body.error === "string" ? body.error : `error ${status}`;
  return `${prefix}: ${detail}.`;
}

/**
 * Read a `GET /pair/status` response (T12). 200 with a boolean `paired` → that value; anything
 * else → not ok, and the caller leaves the connect panel as it was: an unknown state never
 * flips the buttons, so a failed read cannot hide Unpair from a paired parent or vice versa.
 */
export function describePairStatusResult(status, body) {
  if (status === 200 && body && typeof body.paired === "boolean") {
    return { ok: true, paired: body.paired };
  }
  return { ok: false };
}

/**
 * The confirmation shown before a grant (the parent's rule, 2026-09-23): a mis-tap on the phone
 * would hand the child minutes that cannot be taken back, so every amount asks first.
 */
export function grantConfirmMessage(minutes) {
  return `Add ${minutes} minutes to the Mac?`;
}

/** Shown after a grant, since the buttons stay disabled until the page is reloaded. */
export const GRANT_DONE_HINT = "Reload the page to add more.";

/** The confirmation shown before unpairing: re-pairing later needs the parent at the Mac. */
export const UNPAIR_CONFIRM =
  "Unpair this Mac? It stops receiving minutes until you pair it again from its Settings.";

/**
 * Read a `POST /pair/unpair` response: 200 `{ paired: false }` → unpaired; anything else is an
 * error line, and the panel is left as it was.
 */
export function describeUnpairResult(status, body) {
  if (status === 200 && body && body.paired === false) {
    return { ok: true, message: "Unpaired." };
  }
  return { ok: false, message: errorLine("Couldn't unpair", status, body) };
}

/**
 * The signed-in state the server rendered into the page (DESIGN §2.2 amendment 2026-09-23). The
 * server reads the session cookie when it serves `GET /` and fills `<body data-signed-in>`, so the
 * page starts in its final state with no round-trip and no sign-in button flashing. Only the exact
 * string "true" is signed in; a missing attribute or an unfilled placeholder is signed out, never
 * the reverse.
 */
export function initialSignedIn(attribute) {
  return attribute === "true";
}

/**
 * Whether a response means the saved session is gone (expired, signed out elsewhere, or its email
 * taken off the allowlist): the backend answers 401 on the create side. The page then drops to its
 * signed-out state and offers Google sign-in again, instead of showing an error line.
 */
export function sessionLost(status) {
  return status === 401;
}

/**
 * Read a `POST /session` response: 200 with `signedIn: true` means the session cookie is set and the
 * parent will stay signed in. Anything else is shown as an error, and the page stays signed out —
 * a failed session is never treated as a sign-in.
 */
export function describeSessionEstablish(status, body) {
  if (status === 200 && body && body.signedIn === true) {
    return { ok: true, message: "Signed in." };
  }
  return { ok: false, message: errorLine("Couldn't stay signed in", status, body) };
}

/**
 * When the amount buttons are `disabled` (DESIGN §2.2). Signed out: always, so nothing can be
 * granted before the parent is known; signed-in-ness is a Google token in hand or a live saved
 * session (a truthy flag). Signed in: once a grant has gone through (`granted`), or while one is in
 * flight (`busy`) — one grant per page load, so a double tap or a second tap cannot stack minutes
 * by accident (amendment 2026-09-23). Only a reload clears `granted`; a failed grant does not set
 * it, so the parent can retry.
 */
export function amountButtonsDisabled(signedIn, granted = false, busy = false) {
  return !signedIn || granted || busy;
}

// ---------------------------------------------------------------------------------------------
// DOM wiring — browser only. Skipped entirely under a node import (no `document`), which is what
// lets the block above be tested with no window ever created.
// ---------------------------------------------------------------------------------------------

// Google Identity Services, loaded on demand — only when the parent actually has to sign in.
const GSI_SRC = "https://accounts.google.com/gsi/client";

if (typeof document !== "undefined") {
  document.addEventListener("DOMContentLoaded", init);
}

function init() {
  // The page's state lives on two <body> attributes: the server fills them when it serves the
  // page, the stylesheet derives what is visible from them, and this script only updates them.
  //   data-signed-in — decided by the server (initialSignedIn); afterwards changed only by a
  //                    Google sign-in (onCredential), a sign-out, or the backend refusing the
  //                    session (sessionLost). Every create call is authorized by the cookie.
  //   data-paired    — "true" | "false" | "unknown"; one parent, one Mac (DESIGN §2.4 amendment
  //                    2026-09-23): paired shows the note and Unpair only, otherwise Connect only.
  const body = document.body;
  let signedIn = initialSignedIn(body.dataset.signedIn);
  // One grant per page load: set on a successful grant and never cleared, so sign-out/sign-in
  // does not re-enable the buttons either — only a reload does. `granting` covers the request.
  let granted = false;
  let granting = false;

  const els = {
    signin: document.getElementById("signin"),
    connect: document.getElementById("connect"),
    code: document.getElementById("code"),
    status: document.getElementById("status"),
    signout: document.getElementById("signout"),
    unpair: document.getElementById("unpair"),
  };

  // While a pairing code is on screen, re-read the paired state every few seconds so the panel
  // flips to "A Mac is paired" + Unpair by itself once the code is typed on the Mac. Stopped when
  // paired, when the code expires, and on sign-out.
  const PAIR_WATCH_INTERVAL_MS = 3000;
  let pairWatch = null;
  // Google's library: loaded once, on first need (loadGoogle), initialized once (showGoogleButton).
  let gsiLoading = null;
  let gsiInitialized = false;
  function stopPairWatch() {
    if (pairWatch) clearInterval(pairWatch);
    pairWatch = null;
  }

  const amountButtons = [...document.querySelectorAll("button.amount")];
  for (const b of amountButtons) {
    b.addEventListener("click", () => addMinutes(Number(b.dataset.minutes)));
  }
  els.connect.addEventListener("click", getPairingCode);
  els.unpair.addEventListener("click", unpairMac);
  els.signout.addEventListener("click", signOut);

  function reflectSignedIn() {
    body.dataset.signedIn = String(signedIn);
    // The stylesheet already greys the controls while signed out; `disabled` also takes them out
    // of keyboard focus, so nothing can be granted before the parent is known (DESIGN §2.2).
    reflectAmountButtons();
    const disabled = !signedIn;
    els.connect.disabled = disabled;
    if (disabled) {
      stopPairWatch();
      body.dataset.paired = "false"; // meaningless while signed out; shows the greyed Connect
      els.code.textContent = "";
      showGoogleButton();
    } else if (body.dataset.paired !== "true" && body.dataset.paired !== "false") {
      refreshPairState(); // the server could not tell; ask now
    }
  }

  function reflectAmountButtons() {
    const disabled = amountButtonsDisabled(signedIn, granted, granting);
    for (const b of amountButtons) b.disabled = disabled;
  }

  function applyPaired(paired) {
    body.dataset.paired = String(paired);
    if (paired) {
      // A code still on screen has been used (or is moot), so clear it and stop watching.
      stopPairWatch();
      els.code.textContent = "";
    }
  }

  // Load Google's library once, on first need. The hook is installed before the script is added,
  // so it cannot load first and miss it (the async-race T09 flagged).
  function loadGoogle() {
    if (window.google?.accounts?.id) return Promise.resolve();
    if (!gsiLoading) {
      gsiLoading = new Promise((resolve, reject) => {
        window.onGoogleLibraryLoad = resolve;
        const script = document.createElement("script");
        script.src = GSI_SRC;
        script.async = true;
        script.onerror = () => {
          gsiLoading = null; // allow a retry on the next sign-out or reload
          reject(new Error("Google sign-in did not load"));
        };
        document.head.appendChild(script);
      });
    }
    return gsiLoading;
  }

  async function showGoogleButton() {
    try {
      await loadGoogle();
    } catch {
      setStatus("Sign-in is unavailable — Google could not be reached. Reload to try again.");
      return;
    }
    if (signedIn) return; // signed in while the library was loading
    const clientId = document
      .querySelector('meta[name="google-signin-client_id"]')
      ?.getAttribute("content");
    if (!clientId || !window.google?.accounts?.id) {
      setStatus("Sign-in is unavailable — the page is misconfigured.");
      return;
    }
    if (!gsiInitialized) {
      // The client id is the server's own GOOGLE_CLIENT_ID (static.ts), so the page and the
      // verifying backend agree on the audience. No auto-select or One Tap: staying signed in is
      // the saved session's job (DESIGN §2.2 amendment 2026-09-22), not Google's.
      window.google.accounts.id.initialize({ client_id: clientId, callback: onCredential });
      gsiInitialized = true;
    }
    els.signin.replaceChildren();
    window.google.accounts.id.renderButton(els.signin, { theme: "outline", size: "large" });
  }

  // The backend refused the session mid-use: drop to signed out and offer Google sign-in again.
  function onSessionLost() {
    if (!signedIn) return;
    signedIn = false;
    reflectSignedIn();
    setStatus("Your sign-in has expired — sign in again.");
  }

  // Ask the backend whether a Mac is currently paired (T12). A failed or non-200 read leaves the
  // panel as it is; a 401 means the session is gone.
  async function refreshPairState() {
    if (!signedIn) return;
    const { url, options } = pairStatusRequest(); // no token: the session cookie authorizes
    try {
      const res = await fetch(url, options);
      if (sessionLost(res.status)) return onSessionLost();
      const data = await res.json().catch(() => undefined);
      const result = describePairStatusResult(res.status, data);
      if (result.ok) {
        const wasWatching = pairWatch !== null;
        applyPaired(result.paired);
        if (wasWatching && result.paired) setStatus("Mac paired.");
      }
    } catch {
      // Leave the panel unchanged; a status read is not worth a scary message.
    }
  }

  function setStatus(message) {
    els.status.textContent = message;
  }

  // Google handed back an ID token. Trade it once for a saved session (the cookie); from then on the
  // cookie, not this token, authorizes everything — so the token is used here and not kept.
  async function onCredential(response) {
    const idToken = response?.credential ?? null;
    if (!idToken) {
      setStatus("Sign-in failed.");
      return;
    }
    const { url, options } = sessionEstablishRequest(idToken);
    await call(url, options, describeSessionEstablish, () => {
      signedIn = true;
      body.dataset.paired = "unknown"; // not known for this visit yet; reflectSignedIn asks
      reflectSignedIn();
    });
  }

  async function signOut() {
    const { url, options } = signOutRequest();
    try {
      await fetch(url, options); // clears the cookie and deletes the session server-side
    } catch {
      // Best-effort: even if the call fails, drop the UI to signed-out below.
    }
    signedIn = false;
    reflectSignedIn();
    setStatus("Signed out.");
  }

  async function unpairMac() {
    if (!signedIn) return;
    // A mis-tap would cut the Mac off until the parent is physically at it, so ask first.
    if (!window.confirm(UNPAIR_CONFIRM)) return;
    const { url, options } = unpairRequest(); // cookie authorizes
    await call(url, options, describeUnpairResult, () => applyPaired(false));
  }

  async function addMinutes(minutes) {
    if (amountButtonsDisabled(signedIn, granted, granting)) return;
    if (!window.confirm(grantConfirmMessage(minutes))) return;
    granting = true;
    reflectAmountButtons();
    const { url, options } = grantRequest(undefined, minutes); // cookie authorizes
    await call(url, options, describeGrantResult, (result) => {
      granted = true;
      result.message = `${result.message} ${GRANT_DONE_HINT}`;
    });
    granting = false;
    reflectAmountButtons();
  }

  async function getPairingCode() {
    if (!signedIn) return;
    els.code.textContent = "";
    const { url, options } = pairCodeRequest(); // cookie authorizes
    await call(url, options, describePairResult, (result) => {
      els.code.textContent = result.code;
      // Watch for the Mac to redeem the code, for as long as the code lives (600 s by default).
      stopPairWatch();
      const lifetimeMs = (result.expiresInSeconds ?? 600) * 1000;
      const started = Date.now();
      pairWatch = setInterval(() => {
        if (Date.now() - started > lifetimeMs) {
          stopPairWatch();
          els.code.textContent = "";
          setStatus("The pairing code expired — get a new one.");
          return;
        }
        refreshPairState();
      }, PAIR_WATCH_INTERVAL_MS);
    });
  }

  // One request path for every button: fetch, read JSON defensively, describe the result, and show
  // its message. A 401 while signed in means the saved session is gone, so the page drops to signed
  // out rather than showing an error. (POST /session carries a Google token and runs signed out;
  // its 401 is a bad Google token and is reported like any other error.) Any network or parse
  // failure is reported and changes nothing on the Mac — the create call failing is not a grant
  // (DESIGN §2.6, §2.7).
  async function call(url, options, describe, onOk) {
    setStatus("Working…");
    try {
      const res = await fetch(url, options);
      if (sessionLost(res.status) && signedIn) return onSessionLost();
      const data = await res.json().catch(() => undefined);
      const result = describe(res.status, data);
      if (result.ok) onOk(result);
      setStatus(result.message ?? "");
    } catch {
      setStatus("Network error — nothing was changed.");
    }
  }

  // First render, last: every piece of state above (let bindings are not hoisted like functions)
  // must exist before reflectSignedIn runs. Calling it earlier threw inside loadGoogle on a
  // signed-out load, which the catch reported as "Google could not be reached" (2026-09-23).
  reflectSignedIn();
}

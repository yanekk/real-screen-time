// @vitest-environment happy-dom
// @vitest-environment-options {"settings":{"disableJavaScriptFileLoading":true,"handleDisabledFileLoadingAsSuccess":true}}
/// <reference lib="dom" />
/// <reference lib="dom.iterable" />
//
// The page's DOM wiring (DESIGN §2.2, §2.4): the real index.html and the real app.js, run in a
// simulated DOM (happy-dom) and driven by clicks, with fetch, window.confirm and Google's library
// stubbed. Every behaviour a parent can trigger on the page is tested here — the rule in
// server/CLAUDE.md. web.test.ts keeps the pure helpers and the serving path. Still outside this:
// a real browser drawing the page and the native confirm box, and real Google sign-in (DESIGN §5.1).

import { readFileSync } from "node:fs";
// node:url's URL, not the global one: under happy-dom the global is the DOM's, which rejects file:.
import { URL as NodeURL, fileURLToPath } from "node:url";
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

const html = readFileSync(fileURLToPath(new NodeURL("../web/index.html", import.meta.url)), "utf8");
// Parsed, not regex-sliced: the stylesheet's comments mention "<body>", which a regex latches onto.
// Parsing still connects the page's <script src="/app.js">, and happy-dom would fetch it from
// localhost:3000 after the run ends and report the refusal as an unhandled error (a red run with
// every test green). The environment options above switch script downloads off for this file.
const parsed = new DOMParser().parseFromString(html, "text/html");
parsed.querySelectorAll("script").forEach((s) => s.remove());
const styleHtml = parsed.head.querySelector("style")!.outerHTML;
const bodyHtml = parsed.body.innerHTML;

// What the stand-in server answers: a status and JSON body, or an Error for a network failure.
type Reply = { status: number; body?: unknown } | Error;
// Replies keyed by "METHOD /path"; each key is a queue, and its last reply repeats once reached.
type Server = Record<string, Reply[]>;

let confirmSpy: ReturnType<typeof vi.fn>;
let fetchSpy: ReturnType<typeof vi.fn>;
let renderButton: ReturnType<typeof vi.fn>;
let googleCallback: ((r: { credential?: string }) => void) | undefined;

const DEFAULTS: Server = {
  "POST /grant": [{ status: 201, body: { minutes: 15 } }],
  "GET /pair/status": [{ status: 200, body: { paired: true } }],
  "POST /pair/code": [{ status: 200, body: { code: "ABCD2345", expiresInSeconds: 600 } }],
  "POST /pair/unpair": [{ status: 200, body: { paired: false } }],
  "POST /session": [{ status: 200, body: { signedIn: true } }],
  "DELETE /session": [{ status: 200, body: {} }],
};

type PageOptions = {
  signedIn?: boolean;
  paired?: "true" | "false" | "unknown";
  server?: Server;
  google?: "stub" | "fails-to-load";
};

// Load a fresh copy of app.js against a fresh page in the state the server would have rendered.
// app.js registers init on DOMContentLoaded at import; capturing that callback and calling it
// directly keeps earlier tests' listeners from wiring the same buttons twice.
async function loadPage({ signedIn = true, paired = "true", server = {}, google = "stub" }: PageOptions = {}) {
  document.head.innerHTML = `<meta name="google-signin-client_id" content="test-client-id" />${styleHtml}`;
  document.body.innerHTML = bodyHtml;
  document.body.dataset.signedIn = String(signedIn);
  document.body.dataset.paired = paired;

  confirmSpy = vi.fn(() => true);
  window.confirm = confirmSpy as unknown as typeof window.confirm;

  const queues: Server = { ...DEFAULTS, ...server };
  fetchSpy = vi.fn(async (url: string, options: RequestInit = {}) => {
    const key = `${options.method ?? "GET"} ${url}`;
    const q = queues[key];
    if (!q) throw new Error(`unexpected request ${key}`);
    const r = q.length > 1 ? q.shift()! : q[0]!;
    if (r instanceof Error) throw r;
    return { status: r.status, json: async () => r.body };
  });
  globalThis.fetch = fetchSpy as unknown as typeof fetch;

  // Google's library never loads from the network in a test: either a stand-in is already present,
  // or the <script> the page adds is made to fail.
  renderButton = vi.fn();
  googleCallback = undefined;
  if (google === "stub") {
    (window as any).google = {
      accounts: {
        id: {
          initialize: (cfg: { callback: typeof googleCallback }) => (googleCallback = cfg.callback),
          renderButton,
        },
      },
    };
  } else {
    delete (window as any).google;
    vi.spyOn(document.head, "appendChild").mockImplementation(((node: HTMLScriptElement) => {
      queueMicrotask(() => node.onerror?.(new Event("error")));
      return node;
    }) as typeof document.head.appendChild);
  }

  let init: (() => void) | undefined;
  const add = vi.spyOn(document, "addEventListener").mockImplementation(((type: string, fn: () => void) => {
    if (type === "DOMContentLoaded") init = fn;
  }) as typeof document.addEventListener);
  vi.resetModules();
  await import("../web/app.js");
  add.mockRestore();
  init!();
  await settle();
}

// Let every pending fetch/json promise chain finish (a macrotask runs after all microtasks).
const settle = () => new Promise((r) => setTimeout(r, 0));

const $ = (id: string) => document.getElementById(id)!;
const amountButtons = () => [...document.querySelectorAll<HTMLButtonElement>("button.amount")];
const amount = (m: number) => amountButtons().find((b) => b.dataset.minutes === String(m))!;
const allAmountsDisabled = () => amountButtons().every((b) => b.disabled);
const noAmountsDisabled = () => amountButtons().every((b) => !b.disabled);
const status = () => $("status").textContent;
const shown = (id: string) => getComputedStyle($(id)).display !== "none";
const requests = () => fetchSpy.mock.calls.map(([url, o]) => `${o?.method ?? "GET"} ${url}`);

beforeEach(() => vi.restoreAllMocks());
afterEach(() => vi.useRealTimers());

describe("first render — the state the server decided (DESIGN §2.2 amendment 2026-09-23)", () => {
  it("signed in and paired: amounts enabled, the paired note and Unpair shown, no requests", async () => {
    await loadPage({ signedIn: true, paired: "true" });
    expect(noAmountsDisabled()).toBe(true);
    expect(shown("pairstate")).toBe(true);
    expect(shown("unpair")).toBe(true);
    expect(shown("connect")).toBe(false);
    expect(shown("signin")).toBe(false);
    expect(shown("signout")).toBe(true);
    expect(requests()).toEqual([]);
  });

  it("signed in and not paired: Connect a Mac shown, Unpair hidden", async () => {
    await loadPage({ signedIn: true, paired: "false" });
    expect(shown("connect")).toBe(true);
    expect(($("connect") as HTMLButtonElement).disabled).toBe(false);
    expect(shown("unpair")).toBe(false);
    expect(shown("pairstate")).toBe(false);
  });

  it("signed in, paired state unknown: asks GET /pair/status and applies the answer", async () => {
    await loadPage({ paired: "unknown", server: { "GET /pair/status": [{ status: 200, body: { paired: true } }] } });
    expect(requests()).toEqual(["GET /pair/status"]);
    expect(document.body.dataset.paired).toBe("true");
  });

  it("an unreadable pair status leaves the panel as it was", async () => {
    await loadPage({ paired: "unknown", server: { "GET /pair/status": [{ status: 500, body: {} }] } });
    expect(document.body.dataset.paired).toBe("unknown");
    expect(status()).toBe("");
  });

  it("signed out: amounts and Connect disabled, the Google button rendered, Sign out hidden", async () => {
    await loadPage({ signedIn: false, paired: "true" });
    expect(allAmountsDisabled()).toBe(true);
    expect(($("connect") as HTMLButtonElement).disabled).toBe(true);
    expect(document.body.dataset.paired).toBe("false");
    expect(renderButton).toHaveBeenCalledTimes(1);
    expect(shown("signin")).toBe(true);
    expect(shown("signout")).toBe(false);
    expect(shown("unpair")).toBe(false);
    expect(requests()).toEqual([]);
  });

  it("signed out and Google cannot load: says so", async () => {
    await loadPage({ signedIn: false, google: "fails-to-load" });
    expect(status()).toBe("Sign-in is unavailable — Google could not be reached. Reload to try again.");
  });

  it("signed out with no client id in the page: says it is misconfigured", async () => {
    await loadPage();
    document.head.querySelector("meta")!.remove();
    $("signout").click(); // signing out renders the Google button, which reads the client id
    await settle();
    expect(status()).toBe("Sign-in is unavailable — the page is misconfigured.");
  });
});

describe("signing in and out (DESIGN §2.2 amendment 2026-09-22)", () => {
  it("a Google credential is traded for a session once, then the page is signed in", async () => {
    await loadPage({ signedIn: false, server: { "GET /pair/status": [{ status: 200, body: { paired: false } }] } });
    googleCallback!({ credential: "google-id-token" });
    await settle();
    expect(requests()).toEqual(["POST /session", "GET /pair/status"]);
    expect(fetchSpy.mock.calls[0]![1].headers.authorization).toBe("Bearer google-id-token");
    expect(document.body.dataset.signedIn).toBe("true");
    expect(document.body.dataset.paired).toBe("false");
    expect(noAmountsDisabled()).toBe(true);
    expect(status()).toBe("Signed in.");
  });

  it("a refused session keeps the page signed out and shows why", async () => {
    await loadPage({ signedIn: false, server: { "POST /session": [{ status: 403, body: { error: "not allowed" } }] } });
    googleCallback!({ credential: "google-id-token" });
    await settle();
    expect(document.body.dataset.signedIn).toBe("false");
    expect(allAmountsDisabled()).toBe(true);
    expect(status()).toBe("Couldn't stay signed in: not allowed.");
  });

  it("a Google callback with no credential says sign-in failed and sends nothing", async () => {
    await loadPage({ signedIn: false });
    googleCallback!({});
    await settle();
    expect(requests()).toEqual([]);
    expect(status()).toBe("Sign-in failed.");
  });

  it("Sign out deletes the session and drops the page to signed out", async () => {
    await loadPage();
    $("signout").click();
    await settle();
    expect(requests()).toEqual(["DELETE /session"]);
    expect(document.body.dataset.signedIn).toBe("false");
    expect(allAmountsDisabled()).toBe(true);
    expect(renderButton).toHaveBeenCalled();
    expect(status()).toBe("Signed out.");
  });

  it("Sign out still signs out the page when the request fails", async () => {
    await loadPage({ server: { "DELETE /session": [new Error("offline")] } });
    $("signout").click();
    await settle();
    expect(document.body.dataset.signedIn).toBe("false");
    expect(status()).toBe("Signed out.");
  });

  it("a 401 on any call means the session is gone: signed out, and told to sign in again", async () => {
    await loadPage({ server: { "POST /grant": [{ status: 401, body: { error: "no session" } }] } });
    amount(15).click();
    await settle();
    expect(document.body.dataset.signedIn).toBe("false");
    expect(allAmountsDisabled()).toBe(true);
    expect(status()).toBe("Your sign-in has expired — sign in again.");
  });
});

describe("amount buttons (DESIGN §2.2 amendment 2026-09-23)", () => {
  it("asks before granting, naming the amount, then sends it", async () => {
    await loadPage();
    amount(30).click();
    expect(confirmSpy).toHaveBeenCalledWith("Add 30 minutes to the Mac?");
    await settle();
    expect(requests()).toEqual(["POST /grant"]);
    expect(JSON.parse(fetchSpy.mock.calls[0]![1].body)).toEqual({ minutes: 30 });
  });

  it("cancelling the confirmation sends nothing and leaves the buttons enabled", async () => {
    await loadPage();
    confirmSpy.mockReturnValue(false);
    amount(15).click();
    await settle();
    expect(requests()).toEqual([]);
    expect(noAmountsDisabled()).toBe(true);
  });

  it("a successful grant disables all three buttons and a further tap does nothing", async () => {
    await loadPage();
    amount(15).click();
    await settle();
    expect(status()).toBe("Added 15 minutes. Reload the page to add more.");
    expect(allAmountsDisabled()).toBe(true);
    amount(60).click();
    expect(confirmSpy).toHaveBeenCalledTimes(1);
    expect(requests()).toEqual(["POST /grant"]);
  });

  it("the buttons stay disabled after signing out and signing in again", async () => {
    await loadPage();
    amount(15).click();
    await settle();
    $("signout").click();
    await settle();
    googleCallback!({ credential: "google-id-token" });
    await settle();
    expect(document.body.dataset.signedIn).toBe("true");
    expect(allAmountsDisabled()).toBe(true);
  });

  it("the buttons are disabled while the grant is in flight, so a double tap sends one", async () => {
    let release!: () => void;
    await loadPage();
    fetchSpy.mockImplementationOnce(
      () => new Promise((res) => (release = () => res({ status: 201, json: async () => ({ minutes: 15 }) }))),
    );
    amount(15).click();
    expect(status()).toBe("Working…");
    expect(allAmountsDisabled()).toBe(true);
    amount(15).click();
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    release();
    await settle();
    expect(status()).toMatch(/^Added 15 minutes/);
  });

  it("a network failure re-enables the buttons for a retry", async () => {
    await loadPage({ server: { "POST /grant": [new Error("offline")] } });
    amount(15).click();
    await settle();
    expect(status()).toBe("Network error — nothing was changed.");
    expect(noAmountsDisabled()).toBe(true);
  });

  it("a refused grant shows the server's reason and re-enables the buttons", async () => {
    await loadPage({ server: { "POST /grant": [{ status: 500, body: { error: "boom" } }] } });
    amount(15).click();
    await settle();
    expect(status()).toBe("Couldn't add minutes: boom.");
    expect(noAmountsDisabled()).toBe(true);
  });
});

describe("connecting a Mac (DESIGN §2.4)", () => {
  it("Connect a Mac shows the pairing code", async () => {
    await loadPage({ paired: "false" });
    $("connect").click();
    await settle();
    expect(requests()).toEqual(["POST /pair/code"]);
    expect($("code").textContent).toBe("ABCD2345");
  });

  it("a refused code request shows the reason and no code", async () => {
    await loadPage({ paired: "false", server: { "POST /pair/code": [{ status: 500, body: { error: "boom" } }] } });
    $("connect").click();
    await settle();
    expect($("code").textContent).toBe("");
    expect(status()).toBe("Couldn't get a pairing code: boom.");
  });

  it("while the code is shown the page checks every 3 s and flips to paired by itself", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    await loadPage({
      paired: "false",
      server: { "GET /pair/status": [{ status: 200, body: { paired: false } }, { status: 200, body: { paired: true } }] },
    });
    $("connect").click();
    await settle();
    await vi.advanceTimersByTimeAsync(3000);
    await settle();
    expect(document.body.dataset.paired).toBe("false");
    expect($("code").textContent).toBe("ABCD2345");
    await vi.advanceTimersByTimeAsync(3000);
    await settle();
    expect(document.body.dataset.paired).toBe("true");
    expect($("code").textContent).toBe("");
    expect(status()).toBe("Mac paired.");
    const polls = requests().length;
    await vi.advanceTimersByTimeAsync(9000);
    expect(requests().length).toBe(polls); // stopped watching
  });

  it("the code is cleared when it expires, with a message to get a new one", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    await loadPage({
      paired: "false",
      server: {
        "POST /pair/code": [{ status: 200, body: { code: "ABCD2345", expiresInSeconds: 6 } }],
        "GET /pair/status": [{ status: 200, body: { paired: false } }],
      },
    });
    $("connect").click();
    await settle();
    await vi.advanceTimersByTimeAsync(9000);
    await settle();
    expect($("code").textContent).toBe("");
    expect(status()).toBe("The pairing code expired — get a new one.");
  });

  it("signing out stops the watch and clears the code", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    await loadPage({ paired: "false", server: { "GET /pair/status": [{ status: 200, body: { paired: false } }] } });
    $("connect").click();
    await settle();
    $("signout").click();
    await settle();
    expect($("code").textContent).toBe("");
    const before = requests().length;
    await vi.advanceTimersByTimeAsync(9000);
    expect(requests().length).toBe(before);
  });
});

describe("unpairing (DESIGN §2.4 amendment 2026-09-23)", () => {
  it("asks first; cancelling sends nothing and stays paired", async () => {
    await loadPage();
    confirmSpy.mockReturnValue(false);
    $("unpair").click();
    await settle();
    expect(confirmSpy).toHaveBeenCalledWith(
      "Unpair this Mac? It stops receiving minutes until you pair it again from its Settings.",
    );
    expect(requests()).toEqual([]);
    expect(document.body.dataset.paired).toBe("true");
  });

  it("confirmed, it unpairs and the panel shows Connect a Mac", async () => {
    await loadPage();
    $("unpair").click();
    await settle();
    expect(requests()).toEqual(["POST /pair/unpair"]);
    expect(document.body.dataset.paired).toBe("false");
    expect(shown("connect")).toBe(true);
    expect(shown("unpair")).toBe(false);
    expect(status()).toBe("Unpaired.");
  });

  it("a refused unpair shows the reason and stays paired", async () => {
    await loadPage({ server: { "POST /pair/unpair": [{ status: 403, body: { error: "not authorized" } }] } });
    $("unpair").click();
    await settle();
    expect(document.body.dataset.paired).toBe("true");
    expect(status()).toBe("Couldn't unpair: not authorized.");
  });
});

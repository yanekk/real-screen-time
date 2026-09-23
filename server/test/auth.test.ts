// The pure auth primitives (src/auth.ts): allowlist, device-token shape/hash, pairing-code mint
// and normalize. No network, no Google library — those are exercised only through the injected
// verifier in the handler tests.

import { describe, it, expect } from "vitest";
import {
  parseAllowlist,
  normalizeEmail,
  isAuthorized,
  mintDeviceToken,
  hashToken,
  looksLikeDeviceToken,
  mintPairingCode,
  normalizePairingCode,
} from "../src/auth.js";

describe("allowlist (the authorization, DESIGN §2.2)", () => {
  it("parses a comma list, trimming and lowercasing", () => {
    expect(parseAllowlist(" Parent@Example.com , mum@example.com ")).toEqual([
      "parent@example.com",
      "mum@example.com",
    ]);
  });

  it("ignores empty entries and a missing value", () => {
    expect(parseAllowlist("")).toEqual([]);
    expect(parseAllowlist(undefined)).toEqual([]);
    expect(parseAllowlist("a@b.com,, ,c@d.com")).toEqual(["a@b.com", "c@d.com"]);
  });

  it("authorizes only a normalized member; refuses others and the empty email", () => {
    const list = parseAllowlist("parent@example.com");
    expect(isAuthorized("Parent@Example.com", list)).toBe(true);
    expect(isAuthorized("stranger@example.com", list)).toBe(false);
    expect(isAuthorized("", list)).toBe(false);
    expect(isAuthorized(undefined, list)).toBe(false);
  });

  it("normalizeEmail is defensive about nullish input", () => {
    expect(normalizeEmail(undefined)).toBe("");
  });
});

describe("device tokens", () => {
  it("mints 64 lowercase hex chars and hashes stably", () => {
    const t = mintDeviceToken();
    expect(t).toMatch(/^[0-9a-f]{64}$/);
    expect(hashToken(t)).toBe(hashToken(t));
    expect(hashToken(t)).not.toBe(t); // the hash is stored, never the token
  });

  it("recognizes a device-token shape and rejects a JWT-shaped token", () => {
    expect(looksLikeDeviceToken(mintDeviceToken())).toBe(true);
    // A Google ID token is a JWT with dots — never device-shaped.
    expect(looksLikeDeviceToken("header.payload.signature")).toBe(false);
    expect(looksLikeDeviceToken("ABCDEF")).toBe(false);
    expect(looksLikeDeviceToken("")).toBe(false);
  });
});

describe("pairing codes", () => {
  it("mints an 8-char code from the unambiguous alphabet", () => {
    for (let i = 0; i < 50; i++) {
      const c = mintPairingCode();
      expect(c).toHaveLength(8);
      // No I, L, O, 0, 1 — nothing a human can misread between the web page and Settings.
      expect(c).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    }
  });

  it("normalizes a typed code: uppercases and drops separators and whitespace", () => {
    expect(normalizePairingCode("abcd-2345")).toBe("ABCD2345");
    expect(normalizePairingCode(" ab cd 23 45 ")).toBe("ABCD2345");
    expect(normalizePairingCode(undefined)).toBe("");
  });
});

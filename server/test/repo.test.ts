// The in-memory Repo is what every backend unit test runs against, so no test touches AWS
// (DESIGN §4). These prove the storage semantics the endpoints (T08) will rely on. The
// DynamoDB implementation is exercised only against the real table, by hand (DESIGN §5.1).

import { describe, it, expect } from "vitest";
import { InMemoryRepo, type Grant, type PairingCode } from "../src/repo.js";

const FAR_FUTURE = Math.floor(Date.now() / 1000) + 3600;

function grant(id: string, minutes = 30): Grant {
  return { id, minutes, issuedAt: new Date().toISOString(), ttl: FAR_FUTURE };
}

function code(c: string): PairingCode {
  return { code: c, ttl: FAR_FUTURE };
}

describe("InMemoryRepo", () => {
  it("round-trips a grant: put, list, delete", async () => {
    const repo = new InMemoryRepo();
    expect(await repo.listGrants()).toEqual([]);

    await repo.putGrant(grant("g1"));
    const listed = await repo.listGrants();
    expect(listed).toHaveLength(1);
    expect(listed[0]).toMatchObject({ id: "g1", minutes: 30 });

    await repo.deleteGrant("g1");
    expect(await repo.listGrants()).toEqual([]);
  });

  it("does not list a grant past its ttl", async () => {
    const repo = new InMemoryRepo();
    const past = Math.floor(Date.now() / 1000) - 1;
    await repo.putGrant({ id: "old", minutes: 15, issuedAt: new Date().toISOString(), ttl: past });
    expect(await repo.listGrants()).toEqual([]);
  });

  it("takePairingCode returns true once, then false (single-use)", async () => {
    const repo = new InMemoryRepo();
    await repo.putPairingCode(code("ABCD"));
    expect(await repo.takePairingCode("ABCD")).toBe(true);
    expect(await repo.takePairingCode("ABCD")).toBe(false);
  });

  it("takePairingCode is false for an unknown or expired code", async () => {
    const repo = new InMemoryRepo();
    expect(await repo.takePairingCode("NOPE")).toBe(false);
    const past = Math.floor(Date.now() / 1000) - 1;
    await repo.putPairingCode({ code: "STALE", ttl: past });
    expect(await repo.takePairingCode("STALE")).toBe(false);
  });

  it("holds at most one device token: a second put replaces the first (re-pair revokes)", async () => {
    const repo = new InMemoryRepo();
    const iso = new Date().toISOString();

    await repo.putDeviceToken({ tokenHash: "hash-A", issuedAt: iso });
    expect(await repo.hasDeviceToken("hash-A")).toBe(true);

    await repo.putDeviceToken({ tokenHash: "hash-B", issuedAt: iso });
    expect(await repo.hasDeviceToken("hash-B")).toBe(true);
    // The old token no longer validates — this is how re-pairing revokes the previous Mac.
    expect(await repo.hasDeviceToken("hash-A")).toBe(false);
  });

  it("hasDeviceToken is false before any pairing", async () => {
    const repo = new InMemoryRepo();
    expect(await repo.hasDeviceToken("anything")).toBe(false);
  });

  it("hasAnyDeviceToken tracks existence only, for any hash (GET /pair/status, T12)", async () => {
    const repo = new InMemoryRepo();
    expect(await repo.hasAnyDeviceToken()).toBe(false);

    await repo.putDeviceToken({ tokenHash: "hash-A", issuedAt: new Date().toISOString() });
    expect(await repo.hasAnyDeviceToken()).toBe(true);

    // A re-pair replaces the token but a Mac is still paired — existence does not change.
    await repo.putDeviceToken({ tokenHash: "hash-B", issuedAt: new Date().toISOString() });
    expect(await repo.hasAnyDeviceToken()).toBe(true);
  });

  it("deleteDeviceToken unpairs: no token validates and none exists (web Unpair)", async () => {
    const repo = new InMemoryRepo();
    await repo.putDeviceToken({ tokenHash: "hash-A", issuedAt: new Date().toISOString() });
    await repo.deleteDeviceToken();
    expect(await repo.hasDeviceToken("hash-A")).toBe(false);
    expect(await repo.hasAnyDeviceToken()).toBe(false);
    await repo.deleteDeviceToken(); // idempotent
  });

  it("round-trips a session; delete removes it (sign-out)", async () => {
    const repo = new InMemoryRepo();
    expect(await repo.getSession("hash-S")).toBeUndefined();

    await repo.putSession({ tokenHash: "hash-S", email: "p@example.com", ttl: FAR_FUTURE });
    expect(await repo.getSession("hash-S")).toMatchObject({ email: "p@example.com" });

    await repo.deleteSession("hash-S");
    expect(await repo.getSession("hash-S")).toBeUndefined();
  });

  it("holds many sessions independently (one per browser), unlike the single device token", async () => {
    const repo = new InMemoryRepo();
    await repo.putSession({ tokenHash: "hash-A", email: "p@example.com", ttl: FAR_FUTURE });
    await repo.putSession({ tokenHash: "hash-B", email: "p@example.com", ttl: FAR_FUTURE });
    // Adding a second does not revoke the first — both browsers stay signed in.
    expect(await repo.getSession("hash-A")).toBeDefined();
    expect(await repo.getSession("hash-B")).toBeDefined();
  });

  it("does not return a session past its ttl (fails closed)", async () => {
    const repo = new InMemoryRepo();
    const past = Math.floor(Date.now() / 1000) - 1;
    await repo.putSession({ tokenHash: "hash-old", email: "p@example.com", ttl: past });
    expect(await repo.getSession("hash-old")).toBeUndefined();
  });
});

// The data-access layer for the remote-grant backend (DESIGN §3.6).
//
// Everything the backend stores lives in ONE DynamoDB table keyed by `pk` (T00 pinned this
// shape on the parent's real account, FINDINGS 2026-09-22):
//
//   pk = "DEVICE_TOKEN"   the single active device token (a singleton row; overwrite = revoke)
//   pk = "GRANT#<id>"     one unconsumed grant
//   pk = "CODE#<code>"    one pairing code
//   pk = "SESSION#<hash>" one saved parent web session (many allowed, one per browser)
//
// Grants and codes carry a numeric `ttl` (epoch seconds) so DynamoDB self-expires them. That
// deletion lags by up to ~48h, so every read here also filters on `ttl > now` — the same
// belt-and-braces the T00 spike used and DESIGN §3.6 requires.
//
// The interface is what the endpoints (T08) talk to; two implementations satisfy it. The
// DynamoDB one runs on Lambda; the in-memory one is what the unit tests run against, so no
// test touches AWS.

import {
  DynamoDBClient,
} from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  DeleteCommand,
  ScanCommand,
} from "@aws-sdk/lib-dynamodb";

/** One grant the parent created. `id` is the dedupe key the Mac keys off (DESIGN §2.6). */
export interface Grant {
  id: string;
  minutes: number;
  issuedAt: string; // ISO-8601, no fractional seconds (the wire contract T03 pinned)
  ttl: number; // epoch seconds; drives DynamoDB self-expiry
}

/**
 * The single active device token, stored as a HASH of the token, never the token itself:
 * the table is the one place a leaked store would expose it, and a hash is useless to fetch
 * grants with. The endpoint hashes the presented token before asking `hasDeviceToken`.
 * There is at most one — a re-pair overwrites it, which is how re-pairing revokes (DESIGN §2.4).
 */
export interface DeviceToken {
  tokenHash: string;
  issuedAt: string; // ISO-8601
}

/** A short-lived, single-use pairing code (DESIGN §2.4). The code itself is the credential. */
export interface PairingCode {
  code: string;
  ttl: number; // epoch seconds
}

/**
 * A saved parent web session (DESIGN §2.2 amendment 2026-09-22), stored as a HASH of the cookie
 * token, never the token. Unlike the device token there can be several — one per browser the parent
 * signs in from — so each is its own row keyed by its hash. The `email` is the parent it belongs to
 * (returned on validation instead of re-verifying with Google); `ttl` self-expires it.
 */
export interface Session {
  tokenHash: string;
  email: string;
  ttl: number; // epoch seconds; drives DynamoDB self-expiry
}

export interface Repo {
  putGrant(g: Grant): Promise<void>;
  /** Unconsumed, unexpired grants. Expired-but-not-yet-deleted rows are filtered out. */
  listGrants(): Promise<Grant[]>;
  deleteGrant(id: string): Promise<void>;

  /** Replaces THE single active device token (DESIGN §2.4) — a re-pair supplants the old one. */
  putDeviceToken(t: DeviceToken): Promise<void>;
  /** True only for the current token's hash; a prior token's hash no longer validates. */
  hasDeviceToken(tokenHash: string): Promise<boolean>;
  /**
   * Whether ANY device token currently exists — the paired/not-paired read behind
   * `GET /pair/status` (T12). Exposes existence only, never the token or its hash, so it stays
   * inside the create-side gate and leaks nothing (DESIGN §2.3).
   */
  hasAnyDeviceToken(): Promise<boolean>;
  /**
   * Remove THE active device token — the web app's Unpair (DESIGN §2.4 amendment 2026-09-23). The
   * paired Mac's token then stops validating, exactly as a re-pair elsewhere would, and the Mac
   * surfaces "re-pair" on its next poll. A no-op when nothing is paired.
   */
  deleteDeviceToken(): Promise<void>;

  putPairingCode(c: PairingCode): Promise<void>;
  /** Single-use: if the code exists and is unexpired, remove it and return true; else false. */
  takePairingCode(code: string): Promise<boolean>;

  putSession(s: Session): Promise<void>;
  /** The session for this token hash if it exists and is unexpired; else undefined. */
  getSession(tokenHash: string): Promise<Session | undefined>;
  /** Remove a session by its token hash — sign-out. A no-op if it is already gone. */
  deleteSession(tokenHash: string): Promise<void>;
}

const DEVICE_TOKEN_PK = "DEVICE_TOKEN";
const grantPk = (id: string) => `GRANT#${id}`;
const codePk = (code: string) => `CODE#${code}`;
const sessionPk = (tokenHash: string) => `SESSION#${tokenHash}`;

/** Wall-clock epoch seconds. In `server/` (not RSTCore), so a real clock read is fine. */
function nowEpoch(): number {
  return Math.floor(Date.now() / 1000);
}

/**
 * The in-memory Repo. Everything lives in three maps; there is no lazy TTL deletion here, so
 * the reads filter on `ttl > now` to match the DynamoDB implementation exactly — the unit
 * tests must exercise the same semantics that deploy.
 */
export class InMemoryRepo implements Repo {
  private grants = new Map<string, Grant>();
  private deviceToken: DeviceToken | undefined;
  private codes = new Map<string, PairingCode>();
  private sessions = new Map<string, Session>();

  async putGrant(g: Grant): Promise<void> {
    this.grants.set(g.id, { ...g });
  }

  async listGrants(): Promise<Grant[]> {
    const now = nowEpoch();
    return [...this.grants.values()].filter((g) => g.ttl > now).map((g) => ({ ...g }));
  }

  async deleteGrant(id: string): Promise<void> {
    this.grants.delete(id);
  }

  async putDeviceToken(t: DeviceToken): Promise<void> {
    this.deviceToken = { ...t }; // overwrite: single active token (re-pair revokes)
  }

  async hasDeviceToken(tokenHash: string): Promise<boolean> {
    return this.deviceToken?.tokenHash === tokenHash;
  }

  async hasAnyDeviceToken(): Promise<boolean> {
    return this.deviceToken !== undefined;
  }

  async deleteDeviceToken(): Promise<void> {
    this.deviceToken = undefined;
  }

  async putPairingCode(c: PairingCode): Promise<void> {
    this.codes.set(c.code, { ...c });
  }

  async takePairingCode(code: string): Promise<boolean> {
    const c = this.codes.get(code);
    if (!c || c.ttl <= nowEpoch()) return false;
    this.codes.delete(code);
    return true;
  }

  async putSession(s: Session): Promise<void> {
    this.sessions.set(s.tokenHash, { ...s });
  }

  async getSession(tokenHash: string): Promise<Session | undefined> {
    const s = this.sessions.get(tokenHash);
    if (!s || s.ttl <= nowEpoch()) return undefined; // expired-but-not-deleted filtered, like grants
    return { ...s };
  }

  async deleteSession(tokenHash: string): Promise<void> {
    this.sessions.delete(tokenHash);
  }
}

/**
 * The DynamoDB-backed Repo used on Lambda. The AWS SDK v3 clients are provided by the
 * nodejs runtime (T00 FINDINGS 2026-09-22), so they are dev-only dependencies here and are
 * marked external in the esbuild bundle (template.yaml).
 */
export class DynamoRepo implements Repo {
  private readonly doc: DynamoDBDocumentClient;

  constructor(
    private readonly tableName: string,
    doc?: DynamoDBDocumentClient,
  ) {
    this.doc = doc ?? DynamoDBDocumentClient.from(new DynamoDBClient({}));
  }

  async putGrant(g: Grant): Promise<void> {
    await this.doc.send(
      new PutCommand({ TableName: this.tableName, Item: { pk: grantPk(g.id), ...g } }),
    );
  }

  async listGrants(): Promise<Grant[]> {
    const now = nowEpoch();
    // Scan the GRANT# partition. One family polling occasionally keeps this tiny; the ttl
    // filter drops rows DynamoDB has not lazily deleted yet (DESIGN §3.6).
    const res = await this.doc.send(
      new ScanCommand({
        TableName: this.tableName,
        FilterExpression: "begins_with(pk, :p) AND #ttl > :now",
        ExpressionAttributeNames: { "#ttl": "ttl" },
        ExpressionAttributeValues: { ":p": "GRANT#", ":now": now },
      }),
    );
    return (res.Items ?? []).map((it) => ({
      id: it["id"] as string,
      minutes: it["minutes"] as number,
      issuedAt: it["issuedAt"] as string,
      ttl: it["ttl"] as number,
    }));
  }

  async deleteGrant(id: string): Promise<void> {
    await this.doc.send(
      new DeleteCommand({ TableName: this.tableName, Key: { pk: grantPk(id) } }),
    );
  }

  async putDeviceToken(t: DeviceToken): Promise<void> {
    // Fixed key, so a PutCommand overwrites the previous token — the revoke-on-re-pair path.
    await this.doc.send(
      new PutCommand({
        TableName: this.tableName,
        Item: { pk: DEVICE_TOKEN_PK, ...t },
      }),
    );
  }

  async hasDeviceToken(tokenHash: string): Promise<boolean> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tableName, Key: { pk: DEVICE_TOKEN_PK } }),
    );
    return !!res.Item && res.Item["tokenHash"] === tokenHash;
  }

  async hasAnyDeviceToken(): Promise<boolean> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tableName, Key: { pk: DEVICE_TOKEN_PK } }),
    );
    return !!res.Item;
  }

  async deleteDeviceToken(): Promise<void> {
    await this.doc.send(
      new DeleteCommand({ TableName: this.tableName, Key: { pk: DEVICE_TOKEN_PK } }),
    );
  }

  async putPairingCode(c: PairingCode): Promise<void> {
    await this.doc.send(
      new PutCommand({ TableName: this.tableName, Item: { pk: codePk(c.code), ...c } }),
    );
  }

  async takePairingCode(code: string): Promise<boolean> {
    // Atomic single-use: delete only if the row still exists and is unexpired. A concurrent
    // second redemption hits the condition and fails, so a code is spent exactly once.
    try {
      await this.doc.send(
        new DeleteCommand({
          TableName: this.tableName,
          Key: { pk: codePk(code) },
          ConditionExpression: "attribute_exists(pk) AND #ttl > :now",
          ExpressionAttributeNames: { "#ttl": "ttl" },
          ExpressionAttributeValues: { ":now": nowEpoch() },
        }),
      );
      return true;
    } catch (e) {
      if (e instanceof Error && e.name === "ConditionalCheckFailedException") return false;
      throw e;
    }
  }

  async putSession(s: Session): Promise<void> {
    await this.doc.send(
      new PutCommand({ TableName: this.tableName, Item: { pk: sessionPk(s.tokenHash), ...s } }),
    );
  }

  async getSession(tokenHash: string): Promise<Session | undefined> {
    const res = await this.doc.send(
      new GetCommand({ TableName: this.tableName, Key: { pk: sessionPk(tokenHash) } }),
    );
    const it = res.Item;
    // Filter expired-but-not-yet-lazily-deleted rows here too, exactly as listGrants does.
    if (!it || (it["ttl"] as number) <= nowEpoch()) return undefined;
    return {
      tokenHash: it["tokenHash"] as string,
      email: it["email"] as string,
      ttl: it["ttl"] as number,
    };
  }

  async deleteSession(tokenHash: string): Promise<void> {
    await this.doc.send(
      new DeleteCommand({ TableName: this.tableName, Key: { pk: sessionPk(tokenHash) } }),
    );
  }
}

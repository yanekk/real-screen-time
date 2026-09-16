# T05 — Pre-publish secrets & private-data scan

**Phase:** 4 · **Depends on:** — · **Weight:** medium

## Goal

Before the repo goes public (T06), find everything in it that should not be seen by anyone.
Two kinds of thing: secrets (tokens, keys, credentials) whose exposure is a security problem,
and private/personal data (the admin username, an email address, the child's name, home paths,
account uids) whose exposure is a privacy problem for a family. A secret pushed to a public
repo cannot be recalled, so this runs and its findings are settled with the user before a
single commit is published.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §5.2 (the scan is the seatbelt on publishing) and the §7 decision to
gate going public behind it.

## Files

None shipped. This task produces a report to the user and, if they decide to redact, the edits
they choose — but the edits are their decision, not this task's to make unilaterally.

## What to scan

- **Working tree and git history both.** History matters because publishing pushes it all; a
  secret in an old commit is as exposed as one in the tree.
- **Secrets:** API tokens, private keys, `.env`-style files, anything key-shaped. There should
  be none (the app has no third-party services), so any hit is notable.
- **Private data, known to be present:** `admin` (admin username, in paths and
  docs), the git-config email, the child's name, home-directory paths, uids 501/502, and any
  PIN or ledger data that might have been committed by accident.

Use a scanner plus a grep sweep; a fresh-eyes read of what a stranger would learn from the
repo is part of it, not just pattern matching.

## Tests

Not a code task; `make test` is unaffected. The "test" is the report and the user's decisions.

## Done when

- [ ] Working tree and full git history have been scanned for secrets and for the private-data
      list above, and the findings are written up for the user.
- [ ] Each finding is put to the user as redact / accept-as-public, one call, with a
      recommendation — this is a `what`, theirs to decide (some, like the child's name in the
      design docs, they may accept; a stray secret they will not).
- [ ] Their decisions are recorded in `FINDINGS.md` with the date, and any redaction they
      chose is applied. Nothing is published in this task.

## Needs a person

The verdict on what counts as too-private-to-publish is the user's, not the session's. The
implementing session presents the findings and waits; it does not decide to redact or to
accept on the user's behalf, and it does not publish.

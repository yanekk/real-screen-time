# Releasing Real Screen Time

How to cut a new release the app's **Update** button can find. The updater fetches
`https://api.github.com/repos/{owner}/{repo}/releases/latest`, compares its `tag_name`
against `AppVersion.current`, and downloads the release asset named `RealScreenTime.app.zip`
(selected by `.app.zip` suffix). Everything below serves that one contract.

## Cutting a release

1. **Bump the version.** Edit the single constant `AppVersion.current` in
   `Sources/RSTCore/AppVersion.swift` (e.g. `"1.0.1"` → `"1.0.2"`). Nothing else carries a
   version number: `make bundle` stamps this value into `CFBundleShortVersionString`, so the
   shipped app can never disagree with the code (DESIGN §2.1).

2. **Package the asset.**

   ```bash
   aws sso login --profile admin   # make bundle reads the backend address from Parameter Store
   make release
   ```

   This assembles and ad-hoc-signs `dist/RealScreenTime.app`, then zips it to
   `dist/RealScreenTime.app.zip` with `ditto -c -k --keepParent`. `--keepParent` keeps the
   `.app` at the archive root (the updater's `firstAppBundle` looks only at the top level);
   `ditto` preserves the code signature that a plain `zip` would corrupt. The target proves
   the round-trip itself — it unpacks the zip and re-runs `codesign --verify`, failing loudly
   if the signature did not survive — so a green `make release` is your evidence the asset
   will launch after download.

3. **Tag and publish.** Tag the commit `vX.Y.Z` (matching `AppVersion.current`; a leading
   `v` is tolerated by the comparison). Create the GitHub release on that tag and attach
   `dist/RealScreenTime.app.zip` — the asset name must stay exactly that.

   ```bash
   gh release create vX.Y.Z dist/RealScreenTime.app.zip \
     --repo {owner}/{repo} --title "vX.Y.Z" --notes "…"
   ```

4. **Confirm the updater can see it.**

   ```bash
   curl -s https://api.github.com/repos/{owner}/{repo}/releases/latest \
     | jq '{tag_name, asset: .assets[].name}'
   ```

   Expect `tag_name: "vX.Y.Z"` and an asset named `RealScreenTime.app.zip`. If both are
   right, the installed app's Update button will offer the upgrade.

## The repo constants

The updater's target repo is set once, in `Sources/RSTApp/Updater.swift` — `repoOwner` and
`repoName`. While either is empty the Update button reports "not set up yet" rather than
firing a request at a nonexistent path. These are wired to the real repo at first publish
(T06) and change only if the repo moves.

## The public repo is a detached snapshot

The public repo (`yanekk/real-screen-time`) was created as a *fresh initial commit* — a
single historyless snapshot of the cleaned tree — so the private full-history working repo
on this machine has **no remote and shares no history with it**. `spike/`, `.claude/`, `.pir/` (pir's run rules) and,
from v1.1.0, `plans/` are not published: the plan docs name the family and the admin account
(v1.0.1 shipped them with the admin home path scrubbed; v1.1.0 dropped them instead). Two
consequences for the next release:

- Cut it by cloning the public repo and committing the new version there (or re-snapshotting
  this tree the way T06 did), not by adding a remote to this working repo — pushing this
  repo would publish the whole private history the fresh commit exists to avoid.
- Keep the same exclusions, or the private data comes back. Before pushing, grep the snapshot
  case-insensitively for the admin username, the family's names, the backend domain, the AWS
  account id and the parent's email; any hit stops the release.

## The one irreversible step

Making the repo public and publishing a release cannot be truly undone — deleting the repo
does not un-see what was pushed, and the git history goes public with it. The first release
(T06) therefore stops for an explicit go and settles the pre-publish scan (T05) first,
including whether to publish the whole history or a fresh initial commit. Later releases into
the already-public repo are routine.

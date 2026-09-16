# T06 — Public repo + release pipeline, and publish 1.0.1

**Phase:** 4 · **Depends on:** T01, T02, T04, T05 · **Weight:** medium

## Goal

Make v1.0.1 a public GitHub release the Update button can reach. Add the tooling to build and
package the release asset, create the public repo, push, and publish the `v1.0.1` release with
the assembled app attached. This is the one outward, near-irreversible step in the plan, so it
depends on the features actually being in the build (T02, T04), the version being right (T01),
and the pre-publish scan being settled (T05).

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.3 (the release the updater fetches) and §5 (the repo that did not
exist before this release).

## Files

- `Makefile` (changed) — a `release` (or `dist-zip`) target that builds the bundle and zips it
  as `RealScreenTime.app.zip`, the exact asset name T03/T04 expect. Use `ditto -c -k
  --keepParent` so the zip preserves the bundle and its signature.
- Wire the repo owner/name into `Updater.swift`'s constants (T04 left them to be set here, when
  the repo is named with the user).
- A short `RELEASING.md` (or a section in the plan) documenting the steps to cut a future
  release: bump `AppVersion.current`, `make release`, tag `vX.Y.Z`, create the GitHub release,
  attach the zip.

## Steps, in order

1. Confirm with the user the repo owner and name (theirs to choose — it is the public identity
   of the app) and whether the whole current history is published or a fresh initial commit.
2. Build and zip the release asset; confirm the zip unpacks to a bundle `codesign --verify`
   accepts (this is what T04 validates on download).
3. **Get the user's explicit go**, T05 having been settled, then create the public repo and
   push.
4. Publish the `v1.0.1` release with the zip attached.
5. Verify the app can now fetch it: `curl -s https://api.github.com/repos/{owner}/{repo}/releases/latest`
   returns `tag_name: v1.0.1` and the `.app.zip` asset URL.

## Tests

Not a code task in the `make test` sense; the Makefile target is verified by running it and
inspecting the zip. The release itself is verified by the `curl` in step 5 and, end to end, by
T04's hand-verification against a later throwaway 1.0.2.

## Done when

- [ ] `make release` produces `RealScreenTime.app.zip` that unpacks to a valid signed bundle.
- [ ] The public repo exists, with the user's explicit go and after T05, and `v1.0.1` is
      published with the asset attached.
- [ ] `releases/latest` returns `v1.0.1` and the asset URL — the updater has something to find.
- [ ] The release process is written down for next time.

## Needs a person

Publishing is irreversible in the way that matters: a public repo and a public release cannot
be truly unpublished, and the history goes with it. This step stops for the user's explicit go
even though the plan implied it — the way back is "delete the repo, but assume anything pushed
was seen." The session names the repo with the user, confirms T05 is settled, gets the go, and
only then publishes. Record the go and the published URL in `FINDINGS.md` with the date.

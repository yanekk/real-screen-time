# Real Screen Time — build, test and bundle assembly.
#
# There is no Xcode on this machine: Command Line Tools only. So `swift build` plus this
# file is the entire toolchain, and `bundle` assembles the .app layout by hand. If a target
# here starts wanting an .xcodeproj, the answer is another target here.

APP_NAME    := RealScreenTime
BUNDLE      := dist/$(APP_NAME).app
CONTENTS    := $(BUNDLE)/Contents
CONFIG      := release
# Lazy (`=`, not `:=`) on purpose: `:=` would shell out to SwiftPM while make parses the
# file, so every `make test` and `make clean` paid for a release-config path lookup it
# never used. This way only `bundle` asks.
BUILT_BIN    = $(shell swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)
INSTALL_DIR := /Applications

# The backend address the app talks to is deployment-specific, so it is not in the repo
# (2026-09-23): `make bundle` reads the web app's domain from SSM Parameter Store and stamps
# https://<domain> into Info.plist as RSTRemoteEndpoint (RemoteClient.productionEndpoint). It
# needs the admin AWS profile signed in (`aws sso login --profile admin`). Pass
# REMOTE_ENDPOINT=https://... to bundle against another backend without AWS.
REMOTE_ENDPOINT    ?=
REMOTE_AWS_PROFILE ?= admin
REMOTE_DOMAIN_PARAM := /real-screen-time/custom-domain-name

# The version stamped into the bundle plist, read from the one constant in RSTCore so the
# assembled app can never disagree with the code (DESIGN §2.1). Lazy (`=`) so only `bundle`
# pays the grep, matching BUILT_BIN above. Extracts the quoted value from the line
#   public static let current: String = "1.0.1"
APP_VERSION   = $(shell sed -n 's/.*current: String = "\(.*\)".*/\1/p' Sources/RSTCore/AppVersion.swift)

# Swift Testing on a machine with no Xcode.
#
# XCTest.framework ships with Xcode and is simply absent here, so the project uses Swift
# Testing (`import Testing`) throughout. CLT does ship Testing.framework — but SwiftPM does
# not put it on the search or runtime paths, so tests need three things the command line
# has to supply: -F to find the module, and rpaths to Testing.framework and to
# lib_TestingInterop.dylib, which Testing itself dlopens.
#
# These must be global (`-Xswiftc`), not settings on the test target. SwiftPM generates its
# own runner guarded by `#if canImport(Testing)`; if only the test target can see the
# framework, that guard compiles to nothing and `swift test` reports success having run
# **zero tests**. Bare `swift test` therefore fails to build here on purpose — a loud
# failure telling you to use `make test` beats a green run that tested nothing.
CLT_DEVELOPER  := /Library/Developer/CommandLineTools/Library/Developer
CLT_FRAMEWORKS := $(CLT_DEVELOPER)/Frameworks
CLT_INTEROP    := $(CLT_DEVELOPER)/usr/lib
TEST_FLAGS     := -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
                  -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
                  -Xlinker -rpath -Xlinker $(CLT_INTEROP)

# -q on purpose: every `make test` is read back into an agent's context, and Swift
# Testing's default reporter prints one "Test … passed" line per test — 375 of them, ~21 500
# tokens (o200k_base) of pure noise on a green run whose only signal is the exit code. `-q`
# ("only include error output") collapses a passing run to the four-line summary (~50 tokens,
# a 99.8% cut) while a failure still prints in full: file:line, the expanded #expect values,
# and a non-zero exit. Verified 2026-08-30 — see plans/initial-build/FINDINGS.md.
#
# Colour: Swift Testing emits no ANSI on a green run when stdout is not a TTY (as it is
# whenever the output is captured), so the shell's FORCE_COLOR=3 does not reach it and there
# is nothing to strip. The ✔/✘ marks are UTF-8 glyphs, not colour codes.
TEST_QUIET     := -q

.PHONY: all build test server-test seatbelt watchdog ui-gate bundle release install clean

all: build

build:
	swift build

test:
	swift test $(TEST_FLAGS) $(TEST_QUIET)

## The backend suite (plan remote-grant, DESIGN §4/§5). A separate toolchain from the Swift
## app: vitest under server/, headless, no AWS. Colour is forced off in the command itself:
## NO_COLOR=1 is what actually holds, because `npm` re-injects FORCE_COLOR for the script it
## runs and would override a bare FORCE_COLOR=0 (verified 2026-09-22 — the run came out
## coloured); NO_COLOR is respected by vitest's colour library and npm leaves it alone. The
## `test` script is `vitest run`, so the suite exits with a code instead of watching. The
## default reporter gives one summary line per file on green and full detail on any failure.
## `npm --silent` drops npm's own banner and the noisy "npm ERR!" epilogue on a failing run,
## leaving just vitest's output. Turn per-test detail back on with
## `npm test -- --reporter=verbose` (see server/README.md).
server-test:
	cd server && NO_COLOR=1 FORCE_COLOR=0 npm test --silent

## Prove the cover's release works — without ever putting a cover up.
##
## The one thing in this app that must never be wrong is the thing that gives the screen
## back, and T00 proved that testing it *by covering the screen* is how a machine ends up
## power-cycled (2026-08-21). `RST_SEATBELT_SELFTEST=1` runs the real watcher thread, armed
## the real way, with no window and no NSApplication: the process must exit on its own, and
## it must not exit early. Safe to run as often as you like.
SEATBELT_SECONDS := 3
## Limit + the watcher's 0.25s poll + `Seatbelt.releaseGrace` (2s) is ~5.25s, which the
## whole-second polling below reads as 6. The slack is the headroom above that on a loaded
## machine — raised from 6 at T12, when the graceful release stage was restored and the
## expected time stopped being the limit itself.
SEATBELT_SLACK   := 9
## **The floor is what makes the graceful stage a test rather than an observation.** T12
## restored the two-stage release — ask the main thread, wait `releaseGrace`, exit anyway —
## and left the floor at the limit, so deleting the ask and its wait would have exited at
## ~3.25s and still printed `ok`. Limit + grace is 5s; one second under the 6 this really
## measures, which is headroom for the poll without letting a gutted grace through.
SEATBELT_FLOOR   := 5

seatbelt: build
	@bin="$$(swift build --show-bin-path)/$(APP_NAME)"; \
	dir="$$(mktemp -d)"; \
	RST_SEATBELT_SELFTEST=1 RST_MAX_COVER_SECONDS=$(SEATBELT_SECONDS) RST_DATA_DIR="$$dir" \
	  "$$bin" >/dev/null & \
	pid=$$!; waited=0; \
	while kill -0 $$pid 2>/dev/null; do \
	  sleep 1; waited=$$((waited + 1)); \
	  if [ $$waited -gt $(SEATBELT_SLACK) ]; then \
	    kill -9 $$pid; rm -rf "$$dir"; \
	    echo "FAIL: still running after $$waited s — the seatbelt did not fire"; exit 1; \
	  fi; \
	done; \
	rm -rf "$$dir"; \
	if [ $$waited -lt $(SEATBELT_FLOOR) ]; then \
	  echo "FAIL: exited after $$waited s — expected at least $(SEATBELT_FLOOR) s" \
	       "($(SEATBELT_SECONDS) s limit plus the 2 s release grace); either it fired early" \
	       "or the graceful release stage is gone"; exit 1; \
	fi; \
	echo "seatbelt: exited after $$waited s, limit $(SEATBELT_SECONDS) s + 2 s grace — ok"

## Prove the hang watchdog works — without hanging a real app in front of a real screen.
##
## `make seatbelt`'s twin, and the only evidence a session can produce on its own for the
## one claim `make test` cannot reach: that the watcher thread outlives a main thread which
## has stopped answering. `RST_WATCHDOG_SELFTEST=1` says a cover is up — exactly what
## `CoverController` says as the first window goes in — and then parks the main thread for
## ever, with no window and no NSApplication. The process must end itself, and it must have
## written `watchdog_exit` before it did. Safe to run as often as you like.
WATCHDOG_SECONDS := 3
## Limit plus the watcher's 1 s poll is ~4 s; the rest is headroom on a loaded machine.
WATCHDOG_SLACK   := 9
## **The floor is what makes the threshold a test rather than an observation** (the T12
## seatbelt lesson, 2026-08-24). Without it a watchdog that ignored `stallSeconds` and fired
## on its first poll would exit after a second and still print `ok`.
WATCHDOG_FLOOR   := 3

watchdog: build
	@bin="$$(swift build --show-bin-path)/$(APP_NAME)"; \
	dir="$$(mktemp -d)"; \
	RST_WATCHDOG_SELFTEST=1 RST_WATCHDOG_SECONDS=$(WATCHDOG_SECONDS) RST_DATA_DIR="$$dir" \
	  "$$bin" >/dev/null & \
	pid=$$!; waited=0; \
	while kill -0 $$pid 2>/dev/null; do \
	  sleep 1; waited=$$((waited + 1)); \
	  if [ $$waited -gt $(WATCHDOG_SLACK) ]; then \
	    kill -9 $$pid; rm -rf "$$dir"; \
	    echo "FAIL: still running after $$waited s — the watchdog did not fire"; exit 1; \
	  fi; \
	done; \
	if [ $$waited -lt $(WATCHDOG_FLOOR) ]; then \
	  rm -rf "$$dir"; \
	  echo "FAIL: exited after $$waited s — expected at least $(WATCHDOG_SECONDS) s;" \
	       "the stall threshold is not being honoured"; exit 1; \
	fi; \
	if ! grep -q '"type":"watchdog_exit"' "$$dir/events.jsonl" 2>/dev/null; then \
	  rm -rf "$$dir"; \
	  echo "FAIL: exited after $$waited s but wrote no watchdog_exit event —" \
	       "the line has to be written from the watcher thread, before it leaves"; exit 1; \
	fi; \
	line="$$(grep '"type":"watchdog_exit"' "$$dir/events.jsonl")"; \
	rm -rf "$$dir"; \
	echo "watchdog: exited after $$waited s, threshold $(WATCHDOG_SECONDS) s — ok"; \
	echo "  $$line"

## Tier 2 — the real-click gate (plan headed-and-e2e-tests, T07).
##
## Builds the app and the driver, then runs the driver against a boxed, enforcing, seatbelted
## launch with a scratch RST_DATA_DIR the driver creates per scenario. It drives the real
## launched app's cover with genuine clicks and keystrokes through the Accessibility system and
## asserts from events.jsonl — the one thing `make test`'s in-memory Tier 1 suite cannot reach.
##
## NOT part of `make test`: it needs a one-time Accessibility grant and drives a real (boxed)
## window. On the first run the driver is untrusted; it prints exactly which binary to grant and
## exits without launching anything. Grant that binary in System Settings, then run this again.
##
## A debug build on purpose: it is faster to build and the driver forces RST_ENFORCE=1, so debug
## still covers. Box mode (RST_COVER_FRAME, set by the driver) withholds the kiosk lockdown, so
## this can never lock the machine; RST_MAX_COVER_SECONDS is the backstop if a click misses.
ui-gate: build
	@bin="$$(swift build --show-bin-path)"; \
	"$$bin/RSTUIDriver" "$$bin/$(APP_NAME)"

## Assemble dist/RealScreenTime.app by hand and ad-hoc sign it.
## Release configuration on purpose: the installed app enforces by default, while
## `swift run` (debug) observes. See CLAUDE.md, "Enforcement is opt-in in debug builds".
bundle:
	swift build -c $(CONFIG)
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	# Stamp the real version over the placeholder in the committed plist, from the RSTCore
	# constant, so the shipped app's CFBundleShortVersionString always matches the code.
	@test -n "$(APP_VERSION)" || { echo "could not read AppVersion.current"; exit 1; }
	plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" $(CONTENTS)/Info.plist
	@endpoint="$(REMOTE_ENDPOINT)"; \
	if [ -z "$$endpoint" ]; then \
	  domain=$$(aws ssm get-parameter --profile $(REMOTE_AWS_PROFILE) --region eu-central-1 \
	    --name $(REMOTE_DOMAIN_PARAM) --query Parameter.Value --output text) || { \
	    echo "make bundle: could not read $(REMOTE_DOMAIN_PARAM) from Parameter Store."; \
	    echo "Sign in first: aws sso login --profile $(REMOTE_AWS_PROFILE)"; exit 1; }; \
	  endpoint="https://$$domain"; \
	fi; \
	plutil -insert RSTRemoteEndpoint -string "$$endpoint" $(CONTENTS)/Info.plist; \
	echo "backend endpoint: $$endpoint"
	cp $(BUILT_BIN) $(CONTENTS)/MacOS/$(APP_NAME)
	# Copy the tree, then drop the plist that belongs one level up in Contents/. A
	# `find -exec cp` would flatten any subdirectory — fine today with one file in there,
	# silently wrong the first time a resource arrives inside a folder.
	cp -R Resources/ $(CONTENTS)/Resources/
	rm -f $(CONTENTS)/Resources/Info.plist
	# Ad-hoc is correct here: the app never leaves these two machines, so a Developer ID
	# buys nothing. --deep is harmless on a bundle with no nested code.
	codesign --force --deep --sign - $(BUNDLE)
	codesign --verify --verbose=1 $(BUNDLE)
	@echo "built $(BUNDLE)"

## Package the assembled bundle as RealScreenTime.app.zip — the exact release-asset name the
## updater downloads (T03 selects it by `.app.zip` suffix, T04 unpacks it). Two things about
## the zipper are load-bearing:
##   `--keepParent` puts the .app directory itself at the archive root, so T04's
##   `firstAppBundle` — which looks only at the unzip top level, not nested — finds it
##   (FINDINGS, 2026-09-15). A zip made without it unpacks to Contents/… and T04 reports
##   "didn't contain the app".
##   `ditto` preserves the code signature; a plain `zip` mangles the extended attributes the
##   signature lives in, and the downloaded app fails `codesign --verify` at launch — which
##   no test on this machine would catch, because the break only shows after a round-trip
##   through a real zip. So the target proves the round-trip itself: unpack to a scratch dir
##   and re-verify, and fail loudly if the signature did not survive.
RELEASE_ZIP := dist/$(APP_NAME).app.zip

release: bundle
	rm -f $(RELEASE_ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(RELEASE_ZIP)
	@scratch="$$(mktemp -d)"; \
	ditto -x -k $(RELEASE_ZIP) "$$scratch"; \
	if ! codesign --verify --verbose=1 "$$scratch/$(APP_NAME).app"; then \
	  rm -rf "$$scratch"; \
	  echo "FAIL: the unpacked bundle failed codesign --verify — the zip did not preserve the signature"; \
	  exit 1; \
	fi; \
	rm -rf "$$scratch"; \
	echo "built $(RELEASE_ZIP) — unpacks to a bundle codesign --verify accepts"

install: bundle
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "installed $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf dist

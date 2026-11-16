# 7elewen — agent navigation

macOS menu-bar app (Swift, AppKit host + SwiftUI panel). Xcode project `7elewen.xcodeproj`, scheme `7elewen`, sources in `7elewen/`.

## Build & verify

`xcodebuild -project 7elewen.xcodeproj -scheme 7elewen -configuration Debug build CODE_SIGNING_ALLOWED=NO`

The build must succeed **with zero warnings**; the `pre-push` hook enforces this.

## Guardrails

- `scripts/security-audit.sh .` — must exit 0 (no CRITICAL/HIGH). Authoritative secrets / subprocess / sudoers audit; do not substitute ad-hoc `grep` sweeps.
- Hooks live in `scripts/githooks/` (wired via `git config core.hooksPath`); bypass a single push with `git push --no-verify`.

## Environment gotcha (verified on macOS 27.2)

`os_log` / `Logger` output is invisible from both Xcode's console and `log stream` on this machine. Use `print()` when you need runtime output to be visible.

## Releases

Release flow, DMG naming and release-note conventions live in the `xcode-release` skill (`.agents/skills/XCode Release/`). Last: v0.4.0 → `7elewen-macOS-v040.dmg`, notes in `private/RELEASE_NOTES_v<ver>.md` (gitignored).
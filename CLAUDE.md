# CLAUDE.md

## Commands

```sh
swift build                 # → .build/debug/lw
swift build -c release
swift test                  # swift-testing, not XCTest
swift test --filter 'LoetiWayKitTests.Access plan'
```

In an Asylum container there is no Swift toolchain: build and test through the `xcodebuild` host MCP server (workflow `swift-package`, see `.xcodebuildmcp/config.yaml`).

## Architecture

`LoetiWayKit` holds all logic; `LoetiWayCLI` is ArgumentParser wiring and printing only, without tests. New behaviour belongs in the kit.

- `PassCLI` is the only place that knows pass-cli's arguments and JSON. The shapes come from pass-cli's source (`pass-cli/src/commands/agent`, `pass/src/personal_access_token`), not from the docs. `list-access` is internally tagged by `type`; a role is `"Viewer"` or `{"Custom": …}`.
- Everything goes through `CommandRunner`; tests use `FakeRunner`. Never run the real pass-cli in tests.
- `AccessPlan` only manages whole-vault grants. Item and folder grants are reported, never revoked.

## Rules

- Secrets go to pass-cli via stdin (`item create note --from-template -`), never as arguments, and never into error messages (don't echo pass-cli JSON on decode errors).
- Store a new token before deleting the old note. After `agent renew` the old token is already invalid, so a failed store must show the token once (`AppContext.storeToken`).
- The token vault must never be granted to an agent; `CustomerConfig.validate` enforces it.
- Vault names (`VaultNaming`): only `agent-…` vaults may be granted, the token vault is `lw-…`, everything else is private. Both prefixes are fixed, not configurable.
- Managing agents needs the user's account session; `ensureUserSession` refuses token sessions. The session is shared by every process of the macOS user, so commands that change something end it via `AppContext.endSession` (unless `--keep-login`).
- User-facing text is German (Swiss spelling, no ß), code and comments English. Metric units, dates as dd.MM.yyyy.

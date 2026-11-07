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
- GitHub PATs exist per customer (`github` in `.loeti-way.yaml`) and optionally per project (`.loeti-way-project.yaml`, resolved against the customer in `ProjectConfig`). Code that handles a PAT works on a `GitHubTarget`. Inside a broken project config never fall back to the customer's PAT. A project file is agent-writable: nothing in it chooses its note title (always `<customer> <folder name> GitHub PAT`; shared titles fail for every project involved), and `CustomerLocator.ensureUnclaimed` checks all customers before a note is read or written.
- `AccessPlan` only manages whole-vault grants. Item and folder grants are reported, never revoked.
- pass-cli logins (`SessionStore`): every call runs with its own `PROTON_PASS_SESSION_DIR`; pass-cli's default session stays empty. `host` (host agent, viewer on the token vault only) and `agent-<customer>` stay logged in; the user's account only inside `withAccount`, deleted afterwards. `ProcessRunner` strips inherited `PROTON_PASS_*`.
- A `.loeti-way.yaml` may be agent-written. `CustomerRegistry` (`~/.config/loeti-way/customers.yaml`, written only by `lw apply` after confirmation) binds folder, customer, agent, notes, vaults and env; `lw env` and every command except `apply` refuse configs that aren't registered as they are. After every agent login `SessionStore` checks the agent's name and fails closed if it is missing.
- `env:` values are exported on the host only as `LW_ENV_<NAME>` (Asylum maps them), never under the real name.
- `lw env` (`EnvExport`) is what `.envrc` runs: host agent reads the GitHub PAT, the customer's agent reads `env:` values. Never fails, unsets what it can't read. No pass-cli and no Proton token in Asylum containers.

## Rules

- Secrets go to pass-cli via stdin (`item create note --from-template -`) or the environment (`PROTON_PASS_PERSONAL_ACCESS_TOKEN` for `login`), never as arguments, and never into error messages (don't echo pass-cli JSON on decode errors).
- Store a new token before deleting the old note. After `agent renew` the old token is already invalid, so a failed store must show the token once (`AppContext.storeToken`).
- The token vault is never granted to a customer agent (`CustomerConfig.validate`), only to the host agent as viewer (`lw host --setup`). `env:` references must point into the customer's own `proton.vaults`; reserved variable names are refused (`EnvNaming`).
- `host-token` is created with mode 0600 via `open()` and refused when others can read it.
- Vault names (`VaultNaming`): only `agent-…` vaults may be granted, the token vault is `lw-…`, everything else is private. Both prefixes are fixed, not configurable.
- Managing agents needs the user's account: `AppContext.withAccount` (browser login in its own session dir, logout and delete afterwards). Keep the account window short, e.g. `lw github` only logs in to store.
- User-facing text is German (Swiss spelling, no ß), code and comments English. Metric units, dates as dd.MM.yyyy.

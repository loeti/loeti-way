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
- The token vault (`lw-tokens`) holds only Proton agent tokens. Provider tokens (`TokenKind`, `Tokens.swift`; today only `github`) live in `agent-<customer>` or, for a project with `vault: own`, in `agent-<customer>-<folder>`, as a secure note with the provider's fixed `itemTitle`. Both vault names are derived, never configured. Config: `tokens:` (`TokenSection`, unknown providers refused); the old `github:` key is refused with a hint. Code that handles a provider token works on a `TokenTarget`. A new provider: case in `TokenKind`, settings in `ProviderSettings`/`TokenSection`, optionally `lw token <provider>` and a check in `StatusCollector.tokenLine`.
- What a folder exports (`LoadedCustomer.exports(for:)`): the customer's tokens and `env`, the project's own tokens replace those of the same provider, its `env` adds or replaces by variable. Inside a broken or unregistered project nothing, never a fallback to the customer. Own tokens require `vault: own`, and that vault must be in the customer's `proton.vaults`. Folder names that give the same vault fail for every project involved.
- `AccessPlan` only manages whole-vault grants. Item and folder grants are reported, never revoked.
- pass-cli logins (`SessionStore`): every call runs with its own `PROTON_PASS_SESSION_DIR`; pass-cli's default session stays empty. `host` (host agent, viewer on the token vault only, reads agent tokens so a customer's agent can log in: `SessionStore.customerAgent`) and `agent-<customer>` (reads all tokens and `env` values) stay logged in; the user's account only inside `withAccount`, deleted afterwards. `ProcessRunner` strips inherited `PROTON_PASS_*`.
- A `.loeti-way.yaml` or `.loeti-way-project.yaml` may be agent-written. `CustomerRegistry` (`~/.config/loeti-way/customers.yaml`, written only by `lw apply` after confirmation) binds folder, customer, agent, agent-token note, vaults and every export (variable → reference), per project too; `lw env` and every command except `apply` refuse configs that aren't registered as they are (`verify`, `verify(_:project:)`). A vault a customer reads exports from may not be granted to another registered customer. After every agent login `SessionStore` checks the agent's name and fails closed if it is missing.
- Tokens and `env:` values are exported on the host only as `LW_ENV_<NAME>` (Asylum maps them), never under the real name.
- `lw status` (`StatusCollector`) reads nothing an unconfirmed customer or project config names. It works without the account: host agent for agent tokens, the customer's agent for tokens and `env` items (listing, values only for checks), GitHub for expiry and repo coverage (`canAccess`, 404 = not covered), the file system for `.envrc` and git repos. Grants and fresh agent expiry only with `--konto`; `withAccount` records expiry dates in `agents.yaml` (`AgentExpiries`).
- `lw env` (`EnvExport`) is what `.envrc` runs: the customer's agent reads every value, the host agent is only needed for that agent's login. Never fails, unsets what it can't read. No pass-cli and no Proton token in Asylum containers.

## Rules

- Secrets go to pass-cli via stdin (`item create note --from-template -`) or the environment (`PROTON_PASS_PERSONAL_ACCESS_TOKEN` for `login`), never as arguments, and never into error messages (don't echo pass-cli JSON on decode errors).
- Store a new token before deleting the old note. After `agent renew` the old token is already invalid, so a failed store must show the token once (`AppContext.storeToken`).
- The token vault is never granted to a customer agent (`CustomerConfig.validate`), only to the host agent as viewer (`lw host --setup`). `env:` references must point into an `agent-` vault in the customer's own `proton.vaults`; reserved variable names are refused (`EnvNaming`), and a variable may not come from a token and `env` at once (`Export.problems`).
- `host-token` is created with mode 0600 via `open()` and refused when others can read it.
- Vault names (`VaultNaming`): only `agent-…` vaults may be granted, the token vault is `lw-…`, everything else is private. Both prefixes are fixed, not configurable.
- Managing agents needs the user's account: `AppContext.withAccount` (browser login in its own session dir, logout and delete afterwards). Keep the account window short, e.g. `lw token github` only logs in to store.
- User-facing text is German (Swiss spelling, no ß), code and comments English. Metric units, dates as dd.MM.yyyy.

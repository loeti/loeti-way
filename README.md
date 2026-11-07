# loeti-way

`lw` verwaltet pro Kunde die Zugänge, die Coding-Agents in [Asylum](https://github.com/inventage-ai/asylum)-Containern bekommen:

- einen **Proton-Pass-Agent** (ein PAT mit Audit-Log) mit genau den Vaults des Kunden
- einen **GitHub Fine-grained PAT** für die Repos des Kunden

Beide Tokens liegen als Notizen in einem eigenen **Token-Vault**, auf den kein Agent Zugriff hat. Die `.envrc` im Kundenordner liest sie von dort, Asylum reicht sie in den Container weiter. Hintergrund: [Asylum-Setup](https://github.com/loeti/agent-skills/blob/main/docs/asylum-setup.md).

## Modell

```
/Volumes/Code/
├── customers/
│   ├── KundeA/
│   │   ├── .loeti-way.yaml     welche Vaults, welche Rollen, welche GitHub-Org
│   │   ├── .envrc              pass://-Referenzen auf den Token-Vault
│   │   ├── projekt-a1/
│   │   └── projekt-a2/
│   └── KundeB/…
├── firma/.loeti-way.yaml
└── loeti/.loeti-way.yaml

Proton Pass
├── KundeA, KundeA Infra, …     die Agents bekommen Zugriff, je nach Konfiguration
└── Agent Tokens                nur dein Konto: "<Kunde> Proton Agent", "<Kunde> GitHub PAT"
```

## Kundenkonfiguration

```yaml
# /Volumes/Code/customers/KundeA/.loeti-way.yaml
customer: KundeA

proton:
  # agent: asylum-kundea        # Standard: asylum-<kunde>
  expiration: 3m                # 1w, 1m, 3m, 6m, 1y
  vaults:
    - name: KundeA
      role: viewer              # viewer (Standard), editor, manager
    - name: KundeA Infra
      role: viewer

github:                         # optional
  owner: kundea-org             # Organisation oder Benutzer, dem die Repos gehören
  expires_in_days: 90
  repositories: [web, api]      # Erinnerung, GitHub kann sie nicht vorauswählen
  permissions:                  # Standard: contents und pull_requests: write
    contents: write
    pull_requests: write
```

`lw` lehnt eine Konfiguration ab, die dem Agent den Token-Vault freigeben würde.

## Globale Einstellungen

`~/.config/loeti-way/config.yaml`, alles optional:

```yaml
root: /Volumes/Code          # hier sucht lw nach Kunden (bis 3 Ebenen tief)
token_vault: Agent Tokens
warn_days: 14                # ab hier meldet `lw status` ablaufende Tokens
```

Umgebungsvariablen: `LW_ROOT`, `LW_TOKEN_VAULT`, `LW_PASS_CLI` (Pfad zu `pass-cli`).

## Kommandos

`lw` läuft auf dem Host, mit deinem eigenen `pass-cli login`. Ohne Kundenangabe gilt die `.loeti-way.yaml` im aktuellen Verzeichnis oder darüber.

| Kommando | Wirkung |
|---|---|
| `status [kunde] [--offline]` | Alle Kunden: Ablaufdaten, abweichende Rechte, fehlende Tokens. Status 1, wenn etwas zu tun ist |
| `init [ordner] [--github-owner org]` | `.loeti-way.yaml` und `.envrc` anlegen, bestehende Dateien bleiben |
| `apply [kunde] [--dry-run] [-y]` | Agent anlegen, falls er fehlt; Vault-Rechte abgleichen (fehlende freigeben, andere entziehen) |
| `renew [kunde] [--expiration 6m] [-y]` | Agent-Token erneuern und ablegen. Der alte wird sofort ungültig |
| `github [kunde] [--new] [--no-open]` | GitHub-Formular öffnen (vorausgefüllt bzw. "Regenerate"), Token einfügen, prüfen, ablegen |
| `audit [kunde] [--limit 50]` | Was der Agent gelesen hat, mit Begründung (`pass-cli agent monitor`) |

Item- und Ordner-Freigaben, die nicht in der Konfiguration stehen, zeigt `lw` an, ändert sie aber nicht.

## Neuer Kunde

```sh
pass-cli vault create --name "Agent Tokens"      # einmalig
cd /Volumes/Code/customers/KundeA
lw init --github-owner kundea-org
$EDITOR .loeti-way.yaml
lw apply
lw github
direnv allow
```

Einmalig in `~/.asylum/config.yaml`:

```yaml
env-from-host:
  GH_TOKEN: ASYLUM_GH_TOKEN
  PROTON_PASS_PERSONAL_ACCESS_TOKEN: ASYLUM_PROTON_PASS_PAT
```

Nach `renew` oder `github`: `direnv reload` in offenen Shells, dann alle Asylum-Sitzungen des Kunden beenden. Der Token gilt ab der Erstellung des Containers.

## Sicherheit

- Tokens gehen nie als Argument an `pass-cli` (sichtbar in `ps`), sondern über stdin.
- Ein neuer Token wird zuerst abgelegt, erst dann wird die alte Notiz gelöscht. Scheitert das Ablegen, zeigt `lw` den Token einmal an, statt ihn zu verlieren.
- Vor `apply` und `renew` prüft `lw`, ob es den Token-Vault gibt.

## Installation

```sh
swift build -c release
cp .build/release/lw /usr/local/bin/
```

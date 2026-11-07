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
│   │       ├── .loeti-way-project.yaml   optional: eigener GitHub-PAT nur für dieses Repo
│   │       └── .envrc                    lädt die .envrc des Kunden, ersetzt den GitHub-Token
│   └── KundeB/…
├── firma/.loeti-way.yaml
└── loeti/.loeti-way.yaml

Proton Pass
├── agent-kundea, agent-kundea-infra, …   die Agents bekommen Zugriff, je nach Konfiguration
├── lw-tokens                             nur dein Konto: "<Kunde> Proton Agent", "<Kunde> GitHub PAT",
│                                         "<Kunde> <Projekt> GitHub PAT"
└── alle anderen                          privat, lw gibt sie nie frei
```

## Vault-Namen

Zwei Vorsilben sind reserviert, `lw` setzt sie durch:

| Vorsilbe | Wer liest | Beispiele |
|---|---|---|
| `agent-` | der Agent des Kunden | `agent-kundea`, `agent-kundea-infra` |
| `lw-` | nur dein Konto, nie ein Agent | `lw-tokens` |
| keine davon | privat | `Persönlich`, `Firma`, … |

- Nach der Vorsilbe folgen Kleinbuchstaben und Ziffern, mit `-` getrennt. So braucht es weder in der Shell noch in `pass://`-Referenzen Anführungszeichen.
- Der Kundenteil entspricht dem Kundennamen in Kleinbuchstaben, `lw init` trägt `agent-<kunde>` ein.
- Einen zweiten Vault (`agent-kundea-infra`) nur anlegen, wenn er Einträge anderer Vertraulichkeit enthält: Ein Agent bekommt immer den ganzen Vault.
- `lw` lehnt in `proton.vaults` jeden Vault ohne `agent-` ab und verlangt für den Token-Vault `lw-`.
- Ist einem Agent ein anderer Vault freigegeben (z.B. von Hand in Proton), meldet `lw status` das, und `lw apply` entzieht ihn.
- Kunden-Vaults legt `lw` nicht an: `pass-cli vault create --name agent-kundea`.

## Kundenkonfiguration

```yaml
# /Volumes/Code/customers/KundeA/.loeti-way.yaml
customer: KundeA

proton:
  # agent: asylum-kundea        # Standard: asylum-<kunde>
  expiration: 3m                # 1w, 1m, 3m, 6m, 1y
  vaults:
    - name: agent-kundea
      role: viewer              # viewer (Standard), editor, manager
    - name: agent-kundea-infra
      role: viewer

github:                         # optional
  owner: kundea-org             # Organisation oder Benutzer, dem die Repos gehören
  expires_in_days: 90
  repositories: [web, api]      # Erinnerung, GitHub kann sie nicht vorauswählen
  permissions:                  # Standard: contents und pull_requests: write
    contents: write
    pull_requests: write
```

`lw` lehnt eine Konfiguration ab, die dem Agent den Token-Vault oder einen Vault ohne `agent-` freigeben würde.

## Projekt-PAT

Ein Fine-grained PAT hat für alle ausgewählten Repos dieselben Rechte und gehört genau einem Owner. "Alle Kunden-Repos lesen, nur in einem schreiben" geht mit einem Token nicht. Darum gibt es zwei Stufen:

- **Kunde** (`github` in `.loeti-way.yaml`): ein PAT für alle Projekte des Kunden. Ein Agent in Projekt A kann damit auch in Projekt B schreiben.
- **Projekt** (`.loeti-way-project.yaml` im Projektordner, optional): ein eigener PAT, der im Projektordner den des Kunden ersetzt. Der Proton-Agent bleibt der des Kunden.

```yaml
# /Volumes/Code/customers/KundeA/projekt-a2/.loeti-way-project.yaml
project: projekt-a2             # Standard: Ordnername
github:                         # fehlende Werte kommen vom Kunden
  owner: kundea-org             # lw init --project schreibt ihn immer hin
  token_name: kundea_projekt-a2_PAT   # Name auf GitHub, Standard: "<Kunde> <Projekt> Asylum"
  repositories: [projekt-a2]    # Standard: [<projekt>]
```

`lw init --project` legt die Datei und eine `.envrc` an und trägt beide in `.git/info/exclude` ein, falls der Ordner ein git-Repo ist. Die `.envrc` lädt zuerst die des Kunden (`source_up_if_exists`) und setzt dann `ASYLUM_GH_TOKEN` neu. Fehlt der Projekt-Token, bleibt die Variable leer; es gibt keinen Rückfall auf den breiteren Kunden-PAT. `lw` sucht Projekte bis 2 Ebenen unter dem Kundenordner.

Die Notiz im Token-Vault heisst immer `<Kunde> <Projekt> GitHub PAT`; `token_item` gibt es nur beim Kunden. Die Projektdatei liegt dort, wo Agents schreiben können, und darf `lw` darum nicht auf eine andere Notiz lenken. Gehört dieselbe Notiz noch einem anderen Kunden, brechen `lw init --project` und `lw github` ab.

`token_name` gibt es auch beim Kunden. Es muss zum Namen des Tokens auf GitHub passen, sonst schickt dich `lw github` beim Erneuern zum falschen Token.

## Globale Einstellungen

`~/.config/loeti-way/config.yaml`, alles optional:

```yaml
root: /Volumes/Code          # hier sucht lw nach Kunden (bis 3 Ebenen tief)
token_vault: lw-tokens       # muss mit lw- beginnen
warn_days: 14                # ab hier meldet `lw status` ablaufende Tokens
```

Umgebungsvariablen: `LW_ROOT`, `LW_TOKEN_VAULT`, `LW_PASS_CLI` (Pfad zu `pass-cli`).

## Kommandos

`lw` läuft auf dem Host, mit deinem eigenen `pass-cli login`. Ohne Kundenangabe gilt die `.loeti-way.yaml` im aktuellen Verzeichnis oder darüber.

`apply`, `renew` und `github` melden dich danach bei Proton Pass ab, auch wenn sie fehlschlagen. Mit `--keep-login` bleibst du angemeldet. `status` zeigt zuoberst, wer angemeldet ist.

| Kommando | Wirkung |
|---|---|
| `status [kunde] [--offline]` | Wer bei `pass-cli` angemeldet ist; alle Kunden: Ablaufdaten, abweichende Rechte, fehlende Tokens. Status 1, wenn etwas zu tun ist |
| `init [ordner] [--github-owner org] [--project]` | `.loeti-way.yaml` (bzw. mit `--project` `.loeti-way-project.yaml`) und `.envrc` anlegen, bestehende Dateien bleiben |
| `apply [kunde] [--dry-run] [-y]` | Agent anlegen, falls er fehlt; Vault-Rechte abgleichen (fehlende freigeben, andere entziehen) |
| `renew [kunde] [--expiration 6m] [-y]` | Agent-Token erneuern und ablegen. Der alte wird sofort ungültig |
| `github [kunde] [--project name] [--new] [--no-open]` | GitHub-Formular öffnen (vorausgefüllt bzw. "Regenerate"), Token einfügen, prüfen, ablegen. Ohne Kundenangabe gilt das Projekt, in dem du gerade bist |
| `audit [kunde] [--limit 50]` | Was der Agent gelesen hat, mit Begründung (`pass-cli agent monitor`) |

Item- und Ordner-Freigaben, die nicht in der Konfiguration stehen, zeigt `lw` an, ändert sie aber nicht.

## Neuer Kunde

```sh
pass-cli vault create --name lw-tokens          # einmalig
pass-cli vault create --name agent-kundea
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

- Die `pass-cli`-Anmeldung gilt für deinen ganzen macOS-Benutzer, nicht pro Shell: Jeder Prozess, auch ein Agent ausserhalb von Asylum, kann sie benutzen. Darum meldet `lw` dich nach Änderungen ab. Wer gerade angemeldet ist: `pass-cli info` (`Username` = dein Konto, `Personal Access Token` = ein Agent).
- Tokens gehen nie als Argument an `pass-cli` (sichtbar in `ps`), sondern über stdin.
- Ein neuer Token wird zuerst abgelegt, erst dann wird die alte Notiz gelöscht. Scheitert das Ablegen, zeigt `lw` den Token einmal an, statt ihn zu verlieren.
- Vor `apply` und `renew` prüft `lw`, ob es den Token-Vault gibt.

## Installation

```sh
swift build -c release
cp .build/release/lw /Volumes/Tools/bin/      # oder ein anderer Ordner im PATH
```

# loeti-way

`lw` verwaltet pro Kunde die Zugänge, die Coding-Agents in [Asylum](https://github.com/inventage-ai/asylum)-Containern bekommen:

- einen **GitHub Fine-grained PAT** für die Repos des Kunden oder eines Projekts
- Werte aus den Vaults des Kunden (z.B. ein Maven-Passwort), gelesen von einem **Proton-Pass-Agent** des Kunden (ein PAT mit Audit-Log)

Die Tokens liegen als Notizen in einem eigenen **Token-Vault**. Lesen darf ihn nur der **Host-Agent**, der auf dem Mac angemeldet bleibt. Wechselst du in einen Kunden- oder Projektordner, ruft die `.envrc` `lw env` auf: Das setzt `ASYLUM_GH_TOKEN` und die Werte aus `env:`, Asylum reicht sie in den Container weiter. Im Container gibt es kein `pass-cli` und keinen Proton-Token. Hintergrund: [Asylum-Setup](https://github.com/loeti/agent-skills/blob/main/docs/asylum-setup.md).

Dein eigenes Proton-Konto meldet `lw` nur an, solange ein Befehl es braucht, und meldet es danach wieder ab.

## Modell

```
/Volumes/Code/
├── customers/
│   ├── KundeA/
│   │   ├── .loeti-way.yaml     Vaults, Rollen, GitHub-Org, env:
│   │   ├── .envrc              eval "$(lw env)"
│   │   ├── projekt-a1/
│   │   └── projekt-a2/
│   │       ├── .loeti-way-project.yaml   optional: eigener GitHub-PAT nur für dieses Repo
│   │       └── .envrc                    eval "$(lw env)"
│   └── KundeB/…
├── firma/.loeti-way.yaml
└── loeti/.loeti-way.yaml

Proton Pass
├── agent-kundea, agent-kundea-infra, …   der Agent des Kunden, je nach Konfiguration
├── lw-tokens                             dein Konto und der Host-Agent (nur lesen):
│                                         "<Kunde> Proton Agent", "<Kunde> GitHub PAT",
│                                         "<Kunde> <Projekt> GitHub PAT"
└── alle anderen                          privat, lw gibt sie nie frei

~/.config/loeti-way/host-token            Token des Host-Agents, nur für dich lesbar (0600)
~/.config/loeti-way/customers.yaml        von lw apply bestätigte Kunden: Ordner, Agent, Notizen
~/.config/loeti-way/agents.yaml           Ablaufdaten der Agents, zuletzt mit deinem Konto gesehen
~/.cache/loeti-way/sessions/              Anmeldungen von pass-cli, je eine pro Agent
```

## Anmeldungen

`lw` ruft `pass-cli` immer mit einem eigenen `PROTON_PASS_SESSION_DIR` auf. Die normale Anmeldung von `pass-cli`, die jeder Prozess deines macOS-Benutzers finden würde, bleibt leer.

| Anmeldung | Wer | Wie lange | Wofür |
|---|---|---|---|
| `host` | Host-Agent, nur Viewer auf `lw-tokens` | bleibt | `lw env`, `lw host` |
| `agent-<kunde>` | Agent des Kunden | bleibt | Werte aus `env:` |
| `account` | dein Konto, Login im Browser | nur während des Befehls | `apply`, `renew`, `github` (zum Ablegen), `audit`, `status --konto`, `host --setup/--renew` |

Eine `.loeti-way.yaml` kann in einem Ordner liegen, in den ein Agent schreibt, und sie bestimmt, welche Notizen gelesen werden. Darum gilt ein Kunde erst, wenn du ihn mit `lw apply` bestätigt hast: `lw` trägt Ordner, Kundenname, Agent, Notizen, Vaults und `env:` in `customers.yaml` ein. `lw env` und alle anderen Befehle lehnen eine Konfiguration ab, die dort fehlt oder davon abweicht. Nach jedem Anmelden prüft `lw` ausserdem, ob wirklich der erwartete Agent angemeldet ist.

Startest du auf dem Mac aus Versehen einen Agent, findet `pass-cli` keine Anmeldung, und in der Umgebung liegen nur die Werte des Ordners. Ein Prozess, der es darauf anlegt, kann `host-token` lesen und damit die Tokens aller Kunden, aber nicht dein Konto. Jeder Zugriff des Host-Agents steht im Audit-Log: `lw audit --host`.

## Vault-Namen

Zwei Vorsilben sind reserviert, `lw` setzt sie durch:

| Vorsilbe | Wer liest | Beispiele |
|---|---|---|
| `agent-` | der Agent des Kunden | `agent-kundea`, `agent-kundea-infra` |
| `lw-` | dein Konto und der Host-Agent, nie ein Kunden-Agent | `lw-tokens` |
| keine davon | privat | `Persönlich`, `Firma`, … |

- Nach der Vorsilbe folgen Kleinbuchstaben und Ziffern, mit `-` getrennt. So braucht es weder in der Shell noch in `pass://`-Referenzen Anführungszeichen.
- Der Kundenteil entspricht dem Kundennamen in Kleinbuchstaben, `lw init` trägt `agent-<kunde>` ein.
- Einen zweiten Vault (`agent-kundea-infra`) nur anlegen, wenn er Einträge anderer Vertraulichkeit enthält: Ein Agent bekommt immer den ganzen Vault.
- `lw` lehnt in `proton.vaults` jeden Vault ohne `agent-` ab und verlangt für den Token-Vault `lw-`.
- Ist einem Agent ein anderer Vault freigegeben (z.B. von Hand in Proton), meldet `lw status` das, und `lw apply` entzieht ihn. Beim Host-Agent macht das `lw host --setup`.
- Vaults legt `lw` nicht an: `pass-cli vault create --name agent-kundea`.

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

env:                            # optional: lw env setzt diese Variablen
  MAVEN_PASSWORD: pass://agent-kundea/Maven/password
```

`lw` lehnt eine Konfiguration ab, die dem Agent den Token-Vault oder einen Vault ohne `agent-` freigeben würde.

### env

`lw env` liest jede Referenz mit dem Agent des Kunden. Auf dem Mac heisst die Variable immer `LW_ENV_<NAME>`, erst Asylum gibt ihr im Container den eigentlichen Namen (`env-from-host`, siehe [Einmalig](#einmalig)). So wirkt eine Variable wie `NODE_OPTIONS` nie auf Programme auf dem Mac.

- Die Referenz hat die Form `pass://<vault>/<eintrag>/<feld>`, der Vault muss in `proton.vaults` stehen.
- Variablennamen bestehen aus `A-Z`, `0-9` und `_`. Einige Namen sind auch für den Container gesperrt: `PATH`, `HOME`, `GH_TOKEN`, `DYLD_*`, `LD_*`, `PROTON_PASS_*`, `GIT_*`, `ASYLUM_*` und weitere.
- `env:` gibt es nur beim Kunden, nicht in der Projektdatei.

## Projekt-PAT

Ein Fine-grained PAT hat für alle ausgewählten Repos dieselben Rechte und gehört genau einem Owner. "Alle Kunden-Repos lesen, nur in einem schreiben" geht mit einem Token nicht. Darum gibt es zwei Stufen:

- **Kunde** (`github` in `.loeti-way.yaml`): ein PAT für alle Projekte des Kunden. Ein Agent in Projekt A kann damit auch in Projekt B schreiben.
- **Projekt** (`.loeti-way-project.yaml` im Projektordner, optional): ein eigener PAT, der im Projektordner den des Kunden ersetzt. Der Proton-Agent bleibt der des Kunden.

```yaml
# /Volumes/Code/customers/KundeA/projekt-a2/.loeti-way-project.yaml
github:                         # fehlende Werte kommen vom Kunden
  owner: kundea-org             # lw init --project schreibt ihn immer hin
  token_name: kundea_projekt-a2_PAT   # Name auf GitHub, Standard: "<Kunde> <Projekt> Asylum"
  repositories: [projekt-a2]    # Standard: [<projekt>]
```

`lw init --project` legt die Datei und eine `.envrc` an und trägt beide in `.git/info/exclude` ein, falls der Ordner ein git-Repo ist. `lw env` nimmt im Projektordner den PAT des Projekts. Fehlt er oder ist die Projektdatei kaputt, bleibt `ASYLUM_GH_TOKEN` leer; es gibt keinen Rückfall auf den breiteren Kunden-PAT. `lw` sucht Projekte bis 2 Ebenen unter dem Kundenordner.

Das Projekt heisst immer wie sein Ordner, die Notiz im Token-Vault immer `<Kunde> <Ordner> GitHub PAT`. `token_item` gibt es nur beim Kunden, und `project` ist nur erlaubt, wenn es den Ordnernamen wiederholt. Haben zwei Projekte denselben Ordnernamen, lehnt `lw` beide ab. Die Projektdatei liegt dort, wo Agents schreiben können, und darf `lw` darum nicht auf eine andere Notiz lenken. Gehört dieselbe Notiz noch einem anderen Kunden, brechen `lw env`, `lw init --project` und `lw github` ab.

`token_name` gibt es auch beim Kunden. Es muss zum Namen des Tokens auf GitHub passen, sonst schickt dich `lw github` beim Erneuern zum falschen Token.

## Globale Einstellungen

`~/.config/loeti-way/config.yaml`, alles optional:

```yaml
root: /Volumes/Code          # hier sucht lw nach Kunden (bis 3 Ebenen tief)
token_vault: lw-tokens       # muss mit lw- beginnen
host_agent: lw-host          # Name des Host-Agents in Proton Pass
warn_days: 14                # ab hier meldet `lw status` ablaufende Tokens
```

Umgebungsvariablen: `LW_ROOT`, `LW_TOKEN_VAULT`, `LW_PASS_CLI` (Pfad zu `pass-cli`), `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`.

## Kommandos

`lw` läuft auf dem Mac. Ohne Kundenangabe gilt die `.loeti-way.yaml` im aktuellen Verzeichnis oder darüber.

| Kommando | Konto | Wirkung |
|---|---|---|
| `env [ordner]` | nein | `export`-Zeilen für die `.envrc`. Probleme auf stderr, betroffene Variablen werden entfernt, Status immer 0. Im Terminal ohne Werte |
| `host` | nein | `host-token` und Anmeldung des Host-Agents prüfen |
| `host --setup [-y]` | ja | Host-Agent anlegen, falls er fehlt; nur `lw-tokens` als Viewer freigeben, andere Freigaben entziehen |
| `host --renew [--expiration 3m]` | ja | Token des Host-Agents erneuern und in `host-token` schreiben |
| `host --set-token` | nein | Einen vorhandenen Token in `host-token` ablegen und anmelden |
| `status [kunde] [--offline]` | nein | Was zu tun ist, siehe [Status](#status). Status 1, wenn etwas zu tun ist |
| `status --konto` | ja | Zusätzlich die Rechte aller Agents und aktuelle Ablaufdaten |
| `init [ordner] [--github-owner org] [--project]` | nein | `.loeti-way.yaml` (bzw. mit `--project` `.loeti-way-project.yaml`) und `.envrc` anlegen, bestehende Dateien bleiben |
| `apply [kunde] [--dry-run] [-y]` | ja | Kunde in `customers.yaml` bestätigen; Agent anlegen, falls er fehlt; Vault-Rechte abgleichen (fehlende freigeben, andere entziehen) |
| `renew [kunde] [--expiration 6m] [-y]` | ja | Agent-Token erneuern und ablegen. Der alte wird sofort ungültig |
| `github [kunde] [--project name] [--new] [--no-open]` | zum Ablegen | GitHub-Formular öffnen (vorausgefüllt bzw. "Regenerate"), Token einfügen, prüfen, ablegen. Ohne Kundenangabe gilt das Projekt, in dem du gerade bist |
| `audit [kunde] [--host] [--limit 50]` | ja | Was der Agent (bzw. der Host-Agent) gelesen hat, mit Begründung (`pass-cli agent monitor`) |

Item- und Ordner-Freigaben, die nicht in der Konfiguration stehen, zeigt `lw` an, ändert sie aber nicht.

## Status

`lw status` braucht dein Konto nicht. Es zeigt pro Kunde, was zu tun ist (`!`), was stimmt (`✓`) und Hinweise (`·`):

- **Host-Agent:** angemeldet, `lw-tokens` lesbar, Ablaufdatum. Ausserdem, ob die normale Anmeldung von `pass-cli` leer ist; ist dort dein Konto angemeldet, kann jeder Prozess es benutzen.
- **Kunde:** in `customers.yaml` bestätigt und unverändert, Ablaufdatum des Agents, `env:`, `.envrc` lädt `lw env`.
- **GitHub-PATs** von Kunde und Projekten: abgelegt, Ablaufdatum laut GitHub.
- **Jedes git-Repo** bis 2 Ebenen unter dem Kunden: hat es einen Projekt-PAT (sonst `lw init --project`), lädt eine eigene `.envrc` `lw env`, und deckt der zuständige PAT das Repo aus `origin` ab (GitHub antwortet sonst mit 404)?
- **Repos ohne Kunde** unter `root`: Sie bekommen keine Tokens.

Ablaufdaten der Proton-Agents kennt nur dein Konto. `lw` hält sie bei jedem Befehl mit Konto in `agents.yaml` fest; `status` zeigt sie mit "Stand". Die Rechte der Agents prüft nur `lw status --konto`. Ob direnv eine `.envrc` erlaubt hat (`direnv allow`), prüft `lw` nicht.

## Einmalig

```sh
pass-cli vault create --name lw-tokens
lw host --setup                       # Host-Agent anlegen, Token in host-token, anmelden
```

Hast du den Host-Agent schon in Proton angelegt: `lw host --set-token`, danach `lw host --setup`, um seine Rechte zu prüfen.

In `~/.asylum/config.yaml` (nicht gesetzte Variablen überspringt Asylum, die Liste darf also alle Kunden abdecken):

```yaml
env-from-host:
  GH_TOKEN: ASYLUM_GH_TOKEN
  MAVEN_PASSWORD: LW_ENV_MAVEN_PASSWORD   # je Name aus env:
```

`lw` muss für direnv im `PATH` liegen.

## Neuer Kunde

```sh
pass-cli vault create --name agent-kundea
cd /Volumes/Code/customers/KundeA
lw init --github-owner kundea-org
$EDITOR .loeti-way.yaml
lw apply
lw github
direnv allow
```

Nach `renew` oder `github`: `direnv reload` in offenen Shells, dann alle Asylum-Sitzungen des Kunden beenden. Der Token gilt ab der Erstellung des Containers.

## Sicherheit

- Tokens gehen nie als Argument an `pass-cli` (sichtbar in `ps`), sondern über stdin oder die Umgebung. Variablen `PROTON_PASS_*` aus deiner Shell gibt `lw` nicht an `pass-cli` weiter.
- Ein neuer Token wird zuerst abgelegt, erst dann wird die alte Notiz gelöscht. Scheitert das Ablegen, zeigt `lw` den Token einmal an, statt ihn zu verlieren.
- `host-token` wird von Anfang an mit `0600` geschrieben; ist die Datei für andere lesbar, verweigert `lw` sie.
- Vor `apply` und `renew` prüft `lw`, ob es den Token-Vault gibt.

## Installation

```sh
swift build -c release
cp .build/release/lw /Volumes/Tools/bin/      # oder ein anderer Ordner im PATH
```

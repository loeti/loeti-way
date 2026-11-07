# loeti-way

`lw` verwaltet pro Kunde die Zugänge, die Coding-Agents in [Asylum](https://github.com/inventage-ai/asylum)-Containern bekommen:

- **Tokens** von Anbietern wie GitHub, für den ganzen Kunden oder ein einzelnes Projekt
- weitere Werte aus den Vaults des Kunden (z.B. ein Maven-Passwort)

Gelesen wird alles von einem **Proton-Pass-Agent** des Kunden (ein PAT mit Audit-Log), aus den Vaults des Kunden. Die Tokens der Proton-Agents selbst liegen im **Token-Vault**; lesen darf ihn nur der **Host-Agent**, der auf dem Mac angemeldet bleibt. Wechselst du in einen Kunden- oder Projektordner, ruft die `.envrc` `lw env` auf: Das setzt die Variablen des Ordners (z.B. `LW_ENV_GH_TOKEN`), Asylum reicht sie in den Container weiter. Im Container gibt es kein `pass-cli` und keinen Proton-Token. Hintergrund: [Asylum-Setup](https://github.com/loeti/agent-skills/blob/main/docs/asylum-setup.md).

Dein eigenes Proton-Konto meldet `lw` nur an, solange ein Befehl es braucht, und meldet es danach wieder ab.

## Modell

```
/Volumes/Code/
├── customers/
│   ├── KundeA/
│   │   ├── .loeti-way.yaml     Vaults, Rollen, tokens, env
│   │   ├── .envrc              eval "$(lw env)"
│   │   ├── projekt-a1/
│   │   └── projekt-a2/
│   │       ├── .loeti-way-project.yaml   optional: eigener Vault, eigene Tokens und env
│   │       └── .envrc                    eval "$(lw env)"
│   └── KundeB/…
├── firma/.loeti-way.yaml
└── loeti/.loeti-way.yaml

Proton Pass
├── agent-kundea                          Tokens des Kunden: "GitHub Token", …
├── agent-kundea-projekt-a2               Tokens nur für projekt-a2 (vault: own), gleiche Titel
├── agent-kundea-infra, …                 weitere Werte für env, je nach Konfiguration
├── lw-tokens                             nur Tokens der Proton-Agents: "<Kunde> Proton Agent";
│                                         dein Konto und der Host-Agent (nur lesen)
└── alle anderen                          privat, lw gibt sie nie frei

~/.config/loeti-way/host-token            Token des Host-Agents, nur für dich lesbar (0600)
~/.config/loeti-way/customers.yaml        von lw apply bestätigte Kunden und Projekte: Agent, Vaults, was lw env liest
~/.config/loeti-way/agents.yaml           Ablaufdaten der Agents, zuletzt mit deinem Konto gesehen
~/.cache/loeti-way/sessions/              Anmeldungen von pass-cli, je eine pro Agent
```

## Anmeldungen

`lw` ruft `pass-cli` immer mit einem eigenen `PROTON_PASS_SESSION_DIR` auf. Die normale Anmeldung von `pass-cli`, die jeder Prozess deines macOS-Benutzers finden würde, bleibt leer.

| Anmeldung | Wer | Wie lange | Wofür |
|---|---|---|---|
| `host` | Host-Agent, nur Viewer auf `lw-tokens` | bleibt | Token eines Kunden-Agents lesen, wenn dieser sich anmelden muss; `lw host` |
| `agent-<kunde>` | Agent des Kunden | bleibt | Tokens und `env` des Kunden und seiner Projekte |
| `account` | dein Konto, Login im Browser | nur während des Befehls | `apply`, `renew`, `token` (zum Ablegen), `audit`, `status --konto`, `host --setup/--renew` |

Eine `.loeti-way.yaml` oder `.loeti-way-project.yaml` kann in einem Ordner liegen, in den ein Agent schreibt, und sie bestimmt, was gelesen wird. Darum gilt ein Kunde erst, wenn du ihn mit `lw apply` bestätigt hast: `lw` trägt Ordner, Kundenname, Agent, Vaults und jede Variable mit ihrer Referenz in `customers.yaml` ein, für den Kunden und für jedes Projekt. `lw env` und alle anderen Befehle lehnen eine Konfiguration ab, die dort fehlt oder davon abweicht; bei einem Projekt gilt das nur für den Projektordner. Ein Vault, aus dem ein Kunde Werte liest, darf keinem anderen Kunden freigegeben sein. Nach jedem Anmelden prüft `lw` ausserdem, ob wirklich der erwartete Agent angemeldet ist.

Startest du auf dem Mac aus Versehen einen Agent, findet `pass-cli` keine Anmeldung, und in der Umgebung liegen nur die Werte des Ordners. Ein Prozess, der es darauf anlegt, kann `host-token` lesen, damit die Tokens aller Proton-Agents und mit ihnen die Vaults aller Kunden, aber nicht dein Konto. Jeder Zugriff des Host-Agents steht im Audit-Log: `lw audit --host`.

## Vault-Namen

Zwei Vorsilben sind reserviert, `lw` setzt sie durch:

| Vorsilbe | Wer liest | Beispiele |
|---|---|---|
| `agent-` | der Agent des Kunden | `agent-kundea`, `agent-kundea-infra`, `agent-kundea-projekt-a2` |
| `lw-` | dein Konto und der Host-Agent, nie ein Kunden-Agent | `lw-tokens` |
| keine davon | privat | `Persönlich`, `Firma`, … |

- Nach der Vorsilbe folgen Kleinbuchstaben und Ziffern, mit `-` getrennt. So braucht es weder in der Shell noch in `pass://`-Referenzen Anführungszeichen.
- Der Kundenteil entspricht dem Kundennamen in Kleinbuchstaben, `lw init` trägt `agent-<kunde>` ein. Dort liegen die Tokens des Kunden. Der eigene Vault eines Projekts heisst `agent-<kunde>-<projektordner>`; beide Namen sind fest.
- Einen zweiten Vault (`agent-kundea-infra`) nur anlegen, wenn er Einträge anderer Vertraulichkeit enthält: Ein Agent bekommt immer den ganzen Vault.
- `lw` lehnt in `proton.vaults` jeden Vault ohne `agent-` ab und verlangt für den Token-Vault `lw-`.
- Ist einem Agent ein anderer Vault freigegeben (z.B. von Hand in Proton), meldet `lw status` das, und `lw apply` entzieht ihn. Beim Host-Agent macht das `lw host --setup`.
- Vaults legt `lw` nicht an: `pass-cli vault create --name agent-kundea`.

## Kundenkonfiguration

```yaml
# /Volumes/Code/customers/KundeA/.loeti-way.yaml
customer: KundeA

proton:
  # agent: agent-kundea        # Standard: agent-<kunde>
  expiration: 3m                # 1w, 1m, 3m, 6m, 1y
  vaults:
    - name: agent-kundea
      role: viewer              # viewer (Standard), editor, manager
    - name: agent-kundea-infra
      role: viewer

tokens:                         # optional, je Anbieter
  github:
    owner: kundea-org           # Organisation oder Benutzer, dem die Repos gehören
    expires_in_days: 90
    repositories: [web, api]    # Erinnerung, GitHub kann sie nicht vorauswählen
    permissions:                # Standard: contents und pull_requests: write
      contents: write
      pull_requests: write
    # token_name: KundeA_PAT    # Name auf GitHub, Standard: "<Kunde>_PAT"
    # variable: GH_TOKEN        # Name im Container

env:                            # optional: lw env setzt diese Variablen
  MAVEN_PASSWORD: pass://agent-kundea/Maven/password
```

`lw` lehnt eine Konfiguration ab, die dem Agent den Token-Vault oder einen Vault ohne `agent-` freigeben würde.

### tokens

Jeder Anbieter hat einen festen Ablageort und Titel. Ein Token des Kunden liegt in `agent-<kunde>`, als Notiz mit dem Token als Inhalt:

| Anbieter | Titel | Variable (Standard) | Hilfe | Prüfung in `lw status` |
|---|---|---|---|---|
| `github` | `GitHub Token` | `GH_TOKEN` | `lw token github`: Formular vorausgefüllt, Token prüfen und ablegen | Ablaufdatum, welche Repos er abdeckt |

Weitere Anbieter (Bitbucket, LLM-Anbieter, …) kommen als Erweiterung dazu. Einen Token von Hand anzulegen geht immer: richtiger Vault, richtiger Titel. `agent-<kunde>` muss in `proton.vaults` stehen.

### env

`lw env` liest jede Referenz mit dem Agent des Kunden. Auf dem Mac heisst die Variable immer `LW_ENV_<NAME>`, erst Asylum gibt ihr im Container den eigentlichen Namen (`env-from-host`, siehe [Einmalig](#einmalig)). So wirkt eine Variable wie `NODE_OPTIONS` nie auf Programme auf dem Mac.

- Die Referenz hat die Form `pass://<vault>/<eintrag>/<feld>`, der Vault muss in `proton.vaults` stehen.
- Variablennamen bestehen aus `A-Z`, `0-9` und `_`. Einige Namen sind auch für den Container gesperrt: `PATH`, `HOME`, `DYLD_*`, `LD_*`, `PROTON_PASS_*`, `GIT_*`, `ASYLUM_*` und weitere. Eine Variable darf nicht zugleich von einem Token und aus `env` kommen.

## Projekte

Ohne Projektdatei bekommt ein Ordner, was der Kunde exportiert. Das ist der Normalfall, etwa bei Bitbucket, das Tokens nur pro Kunde ausstellt. Ein Fine-grained PAT von GitHub hat aber für alle ausgewählten Repos dieselben Rechte: Ein Agent in Projekt A kann mit dem Token des Kunden auch in Projekt B schreiben. Soll ein Projekt eigene Tokens oder Werte haben, bekommt es eine `.loeti-way-project.yaml`:

```yaml
# /Volumes/Code/customers/KundeA/projekt-a2/.loeti-way-project.yaml
vault: own                      # agent-kundea-projekt-a2, in proton.vaults des Kunden freigeben
tokens:
  github:                       # ersetzt den GitHub-Token des Kunden in diesem Ordner
    owner: kundea-org           # fehlende Werte kommen vom Kunden
    token_name: kundea_projekt-a2_PAT   # Standard: "<Kunde>_<Projekt>_PAT"
    repositories: [projekt-a2]  # Standard: [<projekt>]
env:                            # ergänzt bzw. ersetzt die Werte des Kunden
  DB_PASSWORD: pass://agent-kundea-projekt-a2/DB/password
```

- Eigene Tokens liegen im Vault des Projekts (`vault: own`), mit denselben Titeln wie beim Kunden. Ohne `vault: own` gibt es keine eigenen Tokens.
- Gelesen wird mit dem Agent des Kunden. Den Projekt-Vault gibst du ihm in `proton.vaults` frei, `lw apply` registriert das Projekt.
- Ist die Projektdatei kaputt oder nicht registriert, setzt `lw env` im Projektordner nichts; es gibt keinen Rückfall auf die breiteren Werte des Kunden.
- Das Projekt heisst immer wie sein Ordner, `project` ist nur erlaubt, wenn es den Ordnernamen wiederholt. Ergeben zwei Ordner denselben Vault-Namen (`x y` und `x-y`), lehnt `lw` beide ab.
- `lw init --project` legt die Datei und eine `.envrc` an und trägt beide in `.git/info/exclude` ein, falls der Ordner ein git-Repo ist. `lw` sucht Projekte bis 2 Ebenen unter dem Kundenordner.

`token_name` muss zum Namen des Tokens auf GitHub passen, sonst schickt dich `lw token github` beim Erneuern zum falschen Token.

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
| `apply [kunde] [--dry-run] [-y]` | ja | Kunde und Projekte in `customers.yaml` bestätigen; Agent anlegen, falls er fehlt; Vault-Rechte abgleichen (fehlende freigeben, andere entziehen) |
| `renew [kunde] [--expiration 6m] [-y]` | ja | Agent-Token erneuern und ablegen. Der alte wird sofort ungültig |
| `token github [kunde] [--project name] [--new] [--no-open]` | zum Ablegen | GitHub-Formular öffnen (vorausgefüllt bzw. "Regenerate"), Token einfügen, prüfen, in `agent-<kunde>` bzw. im Projekt-Vault ablegen. Ohne Kundenangabe gilt der Token, den `lw env` im aktuellen Ordner setzt |
| `audit [kunde] [--host] [--limit 50]` | ja | Was der Agent (bzw. der Host-Agent) gelesen hat, mit Begründung (`pass-cli agent monitor`) |

Item- und Ordner-Freigaben, die nicht in der Konfiguration stehen, zeigt `lw` an, ändert sie aber nicht.

## Status

`lw status` braucht dein Konto nicht. Es zeigt pro Kunde, was zu tun ist (`!`), was stimmt (`✓`) und Hinweise (`·`):

- **Host-Agent:** angemeldet, `lw-tokens` lesbar, Ablaufdatum. Ausserdem, ob die normale Anmeldung von `pass-cli` leer ist; ist dort dein Konto angemeldet, kann jeder Prozess es benutzen.
- **Kunde:** in `customers.yaml` bestätigt und unverändert, Ablaufdatum des Agents, sein Token in `lw-tokens`, `.envrc` lädt `lw env`.
- **Tokens und env** von Kunde und Projekten, mit dem Agent des Kunden: Notiz bzw. Eintrag vorhanden; beim GitHub-Token das Ablaufdatum laut GitHub. Projekte zusätzlich: registriert.
- **Jedes git-Repo** bis 2 Ebenen unter dem Kunden: lädt eine eigene `.envrc` `lw env`, gibt es für ein GitHub-Repo einen GitHub-Token, und deckt er das Repo aus `origin` ab (GitHub antwortet sonst mit 404)?
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
  GH_TOKEN: LW_ENV_GH_TOKEN               # je Variable eines Tokens
  MAVEN_PASSWORD: LW_ENV_MAVEN_PASSWORD   # je Name aus env
```

`lw` muss für direnv im `PATH` liegen.

## Neuer Kunde

```sh
pass-cli vault create --name agent-kundea
cd /Volumes/Code/customers/KundeA
lw init --github-owner kundea-org
$EDITOR .loeti-way.yaml
lw apply
lw token github
direnv allow
```

Nach `renew` oder `token`: `direnv reload` in offenen Shells, dann alle Asylum-Sitzungen des Kunden beenden. Der Token gilt ab der Erstellung des Containers.

## Sicherheit

- Tokens gehen nie als Argument an `pass-cli` (sichtbar in `ps`), sondern über stdin oder die Umgebung. Variablen `PROTON_PASS_*` aus deiner Shell gibt `lw` nicht an `pass-cli` weiter.
- Ein neuer Token wird zuerst abgelegt, erst dann wird die alte Notiz gelöscht. Scheitert das Ablegen, zeigt `lw` den Token einmal an, statt ihn zu verlieren.
- `host-token` wird von Anfang an mit `0600` geschrieben; ist die Datei für andere lesbar, verweigert `lw` sie.
- Vor `apply` und `renew` prüft `lw`, ob es den Token-Vault gibt, vor dem Ablegen eines Tokens den Vault des Kunden bzw. Projekts.

## Installation

```sh
swift build -c release
cp .build/release/lw /Volumes/Tools/bin/      # oder ein anderer Ordner im PATH
```

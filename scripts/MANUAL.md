# ha_control.ps1, ha_yaml.py and ha_snapshot.py manual

`ha_control.ps1` moves Home Assistant YAML configuration between a local repository and the live `/config` folder over SSH. It also deletes retired files on the server, copies other server files read only, installs local apps (add-ons), and verifies, reloads and restarts Home Assistant through the REST API.

`ha_yaml.py` gives all YAML files one canonical format and compares files by meaning instead of by text. `ha_control.ps1` calls it automatically.

`ha_snapshot.py` records the state of Home Assistant before a change and compares it after the change. Use it when you move automations, scripts or entities between files.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Commands](#commands)
- [Rollback](#rollback)
- [Check a move: ha_snapshot.py](#check-a-move-ha_snapshotpy)
- [YAML formatting](#yaml-formatting)
- [Dry run](#dry-run)
- [Exit codes](#exit-codes)
- [ha_yaml.py on its own](#ha_yamlpy-on-its-own)
- [Troubleshooting](#troubleshooting)

## Requirements

On your PC:

| Requirement | Why |
| --- | --- |
| PowerShell 7 (`pwsh`) on Windows | Runs the script |
| OpenSSH client (`ssh`, `scp`) | File transfer and remote commands |
| `tar.exe` (built into Windows 10 and later) | Builds the deployment bundle |
| Git (optional) | Enables the pull guard against overwriting uncommitted changes |
| Python 3 with `ruamel.yaml` and PyYAML (optional) | Canonical formatting and the semantic diff. Without it, the script says so once and falls back to a text comparison |
| Python package `websockets` (optional) | The log check of `ha_snapshot.py`. Without it, that check is skipped with a warning |

```powershell
pip install ruamel.yaml pyyaml websockets
```

On Home Assistant:

- The **Advanced SSH & Web Terminal** add-on, with SSH access to `/config`.
- A **long-lived access token** (your profile → Security → Long-lived access tokens).

## Installation

### 1. Folder layout

The repository is a mirror of `/config`. The scripts go into a `Tools` folder in the repository root:

```text
my-ha-config/              <- mirror of /config
├── .env                   <- credentials, never committed
├── configuration.yaml
├── automations.yaml
├── packages/
└── Tools/
    ├── ha_control.ps1
    ├── ha_yaml.py
    ├── ha_snapshot.py
    └── .deployignore
```

`ha_control.ps1` and `ha_snapshot.py` read `..\.env`. `ha_control.ps1` finds `ha_yaml.py` and `.deployignore` next to itself. Keep these files together.

### 2. Credentials: `.env`

Create `.env` in the repository root:

```ini
HA_URL=http://homeassistant.local:8123
HA_TOKEN=<your long-lived access token>
HA_SSH_USER=<ssh user of the add-on>
HA_SSH_HOST=homeassistant.local
HA_SSH_PORT=22
```

All five values are required. The script stops with a clear message when one is missing.

> [!WARNING]
> `.env` holds your token. Add it to `.gitignore` and never commit it. If a token leaks, revoke it in Home Assistant and create a new one.

### 3. SSH authentication

The script calls `ssh` and `scp` directly, so it uses your normal OpenSSH setup. Use an SSH key (in `~/.ssh` or loaded in `ssh-agent`) and add the public key to the add-on configuration. Otherwise every transfer asks for a password.

The script requests the `aes256-gcm@openssh.com` cipher and the legacy SCP protocol (`scp -O`). The Advanced SSH & Web Terminal add-on supports both.

### 4. Deployment exclusions: `.deployignore`

`-Deploy` bundles the whole repository except the entries in `Tools\.deployignore`. Start from the sample in this folder and add your own repository-only folders.

> [!IMPORTANT]
> Keep `.env`, `.git` and `.storage` in `.deployignore`. Without the file, a full deploy uploads your credentials and Git history into `/config`.

Each line becomes one `tar --exclude=<pattern>` argument. These are tar globs, not gitignore patterns:

| Pattern | Excludes |
| --- | --- |
| `docs` | every folder named `docs`, at any depth |
| `./docs` | only the `docs` folder in the root (GNU tar; bsdtar treats it like the bare form) |
| `*.md` | every Markdown file, at any depth |

## Commands

Run the script from the repository root (`.\Tools\ha_control.ps1`) or from the `Tools` folder (`.\ha_control.ps1`).

### Diff: preview changes

Downloads the remote files to a temporary folder outside the repository and compares them with your local copies. It changes nothing.

```powershell
.\Tools\ha_control.ps1 -Diff
.\Tools\ha_control.ps1 -Diff -File automations.yaml
```

Scope: root `*.yaml`, `packages/` and `custom_templates/`. `-Deploy` writes more than this; `.deployignore` defines the full bundle.

### Pull: sync down from Home Assistant

The HA web UI saves automations, scripts and scenes on the server. Pull them before you deploy, or your local copy overwrites them.

```powershell
.\Tools\ha_control.ps1 -Pull
.\Tools\ha_control.ps1 -Pull -File automations.yaml
```

Pull refuses to run when a file in its scope has uncommitted changes. Commit or stash first, or pass `-Force` to overwrite them.

### Deploy

Full deploy: bundles the configuration (with subfolders), copies it to Home Assistant and unpacks it into `/config`.

```powershell
.\Tools\ha_control.ps1 -Deploy -Verify
```

Single file:

```powershell
.\Tools\ha_control.ps1 -Deploy -File packages\pool_control.yaml -Verify
```

The upload is checked by sha256 against the server copy. A path outside the repository root is rejected.

> [!IMPORTANT]
> Always chain `-Verify` onto `-Deploy`. Without it, a deploy that uploads correctly but breaks the configuration counts as clean, and the backup is deleted.

### Remove: delete retired files on the server

`-Deploy` never deletes a file on the server. When you merge a file into another one, or retire it, the old copy stays in `/config` and Home Assistant loads both. Two packages with the same keys make Home Assistant reject the configuration.

Delete the file from the repository first, then remove it on the server:

```powershell
.\Tools\ha_control.ps1 -Remove packages\dehumidifier_card.yaml -Deploy -File packages\dehumidifier.yaml -Verify -Reload
.\Tools\ha_control.ps1 -Remove groups.yaml,lights.yaml -Verify
```

- `-Remove` needs `-Verify` and runs before `-Deploy`. A merge step removes the old file and uploads the new one before Home Assistant checks either.
- Each file is moved to `<file>.ha_bak` first. The copy is deleted when `-Verify` passes, and moved back when the check fails or the run stops part way.
- Only `.yaml`, `.yml` and `.jinja` files inside `/config`, never `configuration.yaml` or `secrets.yaml`.
- A file that still exists locally is refused: the next full deploy would upload it again.
- `-Diff` lists files that exist only on the server, with the `-Remove` command to delete them.

### Fetch: copy other server files, read only

`-Pull` covers only the YAML scope. `-Fetch` copies any file under `/config` to a local folder, for example the `.storage` files that UI integrations and dashboards use. It never writes to the server.

```powershell
.\Tools\ha_control.ps1 -Fetch '.storage/lovelace*'
.\Tools\ha_control.ps1 -Fetch 'home-assistant.log.1' -OutDir C:\temp\ha
```

- The path is relative to `/config`. `*` and `?` are allowed; other special characters, a leading `/` and `..` are refused.
- Without `-OutDir`, files go to `%TEMP%\ha_control_fetch`, outside the repository. `.storage` files can hold tokens and personal data, so do not commit them.
- The script lists the files this run wrote.

> [!CAUTION]
> Read `.storage` files, never edit them by hand. Home Assistant overwrites them, and a broken file can stop an integration from loading. Make changes through the UI or the API.

### App: install or update a local app (add-on)

```powershell
.\Tools\ha_control.ps1 -App ..\my-app-repo\my_app
.\Tools\ha_control.ps1 -App ..\my-app-repo\my_app -WhatIf
```

`-App` takes the app folder itself (the folder with `config.yaml`), relative to where you run the command. It:

1. checks the folder: a `config.yaml` with a `slug`, and LF line endings in every `.sh` file (a CRLF line ending on the shebang line stops the container);
2. packs the folder without `__pycache__`, uploads it and checks the upload;
3. puts it in `/addons/<slug>`: it extracts next to the old copy, then swaps them, so a failed extract keeps the old copy;
4. runs `ha store reload`;
5. installs and starts `local_<slug>` when it is new, runs `ha apps update` when the version in `config.yaml` went up, or `ha apps rebuild` when the version is the same;
6. shows the last 15 lines of the app log.

The upload takes the folder as it is on disk, committed or not. The first build of the image on the host takes a few minutes. Set app options, such as a token, in the Home Assistant UI under Settings → Apps, never in the folder.

### Verify

Asks Home Assistant to check the configuration on the server.

```powershell
.\Tools\ha_control.ps1 -Verify
```

### Reload

Applies changes without a restart. The default target is `All`.

```powershell
.\Tools\ha_control.ps1 -Reload
.\Tools\ha_control.ps1 -Reload -Target Automations
```

| Target | Reloads |
| --- | --- |
| `All` | every YAML domain (`reload_all`), themes, custom Jinja templates |
| `Core` | core configuration |
| `Automations` | automations |
| `Scripts` | scripts |
| `TemplateEntities` | template entities (`template.reload`) |
| `Themes` | frontend themes |
| `Rest` | REST commands |
| `Templates` | custom Jinja templates in `custom_templates/` |

`All` briefly unloads every YAML domain. An automation that runs at that moment can fail, for example with "script not found". Prefer the smallest target that covers your change.

Some YAML integrations have no reload service, for example `utility_meter` and the `integration` sensor platform. A change to those needs a restart.

### Restart

```powershell
.\Tools\ha_control.ps1 -Restart
.\Tools\ha_control.ps1 -Restart -RestartTimeoutSeconds 600
```

The script waits until Home Assistant has stopped and its core state is `RUNNING` again, so a chained command runs against a fully started instance. The API answers before startup finishes, so the script checks the core state rather than waiting for an answer. It exits non-zero when Home Assistant does not stop within 60 s, or does not finish starting within the timeout (default 300 s, range 10–3600 s).

### Chain commands

```powershell
.\Tools\ha_control.ps1 -Pull
.\Tools\ha_control.ps1 -Deploy -File automations.yaml -Verify -Reload -Target Automations
```

The order is fixed: Fetch, Pull, Diff, Remove, Deploy, Verify, Reload, Restart, App.

### All parameters

| Parameter | Effect |
| --- | --- |
| `-Diff` | Compare local and remote files |
| `-Pull` | Download remote files |
| `-Deploy` | Upload files, with a server-side backup |
| `-File <path>` | Limit `-Diff`, `-Pull` or `-Deploy` to one file |
| `-Remove <path>[,<path>…]` | Delete retired YAML files on the server; needs `-Verify` |
| `-Fetch <path>` | Copy files under `/config` to a local folder, read only |
| `-OutDir <folder>` | Target folder for `-Fetch` (default `%TEMP%\ha_control_fetch`) |
| `-App <folder>` | Install or update a local app (add-on) |
| `-Verify` | Check the configuration on the server; roll back a deploy or remove if it is invalid |
| `-Reload` | Reload without restart |
| `-Target <name>` | Reload target (see the table above) |
| `-Restart` | Restart Home Assistant and wait until startup has finished |
| `-RestartTimeoutSeconds <n>` | Restart wait limit (default 300) |
| `-Force` | Let `-Pull` overwrite files with uncommitted changes |
| `-NoFormat` | Skip the canonical reformat of local files |
| `-WhatIf` / `-Confirm` | Dry run / confirm each remote write |

## Rollback

`-Deploy` and `-Remove` take a backup on the server before they write:

- single file or removed file: `<file>.ha_bak` next to the target;
- full deploy: `/config/.ha_control_deploy_backup.tar`, holding exactly the top-level paths the bundle overwrites.

The backup is restored when the run stops part way, and when `-Verify` reports an invalid configuration. It is deleted after a clean run, so it never outlives the command. If the restore itself fails, the script prints the path of the backup left on the server and exits non-zero.

## Check a move: ha_snapshot.py

`ha_snapshot.py` only reads. It records the state machine before a step and compares it after the step. Use it for every move of automations, scripts or template entities between files: a move that goes wrong shows up as a missing entity, a `_2` duplicate, an entity that turns unavailable, or a "duplicate" line in the log.

```powershell
python Tools\ha_snapshot.py snapshot --out $env:TEMP\before.json
# ... edit, -Remove / -Deploy -Verify, -Reload or -Restart ...
python Tools\ha_snapshot.py compare $env:TEMP\before.json --states "sensor.washer_*"
```

`compare` reports, and exits `1` on:

- entities that disappeared;
- new `_2`-style duplicates (the answer of Home Assistant to a duplicate `unique_id`);
- entities that went `unavailable` or `unknown`;
- state differences for the `--states` globs (the entities the step moved);
- new log entries about duplicates, invalid configuration or failed setups.

It also prints the automation, script and entity counts. Exit code `0` means no differences that point to a broken move; `2` means the check could not run.

Without `--out`, snapshots go to `%TEMP%\ha_snapshot\`, outside the repository: states include presence and other personal data. Without an `AFTER` file, `compare` reads the live state. Live sensor values change, so choose the `--states` globs with care.

## YAML formatting

`-Diff`, `-Pull` and `-Deploy` first rewrite local YAML into one canonical format with `ha_yaml.py`. This stops files from changing back and forth between the repository, the Studio Code Server add-on and the HA web UI editors.

- Comments, key order, `!secret` tags and block scalars are kept (ruamel round-trip).
- The formatter reads YAML 1.1, like Home Assistant. Values such as `on`, `off`, `yes` and `no` keep their meaning.
- Every result is checked with PyYAML, the loader Home Assistant uses. A file whose meaning would change is never written. ruamel and PyYAML disagree on plain `y` and `n`, for example.
- `-Diff` compares by meaning, so pure formatting differences show as identical.

Pass `-NoFormat` to leave local files untouched.

## Dry run

```powershell
.\Tools\ha_control.ps1 -Deploy -WhatIf
```

Builds the bundle and reports its size, entry count and top-level members. Lists every remote write it would perform, without doing any of them. `-Confirm` asks before each write.

## Exit codes

`0` on success. `1` on any failure: a failed upload, a failed verification, a failed reload or restart, a restart timeout or a failed rollback. Check `$LASTEXITCODE` when you script around it.

## ha_yaml.py on its own

```text
python ha_yaml.py format <file> [<file> ...]   # rewrite in place if changed
python ha_yaml.py diff   <local> <remote> [name]
```

| Command | Exit code | Meaning |
| --- | --- | --- |
| `format` | `0` | Done. Each file is reported as formatted or unchanged |
| `format` | `1` | A file could not be parsed, or formatting would change its meaning. The file is left untouched |
| `diff` | `0` | Same meaning |
| `diff` | `1` | Different. A unified diff of the canonical form is printed |
| `diff` | `2` | Could not parse, or the canonical form hides a difference that Home Assistant sees. Fall back to a text diff |

## Troubleshooting

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `.env file not found at …` | `.env` is not in the repository root, one level above `Tools` | Move `.env` to the root |
| `.env has no value for: …` | A required key is empty or missing | Fill in all five keys |
| `Pull would overwrite these files` | Uncommitted local changes inside the pull scope | Commit or stash, or use `-Force` |
| Formatting skipped, text comparison used | Python, `ruamel.yaml` or PyYAML not found | `pip install ruamel.yaml pyyaml` |
| Password prompt on every transfer | No SSH key set up | Add your public key to the add-on configuration |
| `Home Assistant did not answer within … s` | The restart takes longer than the timeout | Raise `-RestartTimeoutSeconds`, then check the HA log |
| Deploy rolled back after `-Verify` | The configuration on the server is invalid | Run `-Verify` again for the error, fix it locally, deploy again |
| An automation fails during a reload | `-Reload` (All) unloaded the domain it uses | Reload only the target you changed |
| `-Remove` refuses a file | The file still exists locally, or it is not a `.yaml`, `.yml` or `.jinja` file inside `/config` | Delete it from the repository first; remove other files by hand |
| `-Remove` stops with a backup that already exists | A `<file>.ha_bak` from an earlier run is still on the server | Check that copy, delete it, run again |
| App container stops at once after `-App` | A `.sh` file has CRLF line endings | `-App` refuses such a folder; convert the file to LF |
| `ha_snapshot.py` warns that the log check needs `websockets` | The Python package is missing | `pip install websockets` |

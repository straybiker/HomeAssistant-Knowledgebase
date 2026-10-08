# ha_control.ps1 and ha_yaml.py manual

`ha_control.ps1` moves Home Assistant YAML configuration between a local repository and the live `/config` folder over SSH. It also verifies, reloads and restarts Home Assistant through the REST API.

`ha_yaml.py` gives all YAML files one canonical format and compares files by meaning instead of by text. `ha_control.ps1` calls it automatically.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Commands](#commands)
- [Rollback](#rollback)
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

```powershell
pip install ruamel.yaml pyyaml
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
    └── .deployignore
```

The script reads `..\.env` and finds `ha_yaml.py` and `.deployignore` next to itself. Keep these three files together.

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

The order is fixed: Pull, Diff, Deploy, Verify, Reload, Restart.

### All parameters

| Parameter | Effect |
| --- | --- |
| `-Diff` | Compare local and remote files |
| `-Pull` | Download remote files |
| `-Deploy` | Upload files, with a server-side backup |
| `-File <path>` | Limit `-Diff`, `-Pull` or `-Deploy` to one file |
| `-Verify` | Check the configuration on the server; roll back a deploy if it is invalid |
| `-Reload` | Reload without restart |
| `-Target <name>` | Reload target (see the table above) |
| `-Restart` | Restart Home Assistant and wait until startup has finished |
| `-RestartTimeoutSeconds <n>` | Restart wait limit (default 300) |
| `-Force` | Let `-Pull` overwrite files with uncommitted changes |
| `-NoFormat` | Skip the canonical reformat of local files |
| `-WhatIf` / `-Confirm` | Dry run / confirm each remote write |

## Rollback

`-Deploy` takes a backup on the server before it writes:

- single file: `<file>.ha_bak` next to the target;
- full deploy: `/config/.ha_control_deploy_backup.tar`, holding exactly the top-level paths the bundle overwrites.

The backup is restored when the deployment stops part way, and when `-Verify` reports an invalid configuration. It is deleted after a clean run, so it never outlives the command. If the restore itself fails, the script prints the path of the backup left on the server and exits non-zero.

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

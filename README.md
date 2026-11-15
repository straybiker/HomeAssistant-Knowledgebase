# Home Assistant Knowledgebase

A collection of guides, scripts, and documentation for Home Assistant configuration, debugging, and deployment.

## 📚 Guides

### [WH52 YAML Bridge](guides/WH52_YAML_BRIDGE.md)
**Decode Ecowitt WH52 soil sensors in Home Assistant using pure YAML (no Python required)**

A temporary bridge for integrating Ecowitt / Fine Offset WH52 3-in-1 soil sensors (moisture, temperature, EC) into Home Assistant using MQTT and HA automations.

- Setup with RTL-HAOS add-on
- Flex decoder configuration
- Complete YAML package template with calibration guide
- Troubleshooting
- Upgrade path to native rtl_433 support (protocol 353)

### [Poolstation Modbus Migration](guides/POOLSTATION_MODBUS_MIGRATION.md)
**HTTP to Modbus TCP migration for Idegis pool controller**

Complete guide for migrating from HTTP-based pool control to native Modbus TCP integration. Includes entity renaming, YAML updates, and rollback procedures.

- 53 Modbus entities mapped
- Automated and manual migration steps
- Entity renaming from `idegis_domotic_*` to `poolcontroller_*`
- Comprehensive troubleshooting
- Rollback instructions if needed

---

## 🛠️ Scripts

### [ha_control.ps1](scripts/ha_control.ps1)
**Deploy Home Assistant YAML configuration from a Git repository over SSH**

- Diff, pull and deploy between the repository and `/config`. A single-file upload is checked by sha256.
- `-Remove` deletes retired files on the server, which `-Deploy` never does, so a merged package does not load twice.
- Server-side backup before every deploy and remove. It is restored automatically when the run fails or `-Verify` reports an invalid configuration.
- Pull refuses to overwrite uncommitted local changes.
- `-Fetch` copies other server files, such as `.storage`, read only to a folder outside the repository.
- `-App` installs or updates a local app (add-on) from its folder.
- Reload one domain (automations, scripts, template entities, …) or restart, and wait until startup has finished.
- Dry run with `-WhatIf`. Exit code `1` on any failure.

### [ha_snapshot.py](scripts/ha_snapshot.py)
**Before/after check for a configuration move**

Records all entities before a step and reports what the step broke: missing entities, `_2` duplicates, entities that turned unavailable, and new duplicate or invalid-config errors in the log. Read only.

### [ha_yaml.py](scripts/ha_yaml.py)
**Canonical YAML formatting and diff by meaning**

Keeps comments, key order and `!secret` tags. Reads YAML 1.1 like Home Assistant, and never writes a file whose meaning would change. `ha_control.ps1` calls it automatically.

### [.deployignore](scripts/.deployignore)
**Sample deployment exclusions.** Keeps `.env`, `.git` and other repository-only files out of `/config`.

### [Scripts Manual](scripts/MANUAL.md)
**Setup, commands, rollback, formatting and troubleshooting for the scripts.**

---

## 🏠 Related Home Assistant Projects

### Pool Management
- [homeassistant-poolstation](https://github.com/straybiker/homeassistant-poolstation) — Pool management custom component
- [PyPoolstation](https://github.com/straybiker/PyPoolstation) — Python library for Poolstation

### Smart Home Automation
- [HA EV Charge Control](https://github.com/straybiker/HA-EV-Charge-Control) — Home Assistant integration for EV smart charging: solar, EMS, price and the capacity tariff

### Tools & Libraries
- [IdegisModbus](https://github.com/straybiker/IdegisModbus) — Modbus utilities for Idegis devices
- [alfen_modbus](https://github.com/straybiker/alfen_modbus) — Modbus integration for Alfen EV chargers
- [HA_AI_Analyzer](https://github.com/straybiker/HA_AI_Analyzer) — AI-powered Home Assistant log analysis


---

## 📋 Quick Start

Put the files from `scripts/` into a `Tools` folder in your configuration repository, and create `.env` in the repository root. See the [Scripts Manual](scripts/MANUAL.md#installation).

```powershell
.\Tools\ha_control.ps1 -Diff                                        # preview, changes nothing
.\Tools\ha_control.ps1 -Pull                                        # get UI-made changes first
.\Tools\ha_control.ps1 -Deploy -File automations.yaml -Verify -Reload -Target Automations
.\Tools\ha_control.ps1 -Deploy -Verify                              # full deploy, always with -Verify
.\Tools\ha_control.ps1 -Remove packages\old.yaml -Verify            # delete a retired file on the server
```

---

## 📄 License

MIT License — see [LICENSE](LICENSE)

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
**PowerShell automation for Home Assistant config deployment**

Deploy, verify, and manage your Home Assistant configuration from the command line.

**Features:**
- Deploy config files to HA via SSH/SCP
- Verify YAML syntax before deployment
- Reload specific HA domains (automations, scripts, templates, etc.)
- Restart Home Assistant with confirmation
- Automatic backup on deploy with rollback on failure

**Usage:**
```powershell
.\ha_control.ps1 -Deploy -Verify -Restart
.\ha_control.ps1 -Pull
.\ha_control.ps1 -Diff
.\ha_control.ps1 -Reload -Target Automations
```

### [ha_yaml.py](scripts/ha_yaml.py)
**YAML formatting and diffing utility**

Provides canonical YAML formatting and smart diffs that ignore whitespace changes.

### [Scripts Manual](guides/SCRIPTS_MANUAL.md)
**Complete guide for ha_control.ps1 and ha_yaml.py**

Comprehensive documentation for Home Assistant deployment automation tools.

- ha_control.ps1 setup and usage
- ha_yaml.py formatting and diffing
- Common workflows and examples
- Troubleshooting and best practices
- Integration with Git and CI/CD

---

## 🏠 Related Home Assistant Projects

### Pool Management
- [homeassistant-poolstation](https://github.com/<YOUR_USERNAME>/homeassistant-poolstation) — Pool management custom component
- [homeassistant-vistapool-modbus](https://github.com/<YOUR_USERNAME>/homeassistant-vistapool-modbus) — Vista pool Modbus integration
- [PyPoolstation](https://github.com/<YOUR_USERNAME>/PyPoolstation) — Python library for Poolstation

### Smart Home Automation
- [EV_Loadbalancer](https://github.com/<YOUR_USERNAME>/EV_Loadbalancer) — Smart EV charging load management and balancing

### Tools & Libraries
- [IdegisModbus](https://github.com/<YOUR_USERNAME>/IdegisModbus) — Modbus utilities for Idegis devices
- [alfen_modbus](https://github.com/<YOUR_USERNAME>/alfen_modbus) — Modbus integration for Alfen EV chargers
- [HA_AI_Analyzer](https://github.com/<YOUR_USERNAME>/HA_AI_Analyzer) — AI-powered Home Assistant log analysis

> **Note:** Replace `username` with your GitHub username in the links above

---

## 📋 Quick Start

```powershell
# Deploy and verify:
cd HomeAssistant/Tools
.\ha_control.ps1 -Deploy -Verify -Restart

# Check changes before deploying:
.\ha_control.ps1 -Diff

# Reload without restarting:
.\ha_control.ps1 -Reload -Target Automations
```

---

## 📄 License

MIT License — see [LICENSE](LICENSE)

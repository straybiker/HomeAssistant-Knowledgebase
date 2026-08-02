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

**Key Features:**
- Deploy config files to HA via SSH/SCP with automatic backups
- Verify YAML syntax before deployment (with automatic rollback on failure)
- Reload specific HA domains (automations, scripts, templates, etc.) without restart
- Restart Home Assistant safely with verification checks
- Complete audit trail and timestamped backups

**Quick Usage:**
```powershell
.\ha_control.ps1 -Deploy -Verify -Restart   # Safe full deployment
.\ha_control.ps1 -Pull                      # Sync config from HA
.\ha_control.ps1 -Diff                      # Preview changes
.\ha_control.ps1 -Reload -Target Automations # Fast reload
```

**📖 See also:** [ha_control.ps1 Detailed Reference](guides/HA_CONTROL_DETAILED.md) for credentials setup, -Verify/rollback behavior, failure scenarios, and advanced configuration.

### [ha_yaml.py](scripts/ha_yaml.py)
**YAML formatting and diffing utility**

Provides canonical YAML formatting and smart diffs that ignore whitespace changes.

### [Scripts Manual](scripts/MANUAL.md)
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
- [homeassistant-poolstation](https://github.com/straybiker/homeassistant-poolstation) — Pool management custom component
- [PyPoolstation](https://github.com/straybiker/PyPoolstation) — Python library for Poolstation

### Smart Home Automation
- [EV_Loadbalancer](https://github.com/straybiker/EV_Loadbalancer) — Smart EV charging load management and balancing

### Tools & Libraries
- [IdegisModbus](https://github.com/straybiker/IdegisModbus) — Modbus utilities for Idegis devices
- [alfen_modbus](https://github.com/straybiker/alfen_modbus) — Modbus integration for Alfen EV chargers
- [HA_AI_Analyzer](https://github.com/straybiker/HA_AI_Analyzer) — AI-powered Home Assistant log analysis


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

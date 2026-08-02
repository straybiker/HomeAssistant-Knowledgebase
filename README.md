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

---

## 🏠 Related Home Assistant Projects

- [homeassistant-poolstation](https://github.com/username/homeassistant-poolstation) — Pool management custom component
- [homeassistant-vistapool-modbus](https://github.com/username/homeassistant-vistapool-modbus) — Vista pool Modbus integration
- [PyPoolstation](https://github.com/username/PyPoolstation) — Python library for Poolstation

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

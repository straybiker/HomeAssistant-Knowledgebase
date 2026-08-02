# Pool Controller: HTTP → Modbus TCP Migration Guide

**Status**: Ready for execution  
**Date**: 2026-07-30  
**Entities**: 53 Modbus entities mapped  
**References**: 62 YAML references to update

---

## What This Migration Does

### Entity Renaming
Renames Modbus entities from their default names to `poolcontroller_*` prefix:

| Current Entity | New Entity | Device |
|---|---|---|
| `switch.idegis_domotic_pool_pump` | `switch.poolcontroller_pool_pump` | Main pump |
| `switch.idegis_domotic_relay_square` | `switch.poolcontroller_relay_1400rpm` | Speed 1 |
| `switch.idegis_domotic_relay_triangle` | `switch.poolcontroller_relay_2400rpm` | Speed 2 |
| `switch.idegis_domotic_pool_led_light` | `switch.poolcontroller_relay_2900rpm` | Speed 3 |
| `sensor.zwembad_idegis_domotic_current_ph` | `sensor.poolcontroller_current_ph` | pH |
| `sensor.zwembad_idegis_domotic_current_orp` | `sensor.poolcontroller_current_orp` | ORP |
| `sensor.zwembad_idegis_domotic_salt_concentration` | `sensor.poolcontroller_salt_concentration` | Salinity |
| `sensor.zwembad_idegis_domotic_water_temperature` | `sensor.poolcontroller_water_temperature` | Temperature |
| `sensor.zwembad_idegis_domotic_electrolysis_production` | `sensor.poolcontroller_electrolysis_production` | Electrolysis % |
| `number.zwembad_idegis_domotic_target_ph` | `number.poolcontroller_target_ph` | Target pH |
| `number.zwembad_idegis_domotic_target_orp` | `number.poolcontroller_target_orp` | Target ORP |
| `number.zwembad_idegis_domotic_target_electrolysis_production` | `number.poolcontroller_target_electrolysis_production` | Target Electrolysis |
| `binary_sensor.zwembad_idegis_domotic_water_flow_problem` | `binary_sensor.poolcontroller_water_flow_problem` | Flow alarm |
| `binary_sensor.zwembad_idegis_domotic_uv_light` | `binary_sensor.poolcontroller_uv_light` | UV status |
| `binary_sensor.zwembad_idegis_domotic_uv_available` | `binary_sensor.poolcontroller_uv_available` | UV available |
| `binary_sensor.zwembad_idegis_domotic_uv_enabled` | `binary_sensor.poolcontroller_uv_enabled` | UV enabled |

### File Updates
1. **`scripts.yaml`**: Updates 30 entity references in `set_pool_pump` script
2. **`automations.yaml`**: Updates 32 entity references across 10+ pool automations
3. **`configuration.yaml`**: Updates logging (removes poolstation, adds idegis_modbus)
4. **Lovelace dashboards**: Updates dashboard cards with new entity IDs

### What Stays Unchanged
- **HTTP integration** (`zwembadcontroller_*` entities) remains untouched for safety
- **Custom component code** is not modified (maintains HACS compatibility)
- **Backup copies** are created before any changes

---

## Migration Steps

### Step 0: Dry Run (Recommended)
```powershell
cd C:\Users\stray\OneDrive\Projects\HomeAssistant\Tools

# Check prerequisites
.\MIGRATE.ps1 -Mode Check

# Run dry run to see what will change
.\MIGRATE.ps1 -Mode Migrate -DryRun
```

### Step 1: Full Migration
```powershell
# Execute the complete migration
.\MIGRATE.ps1 -Mode Full

# Or run each step manually:
.\MIGRATE.ps1 -Mode Migrate     # Update YAML files
.\MIGRATE.ps1 -Mode Verify      # Deploy and verify config
```

### Step 2: Manual Verification in Home Assistant
After running the migration script:

1. **Check Lovelace Dashboards**
   - Open Home Assistant UI at `http://ha.local:8123`
   - Go to each dashboard (Desktop, Mobile, etc.)
   - Verify pool cards display the correct entities with no "unknown" states

2. **Test Pool Pump Control**
   - Navigate to area "Zwembad" (Pool)
   - Find the pool pump control
   - Test sequence: Off → Low (1400 RPM) → Medium (2400 RPM) → High (2900 RPM) → Off
   - Verify actual pump adjusts speed in pool controller device

3. **Test Setpoint Updates**
   - Change Target pH from 7.2 → 7.5 → 7.2
   - Change Target ORP from 700 → 750 → 700
   - Change Target Electrolysis Production from 0 → 50 → 0
   - Verify changes reflect on the Idegis controller display

4. **Check Automations**
   - Developer Tools → Automations
   - Find: "Pool pump update RPM", "Pool update salinity", "Pool: Master RPM Controller"
   - Verify they're all in state "on"
   - Monitor logbook for any errors

5. **Monitor Logs**
   - Go to Settings → System → Logs
   - Search for "pool", "idegis", "modbus"
   - Ensure no error messages (warnings about unavailable HTTP entities are OK)

---

## Rollback (If Needed)

### Option 1: Quick Rollback
```powershell
# Restore from backup created during migration
Copy-Item -Path "C:\Users\stray\OneDrive\Projects\HomeAssistant\backups\migration_*\*" `
          -Destination "C:\Users\stray\OneDrive\Projects\HomeAssistant" -Force

# Reload HA config
.\ha_control.ps1 -Reload
```

### Option 2: Git Rollback
```bash
git status                    # See what changed
git diff scripts.yaml         # Review changes
git checkout scripts.yaml     # Revert a file
git checkout automations.yaml
```

---

## File Details

### `migrate_pool_modbus.py`
Python script that:
- Updates entity IDs in YAML files (scripts.yaml, automations.yaml, configuration.yaml)
- Updates entity IDs in Lovelace storage JSON files
- Creates backups before modifications
- Logs all changes made

**Usage:**
```bash
python3 migrate_pool_modbus.py --ha-config "C:/Users/stray/OneDrive/Projects/HomeAssistant" --dry-run
```

### `rename_entities.ps1`
PowerShell script that:
- Connects to Home Assistant API
- Finds entities with `idegis_domotic_` in their names
- Renames them to `poolcontroller_*` prefix via REST API

**Usage:**
```powershell
.\rename_entities.ps1 -HaUrl "http://ha.local:8123" -HaToken "..." -DryRun
```

### `MIGRATE.ps1`
Master orchestration script that:
- Runs all migration steps in correct order
- Creates backups before changes
- Verifies configuration syntax
- Deploys changes to Home Assistant
- Supports multiple modes: Check, Migrate, Verify, Full

**Modes:**
- `Check`: Verify prerequisites only
- `Migrate`: Update YAML files and rename entities
- `Verify`: Deploy config to HA
- `Full`: Execute complete migration (backup → update → deploy → test)
- `Rollback`: Instructions for rolling back

---

## Troubleshooting

### Issue: "Entity not found in registry"
**Cause**: The Modbus integration hasn't created the entity yet.  
**Fix**: 
1. Check Modbus TCP connection to device (IP 192.168.3.23:502)
2. Verify `idegis_modbus` integration is loaded
3. Restart Home Assistant: Settings → System → Restart

### Issue: Automations still reference old entity IDs
**Cause**: Script didn't find them in automations.yaml  
**Fix**:
1. Manually search in automations.yaml for `zwembadcontroller_`
2. Replace with `poolcontroller_` equivalents from the table above
3. Reload automations

### Issue: Lovelace dashboards show "unknown" entities
**Cause**: Dashboard cards reference old entity IDs  
**Fix**:
1. The migration script should have updated `.storage/lovelace*` files
2. If manually editing: Edit card → Change entity ID → Save
3. Clear browser cache (Ctrl+Shift+Delete)
4. Hard refresh HA UI (Ctrl+F5)

### Issue: Pool pump doesn't respond to commands
**Cause**: Modbus communication issue  
**Fix**:
1. Check Modbus device is online (ping 192.168.3.23)
2. Verify TCP port 502 is open and responding
3. Check HA logs for Modbus errors
4. Restart Modbus integration: Developer Tools → Services → modbus.restart

---

## Success Criteria

✓ All `poolcontroller_*` entities show live data in Home Assistant  
✓ Pool pump responds to speed control commands  
✓ Setpoint changes (pH, ORP, Electrolysis) update on device  
✓ Pool automations trigger without errors  
✓ Lovelace dashboards display pool data correctly  
✓ No "unknown" states for pool entities  
✓ HTTP `zwembadcontroller_*` entities remain untouched  

---

## Post-Migration (Optional)

Once you're confident the Modbus integration is stable:

1. **Keep HTTP integration**: Running both in parallel provides fallback
2. **Monitor for 24-48 hours**: Ensure stability before final cleanup
3. **Remove HTTP integration**: When ready to fully switch

## Next Steps

1. Run: `.\MIGRATE.ps1 -Mode Check`
2. Review the output
3. Run: `.\MIGRATE.ps1 -Mode Full`
4. Follow manual verification steps
5. Report any issues

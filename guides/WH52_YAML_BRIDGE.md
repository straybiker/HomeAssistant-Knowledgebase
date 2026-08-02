# WH52 → Home Assistant (YAML-based decoder bridge)

A Home Assistant native approach to decode **Ecowitt / Fine Offset WH52** 3-in-1 soil sensors (soil moisture / temperature / electrical conductivity) using YAML automations and MQTT, until native `rtl_433` support becomes the standard.

**Status:** This is a temporary bridge. Once `rtl_433` ships with native WH52 (protocol 353) support in a stable release, you can simplify to a single `-R 353` flag and delete this automation entirely.

## What you need

1. **RTL-SDR + rtl_433** receiving WH52 transmissions with MQTT output
   - Recommended: [RTL-HAOS Home Assistant add-on](https://github.com/jaronmcd/rtl-haos)
   - Alternative: [rtl_433 (next) add-on by pbkhrv](https://github.com/pbkhrv/rtl_433-hass-addons)

2. **A flex decoder** configured in rtl_433 to emit raw WH52 frames:
   ```
   -X 'n=Ecowitt_WH52,m=FSK_PCM,s=58,l=58,r=5000,g=4000,t=5,preamble=aa2dd4a2,\
       get=id:@0:{24}:%x,\
       get=temp_raw:@24:{16},\
       get=moisture_raw:@40:{24},\
       get=ec_raw:@64:{24}'
   ```

3. **MQTT broker** (Home Assistant's built-in Mosquitto works fine)

4. **MQTT integration** enabled in Home Assistant

## How it works

The architecture is straightforward:

```
Ecowitt WH52 (868 MHz)
         ↓
    RTL-SDR + rtl_433
    (flex decoder)
         ↓
    MQTT: home/rtl_devices/unknown/rows_0_data (raw hex)
         ↓
    Home Assistant automation (packages/wh52.yaml)
    - Parses hex frame
    - Decodes per-sensor values
    - Publishes to: rtl_433/wh52/<id>
         ↓
    MQTT discovery entities (wh52_<id>_moisture, etc.)
         ↓
    Plant devices + automations
```

## Installation

### 1. Configure RTL-HAOS flex decoder

In your RTL-HAOS add-on settings, update the `rtl_433_args` to include the flex decoder:

```yaml
rtl_433_args: >-
  -R 142 -X 'n=Ecowitt_WH52,m=FSK_PCM,s=58,l=58,r=5000,g=4000,t=5,
  preamble=aa2dd4a2,
  get=id:@0:{24}:%x,
  get=temp_raw:@24:{16},
  get=moisture_raw:@40:{24},
  get=ec_raw:@64:{24}'
```

**Parameter notes:**
- `s=58, l=58` — bit period (µs)
- `r=5000` — reset timeout (higher = more forgiving)
- `g=4000, t=5` — gain and threshold (tuned for 868 MHz)
- `preamble=aa2dd4a2` — WH52 sync word
- `get=` fields — bit-level frame parsing

Save and restart the add-on.

### 2. Add the package to Home Assistant

Copy the `packages/wh52.yaml` file from this repository into your `packages/` directory.

**File location:** `config/packages/wh52.yaml`

This file contains:
- The MQTT parsing automation
- MQTT entity definitions for each sensor (8 entities per WH52)
- Binary sensors for soil contact detection

### 3. Update your recorder config

Edit `configuration.yaml` to exclude raw bridge entities (optional but recommended — cuts logbook writes by ~68%):

```yaml
recorder:
  exclude:
    entity_globs:
      # RTL_433 WH52 raw entities (all reshape via MQTT, safe to exclude)
      - sensor.ecowitt_wh52_unknown_*
```

Restart Home Assistant.

## Package template (packages/wh52.yaml)

Copy this template into `config/packages/wh52.yaml`. Replace `SENSOR_ID` with your actual WH52 hex ID, and repeat the sensor block for each unit.

### Finding your sensor ID

Check your RTL-HAOS or rtl_433 logs after a transmission. You'll see output like:
```
[JSONDUMP]: model=Ecowitt_WH52 id=5452 ...
```
The `id=5452` (or `507e`, `5425`, etc.) is your **3-digit hex sensor ID**. Use this ID everywhere in the template below.

### Template (single sensor)

```yaml
# =============================================================================
# WH52 — in-HA reshape + calibrated conversions + diagnostics (no ext. process)
# =============================================================================
# HA package: automation + mqtt (sensor & binary_sensor).
#
# Flow: RTL-HAOS flex -> home/rtl_devices/unknown/rows_0_data
#       -> automation parses/republishes -> rtl_433/wh52/<id> -> mqtt entities.
#
# TEMP WORD low 12 bits = temp (raw/10-40). Top bits = flags (NOT temp):
#   bit 13 (0x2000) = in air / no soil contact (confirmed)
#
# MOISTURE: per-sensor 2-point %, clamped 0-100
# EC: raw 16-bit, still uncalibrated.
# =============================================================================

automation:
  - alias: WH52 reshape to per-id topic
    mode: queued
    max: 10
    trigger:
      - platform: mqtt
        topic: home/rtl_devices/unknown/rows_0_data
    action:
      - variables:
          p: '{{ trigger.payload }}'
          id: "{{ '%x' | format(trigger.payload[0:6] | int(0, 16)) }}"
          tw: '{{ trigger.payload[6:10] | int(0, 16) }}'
      - condition: template
        value_template: '{{ p | length >= 22 }}'
      - action: mqtt.publish
        data:
          topic: rtl_433/wh52/{{ id }}
          retain: true
          payload: >-
            {"id":"{{ id }}",
             "temperature_C":{{ ((tw | bitwise_and(4095)) / 10 - 40) | round(1) }},
             "status":{{ tw // 4096 }},
             "in_air":{{ ((tw | bitwise_and(8192)) > 0) | int }},
             "batt_mv":{{ (p[26:28] | int(0,16)) * 10 }},
             "moisture_raw":{{ p[10:14] | int(0,16) }},
             "moisture_raw24":{{ p[10:16] | int(0,16) }},
             "ec_raw":{{ p[16:20] | int(0,16) }},
             "ec_raw24":{{ p[16:22] | int(0,16) }}}

mqtt:
  sensor:
    # ===== WH52 Sensor [replace SENSOR_ID with your 3-digit hex: 5452, 507e, etc.] =====
    - name: Temperature
      unique_id: wh52_SENSOR_ID_temp
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.temperature_C }}'
      device_class: temperature
      unit_of_measurement: °C
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID], name: Soil Sensor SENSOR_ID, model: WH52, manufacturer: Ecowitt / Fine Offset}
    
    - name: Soil moisture
      unique_id: wh52_SENSOR_ID_moisture
      state_topic: rtl_433/wh52/SENSOR_ID
      # Calibration formula: (raw - dry_point) / (wet_point - dry_point) * 100
      # Dry point: reading in completely dry soil (typical ~70–80)
      # Wet point: reading in saturated water (typical ~25,000–26,000)
      # Example below is tuned for sensor 5452; adjust for your unit
      value_template: '{{ [0, [100, (value_json.moisture_raw - 74) * 100 / 25727] | min] | max | round(1) }}'
      device_class: moisture
      unit_of_measurement: '%'
      icon: mdi:water-percent
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    - name: Soil EC
      unique_id: wh52_SENSOR_ID_ec
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.ec_raw }}'
      device_class: conductivity
      unit_of_measurement: µS/cm
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    # --- Diagnostic entities ---
    - name: Moisture raw
      unique_id: wh52_SENSOR_ID_moist_raw
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.moisture_raw }}'
      entity_category: diagnostic
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    - name: Moisture raw 24-bit
      unique_id: wh52_SENSOR_ID_moist_raw24
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.moisture_raw24 }}'
      entity_category: diagnostic
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    - name: EC raw 24-bit
      unique_id: wh52_SENSOR_ID_ec_raw24
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.ec_raw24 }}'
      entity_category: diagnostic
      state_class: measurement
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    - name: Status nibble
      unique_id: wh52_SENSOR_ID_status
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.status }}'
      entity_category: diagnostic
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
    
    - name: Battery (unverified)
      unique_id: wh52_SENSOR_ID_battmv
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.batt_mv }}'
      device_class: voltage
      unit_of_measurement: mV
      state_class: measurement
      entity_category: diagnostic
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}

  binary_sensor:
    # In-air contact flag (bit 13) — raises if sensor loses soil contact
    - name: In air
      unique_id: wh52_SENSOR_ID_inair
      state_topic: rtl_433/wh52/SENSOR_ID
      value_template: '{{ value_json.in_air }}'
      payload_on: '1'
      payload_off: '0'
      device_class: problem
      entity_category: diagnostic
      expire_after: 600
      device: {identifiers: [wh52_SENSOR_ID]}
```

### Setup steps

1. **Find your sensor ID** from the logs (see section above)
2. **Replace all `SENSOR_ID` placeholders** with your actual 3-digit hex ID (e.g., `5452`, `507e`)
3. **Calibrate moisture** (optional but recommended):
   - Read the sensor in completely dry soil → note `moisture_raw` value
   - Read the sensor in saturated water → note `moisture_raw` value
   - Update the formula: `(value_json.moisture_raw - DRY) * 100 / (WET - DRY)`
4. **Save as `packages/wh52.yaml`** and restart Home Assistant

### Adding more sensors

For each additional WH52 unit, duplicate the entire `sensor:` and `binary_sensor:` block and change `SENSOR_ID` to your new unit's hex ID. The **automation block stays the same** — it handles all sensors automatically.

Example with 2 sensors:
```yaml
automation:
  - alias: WH52 reshape...  # shared by all sensors

mqtt:
  sensor:
    # Sensor 1 (5452)
    - name: Temperature
      unique_id: wh52_5452_temp
      state_topic: rtl_433/wh52/5452
      ...
    
    # Sensor 2 (507e)
    - name: Temperature
      unique_id: wh52_507e_temp
      state_topic: rtl_433/wh52/507e
      ...
```

## Entities created per sensor

Each WH52 sensor ID creates a **device** `wh52_<id>` with 8 entities:

### Sensor entities
- `sensor.wh52_<id>_temperature` — °C, device_class: temperature
- `sensor.wh52_<id>_soil_moisture` — %, device_class: moisture (converted to 0–100 scale)
- `sensor.wh52_<id>_soil_ec` — µS/cm (raw counts, uncalibrated)

### Diagnostic entities
- `sensor.wh52_<id>_moisture_raw` — 16-bit raw ADC value
- `sensor.wh52_<id>_moisture_raw_24_bit` — 24-bit raw (before /256 conversion)
- `sensor.wh52_<id>_ec_raw_24_bit` — 24-bit raw EC counts
- `sensor.wh52_<id>_status` — status nibble (diagnostic)
- `sensor.wh52_<id>_battery_unverified` — mV (placeholder, verify by watching drift as cell ages)

### Binary sensor
- `binary_sensor.wh52_<id>_in_air` — problem class; triggers if no soil contact detected

Example entity IDs from the sample setup:
- `sensor.wh52_5452_temperature`
- `sensor.wh52_5452_soil_moisture`
- `sensor.wh52_5452_soil_ec`

## Using with automations and plants

The soil moisture entities can be used in automations or linked to plant devices. Example:

```yaml
plant:
  my_plant:
    sensors:
      moisture: sensor.wh52_5452_soil_moisture
      temperature: sensor.wh52_5452_temperature
      conductivity: sensor.wh52_5452_soil_ec
```

## Decoding reference (reverse-engineered)

Frame structure (24 bytes, Big-Endian):

```
Bytes 0–2:    Device ID (24-bit, unique per sensor)
Bytes 3–4:    Temperature word
              - Bottom 12 bits: raw temperature value
              - Bits 13–15: retry counter (masked in automation)
              - Bit 13: in-air flag (no soil contact)
Byte 5:       Moisture (%), direct 0–100
Bytes 6–8:    EC (20-bit field, Big-Endian)
Byte 13:      Battery voltage (×10, mV) — unverified
Bytes 22–23:  Checksum + sum (not validated in automation)
```

**Conversion formulas:**

Temperature (°C):
```
temp_c = ((temp_raw & 0x0FFF) / 10) - 40
```

Moisture (%):
```
moisture_pct = clamp(0, 100, (raw - min_dry) / (max_wet - min_dry) * 100)
```
Where `min_dry` and `max_wet` are sensor-specific (calibrated per unit in wh52.yaml).

EC (µS/cm):
```
ec_us_cm = ec_raw_24_bit / 25.6  # empirical, may need refinement
```

Battery (mV):
```
batt_mv = byte_13 * 10
```

## Troubleshooting

### Entities don't appear
1. Check that rtl_433 is actually receiving WH52 frames (check add-on logs)
2. Verify the MQTT topic `home/rtl_devices/unknown/rows_0_data` has messages:
   ```bash
   mosquitto_sub -h localhost -t 'home/rtl_devices/unknown/rows_0_data' -v
   ```
3. Check HA's automation trace for errors: **Settings → Automations → WH52 reshape to per-id topic**

### Values look wrong
- **Moisture always 0%:** Calibration constants need adjustment (bytes 13–14 of wh52.yaml)
- **EC reads nonsense:** The EC conversion is empirical; may need per-unit tuning
- **Temperature off by 40°C:** Check that the flex decoder is correctly capturing the temperature word

### Readings are intermittent
- **Dropped readings:** If using RTL-HAOS with `rtl_throttle_interval: 30` (default), multiple sensors compete for a 30-second slot. Set to `0` for realtime.
- **All three sensors on one device:** This is normal with the flex decoder (they share the `unknown` device). The automation splits them by ID for clean entities.

## Upgrade path: Native rtl_433 support (protocol 353)

Once `rtl_433` ships with native WH52 support in a stable release:

1. **Update RTL-HAOS** to a version that includes protocol 353
2. **Remove the flex decoder** from your config
3. **Add protocol 353:**
   ```yaml
   rtl_433_args: >-
     -R 142 -R 353
   ```
4. **Delete `packages/wh52.yaml`** — entities will auto-discover from the native decoder
5. **Restart Home Assistant**

No further changes needed. Each sensor will appear as a separate device with native auto-discovery.

## Credits

- **Reverse engineering & protocol notes:** Based on captures from 4 WH52 units and the manufacturer app
- **Upstream rtl_433:** Stable protocol 142 (WH51) + emerging protocol 353 (WH52) support
- **MQTT broker:** Home Assistant's built-in Mosquitto
- **Original Python bridge:** The gist at https://gist.github.com/Verstreubulator/7983285ba6f0eaf7ce1524f70868619a inspired this YAML approach for users who prefer native HA config

## License

Use freely. Corrections and improvements welcome.

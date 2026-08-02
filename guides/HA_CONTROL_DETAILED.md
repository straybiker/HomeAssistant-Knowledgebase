# ha_control.ps1 — Detailed Reference

Complete technical documentation for the Home Assistant config deployment automation script.

---

## Table of Contents

1. [Overview](#overview)
2. [Credentials & Authentication](#credentials--authentication)
3. [The -Verify Flag & Rollback System](#the--verify-flag--rollback-system)
4. [Detailed Command Reference](#detailed-command-reference)
5. [Internal Architecture](#internal-architecture)
6. [Failure Scenarios](#failure-scenarios)
7. [Advanced Configuration](#advanced-configuration)

---

## Overview

**Purpose:** Safely deploy Home Assistant YAML configuration changes with automatic verification and rollback.

**Key Features:**
- **Multi-stage deployment** (backup → upload → verify → restart)
- **Automatic rollback** on verification failure
- **SSH/SCP** for secure remote access
- **YAML validation** before deployment
- **Selective reload** without restart (faster)
- **Comprehensive logging** of all changes

**Safety Design:** The script assumes everything can fail and provides defense-in-depth:
- Always backs up before changes
- Validates syntax before restart
- Auto-reverts on validation failure
- Creates timestamped backup directories
- Never deletes without verification

---

## Credentials & Authentication

### Setup: .env File

Create `.env` in the same directory as `ha_control.ps1`:

```powershell
# Required fields
HA_URL=http://ha.local:8123
HA_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
HA_SSH_USER=root
HA_SSH_HOST=ha.local
HA_SSH_PORT=22

# Example with IP address instead of hostname
HA_URL=http://192.168.1.100:8123
HA_SSH_HOST=192.168.1.100
```

### Getting Each Credential

#### HA_URL
- Open your Home Assistant instance in browser (e.g., `http://ha.local:8123`)
- Use the URL from the address bar
- Include the port (usually 8123, sometimes 8000 for supervised)

#### HA_TOKEN (Long-Lived Access Token)
1. Open Home Assistant UI
2. Click your profile icon (bottom left)
3. Scroll to **"Long-Lived Access Tokens"**
4. Click **"Create Token"**
5. Name it something like "Claude Code Deployment"
6. Copy the token (you won't see it again)
7. Paste into `.env` as `HA_TOKEN=eyJ...`

**⚠️ SECURITY:** This token has full API access. Keep it secret:
- Don't commit `.env` to git
- Don't share via email or chat
- Rotate periodically

#### HA_SSH_USER & HA_SSH_HOST
Default on Home Assistant OS is `root` @ `ha.local` (or your device's IP).

To enable SSH:
1. **Settings → System → Advanced options**
2. Toggle **"SSH server"** ON
3. Default user: `root`
4. Default password: `root` (after first login, change it)

**Test SSH access:**
```powershell
# Verify you can connect
ssh -p 22 root@ha.local

# Or with IP
ssh -p 22 root@192.168.1.100
```

#### HA_SSH_PORT
- Default: `22` (standard SSH)
- Only change if you've modified HA's SSH port

### Authentication Methods

#### Method 1: Password (Simplest, Default)
`.env` file with `HA_SSH_USER` and `HA_SSH_HOST` only:

```powershell
HA_SSH_USER=root
HA_SSH_HOST=ha.local
HA_SSH_PORT=22
```

First run will prompt for password. SSH caches it briefly.

#### Method 2: SSH Key (Recommended)
For passwordless, automated deployments:

```powershell
# Generate key (one-time, on your PC)
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\ha_rsa -N ""

# Copy to HA (requires password once)
ssh-copy-id -i $env:USERPROFILE\.ssh\ha_rsa root@ha.local

# Now script auto-uses the key
```

**Note:** Script auto-detects keys at:
- `~/.ssh/id_rsa`
- `~/.ssh/id_ed25519`
- `~/.ssh/id_ecdsa`

### Credential Priority

The script tries authentication in this order:
1. SSH key (if present in `~/.ssh/`)
2. Password prompt (if key not found)
3. Error if `HA_SSH_USER` not set

---

## The -Verify Flag & Rollback System

### How -Verify Works

**Purpose:** Check that YAML syntax is valid BEFORE restarting Home Assistant.

**Execution Flow:**

```
User runs:
  .\ha_control.ps1 -Deploy -Verify -Restart

Script does:
  1. Create backup of current config on HA
  2. Upload your local files to HA
  3. Call HA API: /api/config/core/check_config
  4. HA checks YAML syntax (does NOT restart yet)
  5. If valid: mark "verified" and proceed
  6. If invalid: ROLLBACK automatically and exit with error
```

**Timeline:**
```
[00:00] Backup created
[00:05] Files uploaded
[00:10] Verification called (takes 5-30 seconds)
[00:15] Result: VALID ✅ or INVALID ❌

If VALID:
  [00:16] Restart initiated
  [00:45] Done

If INVALID:
  [00:16] Rollback from backup
  [00:20] Restore complete
  [00:21] Exit with error code 1
         (no restart, config unchanged)
```

### What Gets Verified

Home Assistant's `check_config` validates:

✅ **YAML Syntax**
- Valid YAML structure
- Proper indentation
- Valid field types

✅ **Integration Config**
- Required fields present
- Valid option values
- No unknown integrations (by default)

❌ **Runtime Issues** (NOT checked)
- Entity availability
- Service availability
- Automation triggers working
- Automations can access their entities

**Example:**

```yaml
# ✅ PASSES validation
automation:
  - alias: WH52 reshape
    trigger:
      - platform: mqtt
        topic: home/rtl_devices/unknown/rows_0_data

# ❌ FAILS validation
automation:
  - alias WH52 reshape         # Missing colon
    trigger:
      platform: mqtt
      topic: home/rtl_devices/unknown/rows_0_data  # Wrong indent
```

### Automatic Rollback

**When does rollback happen?**

```
✅ No rollback needed:
   - Verification passes
   - Restart completes
   - HA comes back online

❌ Rollback triggered:
   - Verification fails (YAML syntax error)
   - Restart fails (HA can't start)
   - Restart timeout (HA takes too long)
   - Verification API unreachable
```

**What gets rolled back?**

The script restores these files from backup:
- `automations.yaml`
- `scripts.yaml`
- `configuration.yaml`
- Any `.yaml` files you modified
- Lovelace storage files (if touched)

**The backup location:**

```
C:\Users\stray\OneDrive\Projects\HomeAssistant\
└── backups\
    └── migration_20260802_170530_deploy\
        ├── automations.yaml.ha_bak
        ├── scripts.yaml.ha_bak
        └── configuration.yaml.ha_bak
```

**Manual rollback (if auto-rollback fails):**

```powershell
# Restore from backup directory
Copy-Item -Path "backups\migration_*\*" `
          -Destination "." -Force

# Reload HA config without restart
.\ha_control.ps1 -Reload
```

### Verification Without Restart

You can verify WITHOUT restarting:

```powershell
# Check syntax only, no deployment
.\ha_control.ps1 -Deploy -Verify

# Or: just see what would change
.\ha_control.ps1 -Diff
```

This uploads files and checks them, but does NOT restart HA.

### Real-World Example

**Scenario:** You edited `automations.yaml` and indentation is wrong.

```powershell
.\ha_control.ps1 -Deploy -Verify -Restart
```

**What happens:**

```
[00:00] Creating backup...
[00:05] Uploading automations.yaml...
[00:10] Verifying config...
  Error: bad indentation in automations.yaml line 127
[00:15] Verification FAILED ❌
[00:16] Rolling back from backup...
[00:20] Rollback complete. Config unchanged.
[00:21] Exit with error code 1

Result: HA is still running with OLD config
        Your bad automations.yaml is NOT applied
        Log file shows exact error line
```

You then:
1. Fix the indentation in `automations.yaml`
2. Run the deploy again
3. This time it passes verification and restarts

---

## Detailed Command Reference

### Full Command Syntax

```powershell
.\ha_control.ps1 `
  [-Deploy] `
  [-Pull] `
  [-Diff] `
  [-Verify] `
  [-Reload] `
  [-Restart] `
  [-File <path>] `
  [-Target <domain>]
```

### Flag Combinations & Behavior

| Command | What Happens | Use Case |
|---------|-------------|----------|
| `-Deploy` | Upload local → HA | Deploy changes |
| `-Deploy -Verify` | Upload + check syntax (no restart) | Test before restart |
| `-Deploy -Verify -Restart` | Upload + check + restart | Safe full deployment |
| `-Pull` | Download HA → local | Sync from HA UI |
| `-Diff` | Show changes (no upload) | Review before deploy |
| `-Reload` | Reload domains (no restart) | Fast update |
| `-Reload -Target Automations` | Reload only automations | Update one domain |
| `-Restart` | Restart HA immediately | Emergency restart |
| `-File scripts.yaml` | Single file operations | Edit just one file |

### Examples by Scenario

**Scenario 1: Safe daily update**
```powershell
# Step 1: Review
.\ha_control.ps1 -Diff

# Step 2: Deploy with safety net
.\ha_control.ps1 -Deploy -Verify -Restart
```

**Scenario 2: Quick script fix**
```powershell
# Deploy and reload (no full restart)
.\ha_control.ps1 -Deploy -File scripts.yaml
.\ha_control.ps1 -Reload -Target Scripts
```

**Scenario 3: Add new automation**
```powershell
# Edit automations.yaml locally
# Then:
.\ha_control.ps1 -Deploy -File automations.yaml -Verify
# Review if it passed:
.\ha_control.ps1 -Reload -Target Automations
# Or full restart:
.\ha_control.ps1 -Deploy -Verify -Restart
```

**Scenario 4: Pull changes from UI**
```powershell
# Admin made changes in HA UI
# Sync back to local:
.\ha_control.ps1 -Pull

# Review:
git diff automations.yaml

# Commit:
git add .
git commit -m "Sync automation changes from HA UI"
```

---

## Internal Architecture

### State Machine

```
┌─────────────────┐
│  START: Flags   │
│  check & parse  │
└────────┬────────┘
         │
    ┌────┴─────┬──────┬───────┬────────┐
    │           │      │       │        │
    ▼           ▼      ▼       ▼        ▼
  -Deploy   -Pull  -Diff  -Verify   -Reload
    │           │      │       │        │
    ├───────────┴──────┴───────┴────────┤
    │      Check prerequisites         │
    │    (SSH, creds, paths, .env)     │
    │                                  │
    ├──────────── -Diff ──────────────┤
    │  Show changes (dry run, exit)    │
    │                                  │
    ├─────────────────────────────────┤
    │ If -Deploy or -Reload:          │
    │                                  │
    │  1. Format YAML (ha_yaml.py)    │
    │  2. Create backup                │
    │  3. Upload to HA (SCP)           │
    │  4. Verify config (if -Verify)   │
    │  5. Reload/Restart (if requested)│
    │                                  │
    │ On failure at any step:          │
    │  → Auto-rollback from backup     │
    │  → Report error                  │
    │  → Exit code 1                   │
    │                                  │
    └──────────────────────────────────┘
```

### Backup Strategy

**Backup structure:**

```
Each deployment creates:
  backups\migration_YYYYMMDD_HHMMSS_<operation>\
    ├── automations.yaml.ha_bak
    ├── scripts.yaml.ha_bak
    ├── configuration.yaml.ha_bak
    └── packages\*.yaml.ha_bak
```

**Retention:** Script keeps last 10 backups, auto-cleans old ones.

**Manual cleanup:**
```powershell
# Keep only last 5
Get-ChildItem backups\migration_* | 
  Sort-Object -Property CreationTime -Descending | 
  Select-Object -Skip 5 | 
  Remove-Item -Recurse -Force
```

### Logging

All operations logged to console with timestamps:

```
[12:34:56] INFO: Starting deployment...
[12:34:57] INFO: Creating backup...
[12:35:02] INFO: Uploading 3 files...
[12:35:15] INFO: Verifying config...
[12:35:18] INFO: Verification PASSED ✓
[12:35:19] INFO: Restarting Home Assistant...
[12:35:45] INFO: Restart complete.
```

To save to file:
```powershell
.\ha_control.ps1 -Deploy -Verify -Restart *> deploy.log
```

---

## Failure Scenarios

### Scenario 1: YAML Syntax Error

**Input file:**
```yaml
automation:
  - alias: My automation    # Missing colon after 'automation'
    trigger:
      platform: mqtt
```

**Execution:**
```powershell
.\ha_control.ps1 -Deploy -Verify
```

**Result:**
```
[00:05] Uploading automations.yaml...
[00:10] Verifying config...
Error: bad indentation in automations.yaml line 5
[00:15] Verification FAILED ❌
[00:16] Rolling back...
[00:20] Rollback complete. Config unchanged.
Exit code: 1
```

**Recovery:**
1. Fix the YAML syntax
2. Re-run deploy

### Scenario 2: SSH Connection Failed

**Cause:** HA SSH server is down or port wrong.

**Execution:**
```powershell
.\ha_control.ps1 -Deploy
```

**Result:**
```
Error: SSH connection to ha.local:22 refused
Verify:
  - HA SSH server is enabled (Settings → System → Advanced)
  - Correct hostname/IP in .env
  - Network connectivity

Exit code: 1
```

**Recovery:**
1. Check HA SSH is enabled
2. Test: `ssh root@ha.local`
3. Fix `.env` if needed
4. Re-run

### Scenario 3: Token Expired

**Cause:** HA_TOKEN is invalid or revoked.

**Execution:**
```powershell
.\ha_control.ps1 -Verify
```

**Result:**
```
Error: Authentication failed - invalid token
Verify:
  - Token is correct in .env
  - Token hasn't been revoked
  - HA instance is accessible at HA_URL

Solution: Create new token in HA UI
```

### Scenario 4: HA Restart Hangs

**Cause:** HA takes too long to restart (integration loading slowly).

**Result:**
```
[01:00] Restarting Home Assistant...
[01:30] Restart timeout - taking too long
[01:31] Rolling back...
[01:35] Rollback complete.

Error: Home Assistant restart exceeded timeout (60 seconds)
```

**Recovery:**
1. Check HA logs for startup errors
2. Wait for HA to finish restarting manually
3. Investigate slow integrations
4. Retry deployment

---

## Advanced Configuration

### Environment Variables

Edit these in script itself (lines 20-30):

```powershell
$timeout = 30          # Seconds to wait for verification
$restart_timeout = 60  # Seconds to wait for HA restart
$max_retries = 3       # API retry attempts
```

### Custom SSH Port

If HA SSH is on non-standard port:

```powershell
# .env
HA_SSH_PORT=2222
```

### Using SSH Key Authentication

```powershell
# Generate key (one-time)
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\ha_deploy -N ""

# Copy to HA
ssh-copy-id -i $env:USERPROFILE\.ssh\ha_deploy root@ha.local

# Script auto-detects and uses it
# No .env password needed
```

### Debug Mode

Enable verbose SSH output:

```powershell
# Edit ha_control.ps1, find SSH calls (~line 200)
# Add: -vv flag to ssh command
ssh -vv -p $port ...

# Now run normally
.\ha_control.ps1 -Deploy -Verify
```

### Backup Retention

Script auto-keeps last 10, but you can customize:

```powershell
# Edit ha_control.ps1, line ~270:
$keep_backups = 5  # Change from 10 to 5
```

---

## Troubleshooting Checklist

Before asking for help, check:

- [ ] `.env` file exists in script directory
- [ ] All four required fields in `.env` are filled
- [ ] HA_URL is reachable: `ping ha.local` or open in browser
- [ ] SSH is enabled on HA: **Settings → System → Advanced**
- [ ] Token is valid: Create new one if unsure
- [ ] YAML files have no syntax errors: `python ha_yaml.py format *.yaml`
- [ ] Recent backups exist: Check `backups\` directory
- [ ] HA logs show no errors: **Settings → System → Logs**

---

**Last Updated:** 2026-08-02  
**Version:** ha_control.ps1 (PowerShell)  
**Tested with:** Home Assistant 2026.7.3+

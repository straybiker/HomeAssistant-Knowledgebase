# Home Assistant Scripts Manual

Complete documentation for `ha_control.ps1` and `ha_yaml.py` deployment automation tools.

---

## Quick Start

### Prerequisites

1. **PowerShell 5.0+** (built-in on Windows 10+)
2. **SSH access** to your Home Assistant instance
3. **`.env` file** with credentials (see Setup section)
4. **Python 3.7+** (for ha_yaml.py; optional if not using -Verify flag)

### Setup

Create `.env` file in the same directory as `ha_control.ps1`:

```powershell
# .env (example)
HA_URL=http://ha.local:8123
HA_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
HA_SSH_USER=root
HA_SSH_HOST=ha.local
HA_SSH_PORT=22
```

Get your HA token: **Settings → Developer Tools → Long-Lived Access Tokens → Create Token**

### First Run

```powershell
cd C:\Users\stray\OneDrive\Projects\HomeAssistant\Tools

# Test connection (dry run, no changes)
.\ha_control.ps1 -Diff

# Deploy a test file
.\ha_control.ps1 -Pull -File configuration.yaml
```

---

## ha_control.ps1 — Deployment Automation

**Purpose:** Deploy Home Assistant config changes safely with verification and rollback.

### Usage

```powershell
.\ha_control.ps1 [-Deploy] [-Pull] [-File <path>] [-Diff] [-Verify] [-Reload] [-Target <domain>] [-Restart]  
```

### Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-Deploy` | Upload config to HA | `.\ha_control.ps1 -Deploy` |
| `-Pull` | Download config from HA | `.\ha_control.ps1 -Pull` |
| `-Diff` | Show what changed (dry run) | `.\ha_control.ps1 -Diff` |
| `-Verify` | Check YAML syntax | `.\ha_control.ps1 -Deploy -Verify` |
| `-Reload` | Reload domains (no restart) | `.\ha_control.ps1 -Reload -Target Automations` |
| `-Restart` | Restart Home Assistant | `.\ha_control.ps1 -Deploy -Verify -Restart` |
| `-File <path>` | Single file operation | `.\ha_control.ps1 -Pull -File packages/wh52.yaml` |
| `-Target <domain>` | Reload specific domain | `-Reload -Target Scripts` |

### Common Workflows

#### 1. Edit → Verify → Deploy → Restart

```powershell
# Make changes to your YAML files, then:
.\ha_control.ps1 -Deploy -Verify -Restart
```

**What happens:**
1. Creates backup of current config on HA
2. Uploads your local files
3. Verifies YAML syntax
4. Restarts Home Assistant
5. On failure, automatically rolls back from backup

#### 2. Check Before Deploying (Dry Run)

```powershell
# See what will change without touching anything
.\ha_control.ps1 -Diff
```

**Output example:**
```
--- DIFF FOR automations.yaml (- local, + HA) ---
@@ -125,3 +125,8 @@
   - alias: Old Automation
+  - alias: New Automation
+    trigger:
+      platform: time
+      at: '15:00:00'
```

#### 3. Reload Without Restart

```powershell
# Reload only automations (faster than full restart)
.\ha_control.ps1 -Reload -Target Automations

# Reload everything (same as -Reload with no -Target)
.\ha_control.ps1 -Reload
```

**Available reload targets:**
- `All` — Everything (default)
- `Automations` — Automations only
- `Scripts` — Scripts only
- `Templates` — Template entities
- `Themes` — UI themes
- `Rest` — REST commands
- `Core` — Core configuration

#### 4. Pull Latest Config from HA

```powershell
# Download all config files
.\ha_control.ps1 -Pull

# Download single file
.\ha_control.ps1 -Pull -File automations.yaml

# Download from subfolder
.\ha_control.ps1 -Pull -File packages/wh52.yaml
```

#### 5. Simple File Edit & Deploy

```powershell
# Edit scripts.yaml locally, then:
.\ha_control.ps1 -Deploy -File scripts.yaml -Verify

# Verify without deploying
.\ha_control.ps1 -Diff -File scripts.yaml
```

### Advanced Features

#### Automatic Rollback on Verify Failure

```powershell
# If verification fails, config is automatically restored
.\ha_control.ps1 -Deploy -Verify -Restart
# If verify fails: stops, rolls back, exits with error code 1
```

#### Backup Management

```powershell
# Backups are created in: C:\...\HomeAssistant\backups\migration_*/
# Named: migration_YYYYMMDD_HHMMSS_<operation>/
# Contains: Original scripts.yaml, automations.yaml, configuration.yaml
```

#### Environment Variables

Create `.env` file with:

```powershell
HA_URL=http://ha.local:8123           # URL to HA
HA_TOKEN=eyJ...                       # Long-lived access token
HA_SSH_USER=root                      # SSH user (usually root)
HA_SSH_HOST=ha.local                  # SSH hostname or IP
HA_SSH_PORT=22                        # SSH port
```

### Troubleshooting

#### "Error: .env file not found"
**Fix:** Create `.env` in same directory as script with correct credentials

#### "SSH connection refused"
```powershell
# Check SSH is enabled on HA:
# Settings → System → Server Control → Advanced → SSH Server

# Test connection manually:
ssh -p 22 root@ha.local
```

#### "YAML validation failed"
```powershell
# Use -Diff to see exactly what's wrong:
.\ha_control.ps1 -Diff

# The error will show line numbers and the problem
```

#### "Rollback failed"
If automatic rollback fails:
```powershell
# Restore manually from backup
Copy-Item -Path "backups\migration_*\*" -Destination "." -Force
.\ha_control.ps1 -Reload
```

---

## ha_yaml.py — YAML Formatting & Diffing

**Purpose:** Canonical YAML formatting and intelligent diffs that ignore whitespace.

### Installation

```bash
# Required: Python 3.7+
# Install dependency:
pip install ruamel.yaml

# Or if using conda:
conda install -c conda-forge ruamel.yaml
```

### Usage

```bash
python3 ha_yaml.py <command> [files]
```

### Commands

#### Format Files (Canonical Style)

```bash
# Format a single file
python3 ha_yaml.py format automations.yaml

# Format multiple files
python3 ha_yaml.py format automations.yaml scripts.yaml configuration.yaml

# Format entire directory
python3 ha_yaml.py format *.yaml
```

**Output:**
```
formatted: automations.yaml (320 lines)
formatted: scripts.yaml (145 lines)
skip: configuration.yaml (unchanged)
```

#### Compare Files (Smart Diff)

```bash
# Compare local vs remote file
python3 ha_yaml.py diff local_automations.yaml remote_automations.yaml automations.yaml

# Result ignores whitespace differences:
# - Only shows semantic changes
# - Ignores indentation changes
# - Ignores comment differences
```

**Output example:**
```
--- DIFF FOR automations.yaml ---
@@ line 125 @@
- old_entity_id: sensor.temperature
+ new_entity_id: sensor.room_temperature
```

### Integration with ha_control.ps1

The `ha_control.ps1` script **automatically uses** `ha_yaml.py`:

- **`-Deploy`** — Formats files before upload (canonical style)
- **`-Diff`** — Uses smart diffing to show only meaningful changes
- **`-Verify`** — Validates YAML syntax before deployment

You don't need to run it manually unless you want to format files standalone.

### Why Canonical Formatting?

```yaml
# Before (inconsistent)
automation:
  - alias:    WH52 reshape
    mode:queued
    trigger:
      platform: mqtt
        topic: home/rtl_devices/unknown/rows_0_data

# After (canonical)
automation:
  - alias: WH52 reshape
    mode: queued
    trigger:
      - platform: mqtt
        topic: home/rtl_devices/unknown/rows_0_data
```

Benefits:
- Consistent across all files
- Easier code reviews (no formatting noise)
- Catches YAML syntax errors early
- Git diffs are cleaner

---

## Real-World Workflows

### Workflow 1: Safe Automation Update

You want to add a new automation safely:

```powershell
# 1. Edit automations.yaml locally
#    (add your new automation)

# 2. Check what changed
.\ha_control.ps1 -Diff -File automations.yaml

# 3. Deploy and verify (auto-rollback on failure)
.\ha_control.ps1 -Deploy -File automations.yaml -Verify

# 4. If verification passed, reload (no restart needed)
.\ha_control.ps1 -Reload -Target Automations

# Done! Check logbook for errors
```

### Workflow 2: Bulk Config Update

Multiple files changed (e.g., adding WH52 package):

```powershell
# 1. Made changes to:
#    - packages/wh52.yaml
#    - configuration.yaml (added recorder exclusion)
#    - automations.yaml (added new automations)

# 2. Check all changes at once
.\ha_control.ps1 -Diff

# 3. Deploy everything with full safety checks
.\ha_control.ps1 -Deploy -Verify -Restart

# Automatic rollback occurs if any step fails
```

### Workflow 3: Sync Config from HA Back to Local

HA admin made changes in UI, sync back:

```powershell
# 1. Pull latest from HA
.\ha_control.ps1 -Pull

# 2. Review changes in git
git diff

# 3. Commit locally
git add .
git commit -m "Sync config changes from HA"

# 4. Push to GitHub
git push
```

### Workflow 4: Quick Test Before Production

Test a change on staging before prod:

```powershell
# 1. Deploy to staging with verification
.\ha_control.ps1 -Deploy -Verify -Restart

# 2. Test manually in HA (15-30 min)

# 3. If good, commit and tag for production
git tag production-ready-2026-08-02

# 4. Deploy to production
.\ha_control.ps1 -Deploy -Verify -Restart
```

---

## Environment Setup

### Windows Setup

```powershell
# 1. Set execution policy (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Create .env file in Tools directory
# Copy template from above

# 3. Test connection
.\ha_control.ps1 -Diff
```

### SSH Key Authentication (Optional)

For passwordless SSH:

```bash
# Generate key on your PC (one-time)
ssh-keygen -t ed25519 -f ~/.ssh/ha_rsa

# Copy to HA (requires password once)
ssh-copy-id -i ~/.ssh/ha_rsa.pub root@ha.local

# Now update .env to use key
HA_SSH_USER=root
HA_SSH_HOST=ha.local
HA_SSH_PORT=22
# ha_control uses SSH key if available (~/.ssh/id_rsa or ~/.ssh/id_ed25519)
```

### Backup Strategy

```powershell
# Backups auto-create in:
# HomeAssistant/backups/migration_YYYYMMDD_HHMMSS_deploy/

# Keep last 10 backups, clean old ones:
Remove-Item "backups" -Filter "migration_*" -Recurse | 
  Sort-Object -Property CreationTime -Descending | 
  Select-Object -Skip 10 | 
  Remove-Item -Recurse -Force
```

---

## Integration with Git

### Pre-Commit Hook

Automatically format YAML before committing:

```bash
# Create .git/hooks/pre-commit
#!/bin/bash
cd "$(git rev-parse --git-dir)/.."
python3 ha_yaml.py format *.yaml packages/*.yaml
git add *.yaml packages/*.yaml
```

### CI/CD Pipeline

```yaml
# Example: GitLab CI (.gitlab-ci.yml)
deploy_ha:
  script:
    - ./ha_control.ps1 -Deploy -Verify -Restart
  only:
    - main
```

---

## Tips & Best Practices

### 1. Always Diff Before Deploy
```powershell
.\ha_control.ps1 -Diff      # See exactly what changes
.\ha_control.ps1 -Deploy    # Deploy with confidence
```

### 2. Use -Reload for Fast Updates
```powershell
# Restart takes 30-60 seconds
.\ha_control.ps1 -Restart

# Reload takes 2-5 seconds (same effect for automations/scripts)
.\ha_control.ps1 -Reload -Target Automations
```

### 3. Keep Backups
```powershell
# Backups auto-create, but keep them safe
Copy-Item -Path "backups" -Destination "backups_archive_$(Get-Date -Format yyyyMMdd)" -Recurse
```

### 4. Test in Automations Tab
After deployment, check **Settings → Automations** for any error indicators (red icons).

### 5. Monitor Logs After Restart
```
Settings → System → Logs
Search: "error", "warning", "pool", "wh52", etc.
```

---

## Troubleshooting Matrix

| Problem | Cause | Solution |
|---------|-------|----------|
| "Connection refused" | SSH port wrong | Check HA SSH settings |
| "Authentication failed" | Wrong credentials | Verify token in .env |
| "YAML validation failed" | Syntax error in file | Use -Diff to locate |
| "Timeout waiting for..." | Slow network | Increase timeout or check connection |
| "Entity not found" | Entity ID mistyped | Check entity IDs in HA first |
| "Rollback failed" | Backup corrupted | Restore manually from `.backups/` |

---

## Advanced

### Custom Timeout

```powershell
# Default is 30 seconds, increase for slow networks:
# Edit ha_control.ps1, line ~35:
$timeout = 60  # seconds
```

### Disable Automatic Rollback

```powershell
# For CI/CD (if you want to keep bad config):
# Edit ha_control.ps1, line ~80:
$script:backupCreated = $false  # Skip rollback
```

### Log All Changes

```powershell
# Redirect output to file
.\ha_control.ps1 -Deploy -Verify -Restart *> deploy.log
```

---

## Support

**For ha_control.ps1 issues:**
- Check `.env` credentials
- Verify SSH access: `ssh -p 22 root@ha.local`
- Enable SSH debugging: `ssh -vv ...`

**For ha_yaml.py issues:**
- Verify Python 3.7+: `python --version`
- Check ruamel.yaml installed: `pip show ruamel.yaml`
- Test on single file first

**For Home Assistant issues:**
- Check system logs: **Settings → System → Logs**
- Restart HA: **Settings → System → Restart**
- Check entity availability: **Developer Tools → States**

---

**Last updated:** 2026-08-02  
**Tested with:** HA 2026.7.3, PowerShell 7.4

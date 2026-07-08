# Repair-AOVPNTrigger.ps1

Remediation script that replaces an aggressive Always On VPN trigger with connection logic that never drops an active tunnel because of a single failed health probe — the failure mode that disconnects RDP/remote-control sessions mid-use.

## What it does

- Backs up the existing trigger script in place (timestamped `.backup-yyyymmdd-hhmmss`).
- Writes a safer trigger that evaluates **multiple** corporate reachability probes (DNS resolution + endpoint checks) before deciding state.
- Keeps an already-connected tunnel up even when all probes fail — a connected-but-degraded tunnel is preferable to a forced disconnect/reconnect cycle.
- Uses a global mutex so overlapping scheduled-task launches don't fight over the connection.
- Opens its log with `FileShare.ReadWrite` to avoid log-lock contention between simultaneous task instances.
- Disables the aggressive periodic re-trigger task if present and switches remaining AOVPN tasks to `IgnoreNew` multiple-instance behavior.
- `-RunNow` performs a one-time validation run of the repaired trigger.

## Usage

```powershell
# Elevated, after the AOVPN deployment has created the profile and tasks
.\Repair-AOVPNTrigger.ps1            # repair only
.\Repair-AOVPNTrigger.ps1 -RunNow    # repair + immediate validation pass
```

## Requirements

- Existing AOVPN deployment (profile + scheduled tasks). This script repairs trigger behavior; it does not create missing tasks — run the deployment script first if they're absent.
- Elevated or SYSTEM context (SCCM/Intune remediation-friendly).

## Design notes

- The probe list is environment-specific — replace the template DNS/DC/app targets before use.
- The active-RDP check is informational; the repaired logic protects connected tunnels regardless of probe results.

## Rollback

Restore the timestamped backup of the trigger script and re-enable the periodic task only if the old recycle behavior is intentionally wanted.

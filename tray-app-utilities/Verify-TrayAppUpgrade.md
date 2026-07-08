# Verify-TrayAppUpgrade.ps1

Post-rollout spot check for an MSI MajorUpgrade deployment: confirms the new version landed and the old ProductCode is gone.

## What it checks

- The app's registry detection footprint (`Version`, `InstallPath`) — the same values SCCM's registry-based detection method reads.
- The installed EXE's `FileVersion` (matches the MSI/assembly version when the release process bumped everything together).
- `Win32_Product` filtered by display name: exactly **one** entry should remain, carrying the new version and new `IdentifyingNumber`. Two entries means MajorUpgrade never fired — almost always a ProductCode that wasn't regenerated for the release.

## Usage

```powershell
.\Verify-TrayAppUpgrade.ps1    # run on a target machine after deployment
```

Note: the `Win32_Product` query is slow and triggers MSI self-repair checks by design — fine for spot checks, don't loop it fleet-wide; use the registry footprint for at-scale compliance instead.

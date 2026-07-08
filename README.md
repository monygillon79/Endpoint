# Windows Endpoint Engineering Scripts

A collection of production-grade PowerShell tooling and utilities from real enterprise endpoint work: Always On VPN deployment and stabilization, Windows 11 imaging and branding, Configuration Manager (SCCM/MECM) automation, and a full-stack IT documentation generator.

All environment-specific values (domains, site codes, hostnames, OU paths) use template placeholders — `contoso.local`, `P01`, `cm01`, `vpn.example.org` — and must be replaced before use. Test in a pilot ring before broad deployment.

## Script index

### Always On VPN — `always-on-vpn/`

| Script | Purpose |
|---|---|
| [Deploy-AlwaysOnVPN.ps1](always-on-vpn/Deploy-AlwaysOnVPN.md) | End-to-end IKEv2 device-tunnel deployment: profile creation, routes, rasphone.pbk hardening, NAT-T Error 809 fix, trigger tasks, detection metadata |
| [Repair-AOVPNTrigger.ps1](always-on-vpn/Repair-AOVPNTrigger.md) | Replaces aggressive trigger logic with multi-probe health checks that never drop a connected tunnel — fixes mid-session RDP disconnects |

### Windows 11 imaging & branding — `windows-11-branding/`

| Script | Purpose |
|---|---|
| [Set-Win11-24H2-UserCustomizableDefaults.ps1](windows-11-branding/Set-Win11-24H2-UserCustomizableDefaults.md) | Default Start/taskbar/wallpaper during 24H2 imaging, user-changeable after first sign-in (online + offline OS targets) |
| [Set-Win11Branding.ps1](windows-11-branding/Set-Win11Branding.md) | Policy-enforced branding across default, loaded, and offline profiles — for lock-down scenarios only |
| [LayoutModification.xml](windows-11-branding/LayoutModification.md) | Taskbar pin layout template consumed by both scripts above |

### SCCM OSD — `sccm-osd/`

| Script | Purpose |
|---|---|
| [UIpp-OSD-Frontend.xml](sccm-osd/UIpp-OSD-Frontend.md) | UI++ pre-imaging wizard: service-tag confirmation, location/department/build selection, dynamic app tree → task sequence variables |

### SCCM application icon pipeline — `sccm-app-icons/` ([pipeline overview](sccm-app-icons/README.md))

| Script | Purpose |
|---|---|
| [Get-SCCMAppInventory.ps1](sccm-app-icons/Get-SCCMAppInventory.md) | Inventory all deployed apps to CSV with namespace-aware icon detection |
| [Get-SCCMFullInventory.ps1](sccm-app-icons/Get-SCCMFullInventory.md) | Zero-parameter estate report: apps + packages, deployment collections, creators |
| [Find-AppIcons.ps1](sccm-app-icons/Find-AppIcons.md) | Auto-source 512x512 icons per app (WinGet manifests → Clearbit → publisher og:image) with review CSV |
| [Update-SingleAppIcon.ps1](sccm-app-icons/Update-SingleAppIcon.md) | Reliable single-app icon write via the ConfigMgr SDK serializer, with dry-run, fallback save path, and byte verification |
| [Update-AllAppIcons.ps1](sccm-app-icons/Update-AllAppIcons.md) | Bulk icon application with three-tier name matching, per-icon failure isolation, and CSV outcome log |
| [Verify-AppIcon.ps1](sccm-app-icons/Verify-AppIcon.md) | Reads saved icon bytes back out of SCCM and opens them — ground-truth persistence check |
| [Diagnose-SCCMSite.ps1](sccm-app-icons/Diagnose-SCCMSite.md) | Forensic site-connection discovery when consoles or auto-detection misbehave |

### Endpoint tray-app utilities — `tray-app-utilities/`

Diagnostics built alongside an in-house WinForms system-tray support app deployed fleet-wide via SCCM/MSI.

| Script | Purpose |
|---|---|
| [Check-TrayAppAutolaunch.ps1](tray-app-utilities/Check-TrayAppAutolaunch.md) | Why-isn't-it-starting triage: Run keys, StartupApproved byte decode, logon-vs-install timing, crash log, AppLocker/Defender events |
| [Verify-TrayAppUpgrade.ps1](tray-app-utilities/Verify-TrayAppUpgrade.md) | Post-rollout MSI MajorUpgrade verification: registry footprint, file version, single-ProductCode check |
| [Get-PrimaryMonitorDpi.ps1](tray-app-utilities/Get-PrimaryMonitorDpi.md) | P/Invoke probe for true per-monitor DPI — debugs PerMonitorV2 scaling mismatches |

### DocForge — `docforge/`
<img src="docforge/docs/mockups/network_overview.png" alt="DocForge rendering a Network Overview document" width="920">
Automated IT documentation: collect an environment, generate polished docs.

| Component | Purpose |
|---|---|
| [Collect-ITEnvironment.ps1](docforge/Collect-ITEnvironment.md) | Parallel (RunspacePool) collector for AD, GPO, SCCM, and network data → AES-256-encrypted `.dfpkg` bundle |
| [DocForge web app](docforge/DocForge-App.md) | Node/Express backend + React frontend that streams generated documentation from uploaded environment bundles |

## Conventions

- PowerShell scripts target Windows PowerShell 5.1 (ASCII-safe or BOM-marked UTF-8) and parse clean under PowerShell 7.
- Destructive operations default to **dry-run**; `-Commit` applies.
- Scripts that touch SCCM auto-detect site code/server from the local registry where possible, with parameter overrides.

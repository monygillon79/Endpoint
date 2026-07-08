# Deploy-AlwaysOnVPN.ps1

End-to-end deployment of an Always On VPN **device tunnel** for Windows 10/11 (including 24H2), designed to run as SYSTEM via SCCM, Intune, or any RMM.

## What it does

- Verifies administrative context, supported OS, and a machine certificate usable for IKEv2 client authentication.
- Removes pre-existing VPN connections and stale AOVPN scheduled tasks before deploying.
- Creates an AllUser IKEv2 VPN profile with machine-certificate authentication and split tunneling.
- Adds the configured corporate route list to the profile.
- Edits `rasphone.pbk` to enable AlwaysOn, DeviceTunnel, DNS registration, taskbar icon visibility, and IKEv2-only negotiation — with a backup taken first and restored automatically if the edit fails.
- Applies the IKEv2 NAT-T registry fix (`AssumeUDPEncapsulationContextOnSendRule`) that resolves common Error 809 scenarios behind NAT.
- Adjusts IPv6 bindings so IPv4 is used for tunnel traffic (see caveats).
- Writes a connection-trigger helper script and registers scheduled tasks for startup and network-change events.
- Writes detection metadata under HKLM so deployment tools can detect installation state.

## Usage

```powershell
# Elevated PowerShell or SYSTEM context
.\Deploy-AlwaysOnVPN.ps1
```

Edit the configuration block at the top of the script first: VPN server FQDN, route list, corporate DNS suffix, and internal probe hostname are template values (`vpn.example.org`, `corp.example.org`, etc.).

## Requirements

- Windows 10/11 with a machine certificate issued for client authentication (IKEv2).
- Local admin / SYSTEM execution context.
- RRAS/NPS infrastructure already serving IKEv2 device tunnels.

## Caveats

- **IPv6 handling is deliberate but aggressive:** the script disables IPv6 bindings on adapters and sets `DisabledComponents=255`. In environments where IPv6 must stay functional, change this to prefer-IPv4 (`DisabledComponents=0x20`) instead.
- Restarting PolicyAgent/IKEEXT can momentarily affect other IPsec sessions on the endpoint.
- Pair with `Repair-AOVPNTrigger.ps1` if remote-control/RDP session stability matters — the repair replaces the trigger logic with a version that never tears down a healthy tunnel.

## Rollback

Restore the `rasphone.pbk` backup, remove the VPN profile and AOVPN scheduled tasks, and reverse the IPv6 registry changes if not desired.

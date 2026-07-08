# Collect-ITEnvironment.ps1

DocForge's data collector (v2.0): a single PowerShell script that inventories an on-premises IT environment — Active Directory, Group Policy, SCCM/MECM, and network configuration — and packages everything as an encrypted bundle for the documentation generator.

## What it collects

- **Active Directory:** users, groups, OUs, computers, domain controllers, trusts, service accounts, privileged group membership.
- **Group Policy:** GPO details, links, WMI filters, and *parsed* policy settings (registry, security, scripts, folder redirection, software installation) rather than raw report blobs.
- **SCCM/MECM:** device inventory, collections, software deployments, patch compliance (per-update `CI_ID` summaries), software inventory, BitLocker status. Site server/code auto-detected when not supplied.
- **Network:** DNS, DHCP (scopes + per-scope statistics), adapters, routes, firewall rules, certificate infrastructure.

## Engineering highlights

- Modules run in parallel via a PowerShell **RunspacePool**; each query is wrapped with retry logic and per-item error capture, so one broken subsystem degrades the bundle instead of killing the run.
- Output is a single `.dfpkg` (format v2): JSON encrypted with **AES-256-CBC**, key derived from a `SecureString` passphrase via PBKDF2. `-SkipEncryption` emits plain JSON for development.
- Module selection via `-Modules All|AD|GPO|SCCM|Network` so scoped re-collections stay fast.

## Usage

```powershell
.\Collect-ITEnvironment.ps1 -Passphrase (Read-Host -AsSecureString) -OutputPath C:\Collections
.\Collect-ITEnvironment.ps1 -Modules AD,GPO -SkipEncryption   # dev: plain JSON, AD+GPO only
```

Run as a domain account with read access to AD/GPO/SCCM; RSAT and the ConfigMgr console are used where present.

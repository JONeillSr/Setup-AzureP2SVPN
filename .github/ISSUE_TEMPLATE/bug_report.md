---
name: Bug report
about: Something isn't working as expected
title: '[BUG] '
labels: ['bug', 'needs-triage']
assignees: ''
---

## What happened?

<!-- A clear, concise description of the bug. -->

## What did you expect to happen?

<!-- What should the script have done instead? -->

## Steps to reproduce

<!-- Exact command line you ran (you can redact sensitive IDs with x's). -->

```powershell
.\Setup-AzureP2SVPN.ps1 ...
```

## Script output / error

<!--
Paste the relevant log output. Truncate to the failure point if it's long.
Either inline (in a code block) or attach the .log file the script generates.
-->

```
<paste here>
```

## Environment

- **Script:** `Setup-AzureP2SVPN.ps1` or `Remove-AzureP2SVPN.ps1`
- **Script version:** <!-- visible in the script header banner, e.g., v1.0.8 -->
- **PowerShell version:** <!-- run `$PSVersionTable.PSVersion` -->
- **OS:** <!-- Windows 11, macOS 14, Ubuntu 22.04, etc. -->
- **Az PowerShell module version:** <!-- run `(Get-Module Az -ListAvailable).Version` -->
- **Azure region:** <!-- e.g., westus2, eastus -->
- **Gateway SKU you specified (if any):** <!-- e.g., default VpnGw1AZ -->

## Azure environment context

<!-- Helpful for narrowing down which platform behavior you hit. -->

- **VNet address space:** <!-- e.g., 10.0.0.0/23, 10.0.2.0/23 -->
- **Did the script create the VNet, or join an existing one?** <!-- existing/new -->
- **Subscription type:** <!-- Pay-As-You-Go / Enterprise Agreement / CSP / Visual Studio / Free -->
- **Anything unusual in your Entra tenant?** <!-- Conditional Access policies, B2B/B2C tenant, etc. -->

## Additional context

<!--
Anything else that might help diagnose:
- Have you run the script successfully before?
- Did anything change in your Azure environment recently?
- Screenshots if a portal step is involved
-->

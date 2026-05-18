# Changelog

All notable changes to Setup-AzureP2SVPN are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing pending.

## [1.1.0] - 2026-05-18

### Added

This release rounds out the "complete VPN access pattern" by adding two scripts that solve the DNS half of the puzzle. The P2S VPN gateway alone gives VPN-connected clients network reachability to private VNet resources, but they still resolve hostnames via their local ISP DNS — which doesn't know about your private resources. These two scripts close that gap.

**Why these belong in this repo:** The DNS-for-VPN-clients problem is structurally inseparable from the VPN gateway itself. Without a working DNS path, your "VPN access" only works if users memorize private IP addresses, which nobody actually does. By keeping the gateway and the DNS scripts in one repo, the complete pattern can be deployed and torn down consistently.

- **`scripts/Add-AzureSplitHorizonDNS.ps1` (v1.0.0)** — Provisions an Azure Private DNS Zone that mirrors an existing Public DNS Zone, links it to your VNet, and optionally smart-copies records from the public zone into the private zone.

  Split-horizon (also called split-brain) DNS is the pattern where the same FQDN resolves to a private IP from inside the VNet/VPN and a public IP from the internet. This is the standard way to access internal services using your real domain name without exposing them publicly.

  The script handles the *first* half of the split-horizon setup:
  - **Creates** the Private DNS Zone matching your public zone name
  - **Links** it to your existing VNet (idempotent — reuses existing link if present)
  - **Adds** explicit private records you specify via `-PrivateRecords @{ 'erpnext' = '10.0.2.4' }`
  - **Optionally smart-copies** all public records with conflict flagging:
    - A/AAAA records: copied (flagged if pointing to public IPs — likely candidates for an explicit private override)
    - CNAME records: copied
    - MX records: skipped (mail flow should remain via public DNS even from inside the VNet)
    - SPF/DKIM/DMARC TXT records: skipped (same reason)
    - NS/SOA: never copied (managed by Azure)

  In-VNet resources automatically resolve names via Azure DNS (168.63.129.16) which sees the linked private zone. VPN-connected clients need the second script.

- **`scripts/Add-AzureDNSForwarder.ps1` (v1.0.1)** — Provisions a lightweight Ubuntu 24.04 VM running dnsmasq inside the VNet, configures the VNet's `DhcpOptions.DnsServers` to advertise the forwarder, and (after VPN profile regeneration) routes VPN client DNS queries through the forwarder.

  This solves the second half of split-horizon: Azure's built-in DNS resolver at 168.63.129.16 is only reachable from inside the VNet. VPN clients can't query it directly. The forwarder acts as a bridge — VPN clients query the forwarder, which queries Azure DNS, which sees the private zone.

  Defaults are tuned for typical use:
  - **VM size**: `Standard_B1s` (~$8/month — DNS forwarding is near-zero load)
  - **Subnet**: auto-derives next available `/28` in the VNet (or pass `-DNSSubnetCIDR`)
  - **Static private IP**: critical — the IP gets pushed via the VNet DNS setting and reboots can't change it
  - **NSG**: locked down to port 53 from inside the VNet and from the VPN client pool only
  - **SSH**: locked to `VirtualNetwork` source by default (VPN connection required to administer)
  - **cloud-init**: installs and configures dnsmasq, disables systemd-resolved's port-53 stub listener (Ubuntu 24.04 default that conflicts), enables unattended security upgrades
  - **Optional `-HighAvailability`** spins up two VMs with sequential static IPs for active/active redundancy

### Why the split-horizon pattern matters operationally

Without these scripts, users had two unappealing choices for resolving internal hostnames over VPN:
- Memorize private IPs (works for one or two services, doesn't scale)
- Manually edit each VPN client's `azurevpnconfig.xml` to inject DNS server entries (works but is fragile and breaks on every profile regeneration)

With the split-horizon + forwarder combo, the public domain "just works" from both sides: customers and search engines see the public IP, VPN-connected staff see the internal IP, and you maintain a single source of truth in DNS.

### The architecture this enables end-to-end

```
Internet     → erpnext.example.com → Public IP (or NXDOMAIN if not exposed)

VPN client   → erpnext.example.com → forwarder VM → Azure DNS → Private Zone → 10.0.2.4
```

Same FQDN, different answer based on where the resolver is.

### Documentation

- **USER-GUIDE.md**: new "DNS for VPN clients" section walking through the complete pattern (gateway + private zone + forwarder)
- **README.md**: extended script table and a "Complete VPN access pattern" section
- This CHANGELOG entry serves as a release-time summary; see the script `.SYNOPSIS` and `.DESCRIPTION` blocks for parameter-by-parameter reference

### Backwards compatibility

These are net-new scripts that don't modify existing behavior. `Setup-AzureP2SVPN.ps1` and `Remove-AzureP2SVPN.ps1` are unchanged in this release. Existing deployments work without these new scripts; users who want DNS for VPN clients can opt in by running the new scripts after the gateway is up.

## [1.0.9] - 2026-05-17

### Code quality / linting

Both scripts now pass `PSScriptAnalyzer` cleanly with the repo's settings file. Findings from the initial CI run were triaged into three categories:

**Fixed (real cosmetic improvements):**

- HelpMessage and ConfirmImpact parameter values now use spaces around `=` (PowerShell style convention)
- Switch statement case bodies use single-space before `{` (was using alignment-padding)
- Variable assignment alignment normalized to single space before `=`
- Property access operator spacing normalized
- Em-dash characters in comments replaced with `--` so files are pure ASCII (avoids `PSUseBOMForUnicodeEncodedFile` warning)
- Empty `catch { }` block in the background-job runspace replaced with `Write-Verbose` and an explanatory comment

**Suppressed via SuppressMessageAttribute (false positives):**

- `PSReviewUnusedParameter` on `-TenantId`, `-SubscriptionId`, `-ConfirmContext` — these script-scope parameters are used by the `Resolve-AzureContext` function but PSSA's function-level analysis can't see the connection

**Suppressed via PSScriptAnalyzerSettings.psd1 (rule misfires):**

- `PSUseUsingScopeModifierInNewRunspaces` — false positive when `-ArgumentList` is correctly used with `Start-Job`'s script block `param()`
- `PSAvoidUsingDoubleQuotesForConstantString` — purely cosmetic, no correctness benefit
- `PSUseConsistentIndentation` — misfires on intentional multi-line continuation alignment

### Remove-AzureP2SVPN.ps1

Bumped to v1.0.3 with the same cosmetic fixes and the more informative empty-catch replacement.

### Settings file

`PSScriptAnalyzerSettings.psd1` updated with the additional rule exclusions. Each exclusion is documented inline with the reasoning, so future maintainers can re-enable specific rules if they want to enforce stricter standards.

---

## [1.0.8] - 2026-05-17

### Fixed

- **StrictMode-safe property access on `$gateway.VpnClientConfiguration`.** The v1.0.7 idempotency check (added to skip Phase 2 if AAD was already configured) accessed `$gateway.VpnClientConfiguration.AadTenantUri` directly. Under `Set-StrictMode -Version Latest`, accessing a missing property throws instead of returning `$null` — and a brand-new gateway has no `VpnClientConfiguration` object at all yet. The check now uses `PSObject.Properties.Name -contains 'AadTenantUri'` to test for property existence before reading it.

### How v1.0.7 manifested in practice

Phase 1 (gateway creation) succeeded after a 49-minute wait. The script then tried to determine whether Phase 2 was needed by examining the new gateway's VpnClientConfiguration — but the object existed only with the basic settings we passed during creation (no AAD properties), so accessing `.AadTenantUri` threw a strict-mode error. The script exited before applying Phase 2, leaving the gateway in a valid-but-incomplete state.

### Recovery from a v1.0.7 failure

If you hit this with v1.0.7, the gateway exists and only needs Phase 2 applied. Re-run v1.0.8 with the same parameters — it will detect the existing gateway, skip Phase 1, and proceed directly to Phase 2 (which takes 2-5 minutes).

---

## [1.0.7] - 2026-05-16

### Fixed

- **Phase 2 (AAD configuration) now runs when re-running against an existing gateway.** Previously, the entire Phase 1 + Phase 2 block was nested inside the "gateway doesn't exist" branch. So if Phase 1 succeeded but the script was interrupted before Phase 2 (e.g., timeout, Ctrl+C, network hiccup), re-running the script would skip Phase 2 entirely — the gateway would exist but never get its Entra ID configuration. The script now unconditionally runs Phase 2 after Step 3, and detects whether AAD is already configured (idempotent).

- **Recovery from timeout-on-still-running-job.** When the script's timeout fires but Azure's gateway provisioning is still in `Updating` or `Creating` state, the new behavior is to wait for the existing operation to finish on re-run rather than treating the gateway as "done." This handles the common scenario where the script's default timeout is too tight for AZ SKUs (which take 30-60+ minutes vs 25-35 for non-AZ).

### Changed

- **Default `-ProvisioningTimeoutMinutes` raised from 45 to 75.** AZ-variant SKUs (the new required default) take significantly longer to provision than the older non-AZ SKUs because each zone-redundant deployment provisions three gateway replicas, each with its own bootstrap sequence. Microsoft's docs cite 30-45 minutes for AZ SKUs; in practice we've seen runs up to 50+ minutes that still succeed. The previous 45-minute default was tight enough to false-fail genuinely-working provisions.

- **Improved timeout error message.** When the timeout fires, the script now tells the operator the gateway is likely still being created and that re-running will resume from where things left off, rather than implying total failure.

### Behavior on re-run

The script is now genuinely idempotent at all phases:

| State on re-run | Behavior |
|---|---|
| Gateway doesn't exist | Creates it (Phase 1), then configures AAD (Phase 2) |
| Gateway exists, ProvisioningState=Updating/Creating | Waits for it to finish, then configures AAD |
| Gateway exists, AAD not configured | Skips Phase 1, configures AAD (Phase 2 only) |
| Gateway exists, AAD already matches target | Skips both phases, proceeds to client config generation |

This makes the script safe to interrupt and re-run at any point.

---

## [1.0.6] - 2026-05-16

### Added

- **`-NamePrefix` parameter** for consistent resource naming with sibling Azure Innovators deployment scripts (Deploy-ERPNextToAzure, etc).

  When `-NamePrefix 'JTC-prod-westus2'` is passed, the script produces:
  - Gateway: `JTC-prod-westus2-vpngw`
  - Public IP: `JTC-prod-westus2-vpngw-pip`
  - IP Config: `JTC-prod-westus2-vpngw-ipconfig`

  This matches the established pattern of `<prefix>-<resource-type>` naming used across the toolkit (e.g., `<vmname>-nic`, `<vmname>-pip` in the ERPNext script). Resources in the Azure portal that belong to the same engagement now look related to operators viewing them.

### Naming precedence

The script now uses this decision tree for resource names:

1. Explicit `-GatewayName` wins entirely (operator knows exactly what they want)
2. `-NamePrefix` produces `<prefix>-vpngw` (Azure Innovators consultancy pattern)
3. Fall back to VNet-derived name (the standalone-use default for OSS consumers)

The fallback works well when the script is used against a VNet whose name you don't control (e.g., the Wordpress Hosting on Azure VNet `jtcustomtr-2e886f0313-vnet`). The `-NamePrefix` path is the recommended choice for consultancy engagements where multiple Azure Innovators scripts run against the same target environment.

### Remove-AzureP2SVPN.ps1

Bumped to v1.0.2 with the matching `-NamePrefix` parameter. Pass the same prefix to teardown that you passed to setup, and the script locates the right resources.

---

## [1.0.5] - 2026-05-16

### Fixed

- **Public IP zone configuration now matches gateway SKU.** AZ-variant gateway SKUs (VpnGw1AZ, VpnGw2AZ, etc.) require a zone-redundant public IP — Azure rejects gateway creation with `VmssVpnGatewayPublicIpsMustHaveZonesConfigured` if a regional (non-zonal) public IP is attached. The script now creates the public IP with `-Zone @('1','2','3')` when an AZ gateway SKU is selected.

- **Automatic recreation of mismatched orphan public IPs.** If the script finds an existing public IP whose zone configuration doesn't match what the current gateway SKU requires, it deletes and recreates the IP. This handles the common scenario of failed earlier attempts that left non-zonal public IPs behind. Safety: the script refuses to recreate a public IP that's currently attached to another resource.

### Architecture rationale

Zone-redundant public IPs are deployed across all three availability zones in a region. This matches the AZ gateway's zone-redundant deployment posture — both can survive a single-zone outage. A non-zonal (regional) public IP would be a single point of failure for an otherwise zone-redundant gateway, which is why Azure now refuses the combination.

Non-AZ SKUs (where supported, for pre-existing gateways) still use regional public IPs. The script picks the correct configuration automatically based on the `-GatewaySku` value.

### Note on immutability

Zone configuration on a public IP is set at creation time and cannot be changed afterward. The script's auto-recreate logic exists specifically because Azure offers no way to convert a regional public IP into a zone-redundant one in place. New IP address (the old one is released), but everything downstream is configured at deployment time anyway, so this is non-disruptive when the public IP isn't already attached to anything.

---

## [1.0.4] - 2026-05-16

### Changed

- **`-ConfirmContext` semantics changed from interactive prompt to non-interactive bypass.** Previously, passing the flag triggered a `Read-Host 'Is this the correct context? (yes/no)'` prompt. Now, the flag acts as a multi-tenant safety bypass: pass it to acknowledge that you've verified the current context and want to proceed without an explicit `-SubscriptionId`.

  The new behavior matches the convention used by other Azure Innovators deployment scripts (Deploy-ERPNextToAzure.ps1, Remove-ERPNextAzureDeployment.ps1) for consistency.

  **Migration:** If you used `-ConfirmContext` before and typed `yes` at the prompt, the same command line now just works silently. If you used the flag to deliberately invoke the prompt for safety, switch to passing `-SubscriptionId <id>` explicitly for the equivalent intent.

### Why this matters

The previous prompt-based design made the script's behavior diverge from sibling scripts that share the same parameter name. Operators running multiple scripts in sequence shouldn't have to remember which version of `-ConfirmContext` they're dealing with. The bypass-style flag is also strictly more useful in CI/CD scenarios where interactive prompts can't be answered.

### Multi-tenant safety preserved

The script still refuses to run when the active account can see multiple subscriptions and none has been pinned. The decision tree is now:

1. `-SubscriptionId <id>` → switch to that subscription, proceed
2. `-TenantId <id>` → switch tenants first, then evaluate subscriptions
3. Only one accessible subscription → proceed silently
4. Multiple accessible subscriptions + `-ConfirmContext` → proceed silently using the current default
5. Multiple accessible subscriptions, no `-ConfirmContext` → refuse with an error explaining the options

### Remove-AzureP2SVPN.ps1

Bumped to v1.0.1 with the same `-ConfirmContext` semantics change. Both scripts in the repo now use identical context resolution logic.

---

## [1.0.3] - 2026-05-16

### Fixed

- **Default GatewaySku changed to `VpnGw1AZ`.** Azure no longer accepts new VPN gateway deployments with non-AZ SKUs (VpnGw1/2/3 without the AZ suffix). Attempting to create one returns `NonAzSkusNotAllowedForVPNGateway` from the API. The script's default is now `VpnGw1AZ`, which costs the same and provides higher SLA through availability-zone redundancy.

### Added

- **Pre-flight SKU check.** If you pass an explicit non-AZ SKU (e.g., `-GatewaySku VpnGw1`) for a new gateway creation, the script now throws an actionable error up front instead of waiting for Azure to reject the request a minute into provisioning. Non-AZ SKU values remain in the `ValidateSet` so the script can be used against pre-existing non-AZ gateways for read/update operations.

- **SKU options expanded.** The ValidateSet now includes the full range of AZ SKUs: `VpnGw1AZ`, `VpnGw2AZ`, `VpnGw3AZ`, `VpnGw4AZ`, `VpnGw5AZ` (plus the legacy non-AZ values for backward compatibility).

### Documentation

- README cost table updated to reflect AZ SKU pricing (identical to non-AZ counterparts)
- README parameter reference updated for the new default SKU
- Added a note explaining Azure's 2026 SKU consolidation policy

---

## [1.0.2] - 2026-05-16

### Initial public release

First release intended for general use. Built from a private fork that powered an internal ERPNext-on-Azure deployment toolkit, then genericized.

### Setup-AzureP2SVPN.ps1

**Capabilities:**

- Provisions an Azure VPN Gateway (VpnGw1/2/3) in an existing VNet with Entra ID authentication
- Supports both the Microsoft-registered Azure VPN Client app ID (default, no consent required) and the legacy manually-registered app ID via `-UseLegacyAudience` for backward compatibility
- Joins an existing VNet rather than creating one — designed for shared infrastructure topologies
- Creates GatewaySubnet, Public IP, and Gateway with idempotent reuse if any already exist
- Validates GatewaySubnet CIDR fits in VNet address space before consuming Azure provisioning time
- Validates VPN client pool doesn't overlap VNet address space
- Two-phase gateway creation: basic gateway first, then `Set-AzVirtualNetworkGateway` for Entra ID configuration (matches current Az.Network module's parameter structure)
- Robust async polling with `Blocked`-state guard (prevents silent infinite waits when background runspace prompts can't reach a console)
- Multi-tenant safety via `-ConfirmContext` parameter
- Structured result object with all resource identifiers and the client config download URL

**Defaults:**

- Region: westus2
- Gateway SKU: VpnGw1 (~$140/month, minimum that supports Entra ID auth)
- GatewaySubnet: 10.0.3.0/27 (32 IPs, Microsoft's recommended minimum size)
- VPN client pool: 172.16.100.0/24
- VPN client protocol: OpenVPN (required for Entra ID authentication)
- Audience: Microsoft-registered app (`c632b3df-fb67-4d84-bdcf-b95ad541b5c8`)
- Provisioning timeout: 45 minutes

**Key design decisions documented in the script's NOTES section:**

- Why the Microsoft-registered audience is preferred over the legacy one (no tenant consent action required)
- Why the issuer URL needs a trailing slash (per Microsoft docs, connections fail without it)
- Why GatewaySubnet must be named exactly that (Azure platform requirement)
- Why no NSG is attached to GatewaySubnet (Microsoft's documented stance — unsupported, causes unexpected behavior)

### Remove-AzureP2SVPN.ps1

**Capabilities:**

- Tears down the gateway, its public IP, and optionally the GatewaySubnet
- Refuses to delete a gateway with active site-to-site connections (P2S clients are fine — they disconnect cleanly when the gateway goes away)
- Verifies the gateway is actually gone (calls `Get-AzVirtualNetworkGateway` post-deletion) before reporting success
- Inherits the robust async polling pattern from the setup script
- Same multi-tenant safety via `-ConfirmContext`
- Idempotent — won't fail if some resources are already missing

**Safety defaults:**

- GatewaySubnet is NOT removed by default (requires explicit `-RemoveGatewaySubnet` flag) — many shared VNets are owned by a different team than the VPN admin, and modifying the VNet structure should be explicit
- The VNet itself is never touched
- Resource groups are never deleted (they typically contain other resources)

---

## Provenance

This project originated as part of a larger ERPNext-on-Azure deployment toolkit for a specific consulting engagement. Through that work, the P2S VPN setup logic was abstracted from the application-specific deployment scripts and ended up being clean general-purpose Azure networking automation worth releasing on its own.

The internal lessons that shaped this version's design — particularly around PowerShell job state handling (`Blocked` state is a real failure mode that requires explicit handling) and Azure module parameter naming evolution (`VpnClientAad*` parameters were removed from `New-AzVirtualNetworkGateway` in recent Az.Network versions in favor of the two-phase create-then-configure pattern) — are documented inline in the scripts where future maintainers will see them.

[1.1.0]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.1.0
[1.0.9]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.9
[1.0.8]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.8
[1.0.7]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.7
[1.0.6]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.6
[1.0.5]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.5
[1.0.4]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.4
[1.0.3]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.3
[1.0.2]: https://github.com/JONeillSr/Setup-AzureP2SVPN/releases/tag/v1.0.2

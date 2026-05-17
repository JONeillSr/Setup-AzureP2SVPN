# Setup-AzureP2SVPN

PowerShell automation for Azure Point-to-Site (P2S) VPN Gateway with Microsoft Entra ID authentication.

Creates a VPN gateway in an existing Azure VNet, configures Entra ID authentication using the Microsoft-registered audience (no tenant admin consent required), and produces a downloadable VPN client configuration package ready for the Azure VPN Client app.

[![PSScriptAnalyzer](https://github.com/JONeillSr/Setup-AzureP2SVPN/actions/workflows/lint.yml/badge.svg)](https://github.com/JONeillSr/Setup-AzureP2SVPN/actions/workflows/lint.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.2%2B-blue?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Az.Network](https://img.shields.io/badge/Az.Network-5.0%2B-blue)](https://www.powershellgallery.com/packages/Az.Network)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## What this is for

You have an Azure VNet with private resources (a VM running a private service, an App Service with VNet integration, a database) and you want authorized people to reach those resources securely without exposing public endpoints. Azure P2S VPN with Entra ID auth is the right architecture for that — but the manual portal setup involves a sequence of steps that's easy to get wrong (which audience value? which issuer URL? what's a GatewaySubnet? do I need tenant consent?).

This repo automates the whole thing in two scripts:

- **`Setup-AzureP2SVPN.ps1`** — provisions the gateway end-to-end (~30 min including Azure's gateway provisioning time)
- **`Remove-AzureP2SVPN.ps1`** — tears it down cleanly when you're done (~10-15 min)

Both scripts are designed to be safe to run against shared/production VNets — they only touch the resources they create, never the VNet itself or anything else inside it.

## Highlights

- **No tenant admin consent needed.** Uses the Microsoft-registered Azure VPN Client app ID by default, which is pre-registered globally. The legacy manually-registered app pattern (which required a consent action) is supported via `-UseLegacyAudience` for backward compatibility, but you almost certainly don't need it.
- **Joins existing VNets.** The script doesn't create or modify your VNet — it just adds the GatewaySubnet inside it and provisions a gateway. Designed for the common case where your VNet already exists and is shared with other workloads.
- **Pre-flight checks.** Validates that the requested GatewaySubnet CIDR fits inside the VNet's address space, that the VPN client pool doesn't overlap VNet space, and that the VNet region matches the deployment region — before consuming the 30 minutes of Azure provisioning time.
- **Multi-tenant safety.** Optional `-ConfirmContext` forces explicit confirmation of the active Entra tenant and subscription before doing anything destructive. Recommended if you authenticate to multiple Azure tenants (consultants, MSPs, multi-environment teams).
- **Robust async polling.** Gateway provisioning runs as a background job with proper handling of all PowerShell job states including `Blocked` (which is normally a silent infinite-wait failure mode for async Az cmdlets — guarded explicitly here).
- **Clean teardown.** The companion `Remove-AzureP2SVPN.ps1` script refuses to delete a gateway with active site-to-site connections, optionally removes the GatewaySubnet, and confirms deletion actually happened before reporting success.

## Quick start

### Prerequisites

- PowerShell 7.2 or later
- Az.Accounts, Az.Network, Az.Resources modules (`Install-Module Az -Scope CurrentUser`)
- Owner or Contributor role on the target Azure subscription
- An existing VNet in the target subscription with enough address space for a `/27` GatewaySubnet (32 IPs)

### Provision a VPN Gateway

```powershell
Connect-AzAccount

.\Setup-AzureP2SVPN.ps1 -ConfirmContext `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -Location 'eastus'
```

This will:

1. Verify the VNet exists and is in the target region
2. Validate the GatewaySubnet and VPN client pool CIDRs
3. Create the GatewaySubnet (default: `10.0.3.0/27`)
4. Create a Standard Public IP for the gateway
5. Provision the gateway (VpnGw1 SKU, this takes 25-35 minutes)
6. Apply Entra ID authentication configuration
7. Generate a VPN client config bundle for download

Total time: ~30 minutes (most of it Azure's gateway provisioning, which the script polls every 60 seconds).

### Connect from your device

After the script finishes, it prints a download URL for the VPN client config bundle. Save the file (the URL expires after 1 hour).

1. Install the **Azure VPN Client** app:
   - Windows: Microsoft Store
   - macOS: Mac App Store
   - iOS: App Store
   - Android: Play Store

2. Unzip the downloaded config bundle. You'll see folders for different VPN types; use the `AzureVPN` folder for Entra ID auth.

3. Open Azure VPN Client → **Import** → select the `azurevpnconfig.xml` from the `AzureVPN` folder.

4. Click **Connect**. Sign in with your Microsoft account when prompted.

5. You're now on the VNet. Resources at private IPs (e.g., `10.0.2.4`) are reachable from your laptop.

### Tear it down

```powershell
.\Remove-AzureP2SVPN.ps1 -Force `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -RemoveGatewaySubnet
```

Removes the gateway, its public IP, and (with `-RemoveGatewaySubnet`) the GatewaySubnet. Leaves the VNet and any other resources untouched.

## Architecture

```
                 Your laptop (Azure VPN Client app)
                 Authenticates with Microsoft account
                          │
                          │  Encrypted OpenVPN tunnel
                          ▼
                     Internet
                          │
                          ▼
        ┌────────────────────────────────────────────┐
        │   Azure VNet                               │
        │                                            │
        │   ┌─────────────────────────────────────┐  │
        │   │  VPN Gateway (VpnGw1)               │  │
        │   │  GatewaySubnet                      │  │
        │   │  Client pool: 172.16.100.0/24       │  │
        │   │  Entra ID authentication            │  │
        │   └────────────────┬────────────────────┘  │
        │                    │ routes to             │
        │                    ▼                       │
        │   ┌─────────────────────────────────────┐  │
        │   │  Your existing private resources    │  │
        │   │  (VMs, App Services, databases...)  │  │
        │   └─────────────────────────────────────┘  │
        └────────────────────────────────────────────┘
```

The script never creates, modifies, or even reads the contents of your existing resources. It only:

1. Adds a `GatewaySubnet` to your VNet
2. Creates a public IP in your chosen resource group
3. Creates a VPN Gateway and attaches it to the GatewaySubnet
4. Configures the gateway with Entra ID auth + a VPN client pool

## Cost

| Component | Monthly (USD) |
|---|---|
| VpnGw1AZ gateway | ~$140 |
| Standard Public IP | ~$4 |
| **Total** | **~$144** |

Higher SKUs are available (VpnGw2AZ ~$370, VpnGw3AZ ~$900) for higher throughput needs. The Basic SKU (~$30/month) is cheaper but **does not support Entra ID authentication** — only certificate-based or RADIUS. If you need to keep cost down and don't mind managing certificates per device, edit the script to use Basic SKU; otherwise VpnGw1AZ is the practical minimum.

**Note on AZ SKUs:** As of 2026, Azure requires availability-zone (AZ) SKUs for all new VPN gateway deployments. Non-AZ SKUs (VpnGw1, VpnGw2, etc., without the AZ suffix) are no longer accepted by the platform. AZ SKUs cost the same as their non-AZ counterparts but provide higher SLA through zone-redundant deployment.

## Configuration reference

### Setup-AzureP2SVPN.ps1

| Parameter | Default | Description |
|---|---|---|
| `-VNetName` | (required) | Existing VNet to attach the gateway to |
| `-VNetResourceGroup` | (required) | Resource group containing the VNet |
| `-ResourceGroupName` | = VNetResourceGroup | Where to create the gateway and public IP |
| `-Location` | `westus2` | Azure region (must match VNet region) |
| `-GatewaySubnetPrefix` | `10.0.3.0/27` | CIDR for the new GatewaySubnet |
| `-VPNClientAddressPool` | `172.16.100.0/24` | CIDR pool for VPN clients (must not overlap VNet) |
| `-NamePrefix` | (none, falls back to VNet-derived) | Prefix for resource names; e.g., `JTC-prod-westus2` produces `JTC-prod-westus2-vpngw`. Matches Azure Innovators script conventions. |
| `-GatewayName` | derived from `-NamePrefix` or VNet name | Custom gateway name |
| `-GatewaySku` | `VpnGw1AZ` | Gateway SKU (VpnGw1AZ/2AZ/3AZ/4AZ/5AZ). Non-AZ SKUs are no longer accepted by Azure for new gateways. |
| `-UseLegacyAudience` | off | Use legacy manually-registered Azure VPN app instead of Microsoft-registered |
| `-ConfirmContext` | off | Multi-tenant safety bypass: accept the current Azure context without explicit `-SubscriptionId` |
| `-TenantId` | current context | Override Entra tenant |
| `-SubscriptionId` | current context | Override subscription |
| `-ProvisioningTimeoutMinutes` | 45 | How long to wait for gateway creation |

### Remove-AzureP2SVPN.ps1

| Parameter | Default | Description |
|---|---|---|
| `-VNetName` | (required) | VNet the gateway is attached to |
| `-VNetResourceGroup` | (required) | RG containing the VNet |
| `-NamePrefix` | (none) | Use the same value passed to Setup-AzureP2SVPN |
| `-GatewayName` | derived from `-NamePrefix` or VNet name | Override gateway name |
| `-ResourceGroupName` | = VNetResourceGroup | RG where the gateway lives |
| `-RemoveGatewaySubnet` | off | Also remove the GatewaySubnet from the VNet |
| `-Force` | off | Skip the interactive confirmation prompt |
| `-TimeoutMinutes` | 30 | How long to wait for gateway deletion |

## See also

- [User Guide](USER-GUIDE.md) — Detailed walkthrough including architecture decisions, troubleshooting, and integration patterns
- [CHANGELOG](CHANGELOG.md) — Version history
- [Microsoft Learn: P2S VPN with Entra ID](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-entra-gateway)
- [Microsoft Learn: VPN Gateway SKUs](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings)

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Pull requests welcome. The scripts deliberately avoid being too clever — they prioritize readability and obvious operation order over PowerShell-isms. Please match that style if contributing.

## Author

**John O'Neill Sr.** — Azure Innovators
- GitHub: [@JONeillSr](https://github.com/JONeillSr/)

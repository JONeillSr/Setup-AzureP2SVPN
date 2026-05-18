# Setup-AzureP2SVPN

PowerShell automation for Azure Point-to-Site (P2S) VPN Gateway with Microsoft Entra ID authentication.

Creates a VPN gateway in an existing Azure VNet, configures Entra ID authentication using the Microsoft-registered audience (no tenant admin consent required), and produces a downloadable VPN client configuration package ready for the Azure VPN Client app.

[![PSScriptAnalyzer](https://github.com/JONeillSr/Setup-AzureP2SVPN/actions/workflows/lint.yml/badge.svg)](https://github.com/JONeillSr/Setup-AzureP2SVPN/actions/workflows/lint.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.2%2B-blue?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Az.Network](https://img.shields.io/badge/Az.Network-5.0%2B-blue)](https://www.powershellgallery.com/packages/Az.Network)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## What this is for

You have an Azure VNet with private resources (a VM running a private service, an App Service with VNet integration, a database) and you want authorized people to reach those resources securely without exposing public endpoints. Azure P2S VPN with Entra ID auth is the right architecture for that — but the manual portal setup involves a sequence of steps that's easy to get wrong (which audience value? which issuer URL? what's a GatewaySubnet? do I need tenant consent?).

This repo automates the whole thing:

- **`Setup-AzureP2SVPN.ps1`** — provisions the gateway end-to-end (~30 min including Azure's gateway provisioning time)
- **`Remove-AzureP2SVPN.ps1`** — tears it down cleanly when you're done (~10-15 min)
- **`Add-AzureSplitHorizonDNS.ps1`** — creates a Private DNS Zone mirroring your public zone so internal services resolve to private IPs over VPN
- **`Add-AzureDNSForwarder.ps1`** — provisions a small dnsmasq VM (Ubuntu) in your VNet so VPN clients can actually query that private DNS

All four scripts are designed to be safe to run against shared/production VNets — they only touch the resources they create, never the VNet itself or anything else inside it.

## The complete VPN access pattern

A bare P2S VPN gateway gives clients network reachability — they can `Test-NetConnection 10.0.2.4 -Port 443` and it works. But they can't type `https://erpnext.example.com` in a browser because their laptop's DNS still resolves that hostname against the public internet, which either returns a public IP (wrong) or doesn't exist at all (worse).

This repo's full pattern solves that with three layers:

1. **VPN gateway** (Setup-AzureP2SVPN) — Network reachability via Entra-authenticated tunnel
2. **Private DNS Zone** (Add-AzureSplitHorizonDNS) — Internal records that resolve `erpnext.example.com → 10.0.2.4`
3. **DNS forwarder VM** (Add-AzureDNSForwarder) — Bridges VPN clients to Azure DNS so they actually see those internal records

After all three are deployed, VPN-connected users can use the same FQDN as the public internet but get the internal IP. From inside the VNet, services already work via Azure's built-in "magic" DNS at 168.63.129.16. From outside the VPN, the public DNS continues to point wherever you've configured it (a public-facing IP, or simply nowhere if the service isn't exposed publicly).

You can also deploy just steps 1 and 2 and have internal-VNet resources resolve internal names correctly without needing the forwarder. The forwarder is only required for VPN-client DNS resolution.

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

### Set up DNS for VPN clients (optional but recommended)

Once the gateway is up and you can reach private IPs over VPN, the next step is usually getting hostnames to resolve correctly. By default your laptop still asks the public internet for `erpnext.example.com`, which returns the wrong answer (a public IP) or nothing at all.

To fix that:

```powershell
# Step 1: Create a private DNS zone that mirrors your public zone
.\scripts\Add-AzureSplitHorizonDNS.ps1 -ConfirmContext `
    -PublicZoneName 'contoso.com' `
    -PublicZoneResourceGroup 'contoso-dns-rg' `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -PrivateRecords @{ 'erpnext' = '10.0.2.4'; 'wiki' = '10.0.2.5' } `
    -CopyPublicRecords

# Step 2: Provision a DNS forwarder VM so VPN clients can query the private zone
.\scripts\Add-AzureDNSForwarder.ps1 -ConfirmContext `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -VPNClientAddressPool '172.16.100.0/24' `
    -SSHPublicKeyPath '~/.ssh/id_ed25519.pub'

# Step 3: Regenerate your VPN client profile so it picks up the new VNet DNS
$url = New-AzVpnClientConfiguration -ResourceGroupName 'contoso-network-rg' `
    -Name 'contoso-vpngw' -AuthenticationMethod EAPTLS
Invoke-WebRequest -Uri $url.VpnProfileSASUrl -OutFile 'vpnclient.zip'
```

After re-importing the regenerated profile in Azure VPN Client, `nslookup erpnext.contoso.com` from your laptop returns the private IP (10.0.2.4) instead of the public one. See [USER-GUIDE.md](USER-GUIDE.md#dns-for-vpn-clients) for the deep dive on why this architecture works the way it does and how to verify each layer.

### Tear it down

```powershell
.\Remove-AzureP2SVPN.ps1 -Force `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -RemoveGatewaySubnet
```

Removes the gateway, its public IP, and (with `-RemoveGatewaySubnet`) the GatewaySubnet. Leaves the VNet and any other resources untouched.

## Architecture

The base gateway-only architecture (what `Setup-AzureP2SVPN.ps1` provisions):

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
        │   │  VPN Gateway (VpnGw1AZ)             │  │
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

The complete pattern with DNS scripts added (split-horizon DNS + forwarder):

```
                 Your laptop (Azure VPN Client app)
                          │
                          │  DNS query: erpnext.contoso.com
                          ▼
                  ┌───────────────┐
                  │ NRPT routes   │  ← VPN profile says "use 10.0.3.36 for DNS"
                  │ to forwarder  │
                  └───────┬───────┘
                          │ encrypted tunnel
                          ▼
        ┌────────────────────────────────────────────┐
        │   Azure VNet                               │
        │                                            │
        │   ┌─────────────────────────────────────┐  │
        │   │  DNS Forwarder VM (dnsmasq)         │  │
        │   │  Static IP 10.0.3.36                │  │
        │   │  Forwards to 168.63.129.16          │  │
        │   └────────────────┬────────────────────┘  │
        │                    │ queries               │
        │                    ▼                       │
        │   ┌─────────────────────────────────────┐  │
        │   │  Azure DNS (168.63.129.16)          │  │
        │   │  → sees linked Private DNS Zone     │  │
        │   │  → returns 10.0.2.4                 │  │
        │   └─────────────────────────────────────┘  │
        │                                            │
        │   Browser then connects to 10.0.2.4        │
        │   over the existing VPN tunnel             │
        └────────────────────────────────────────────┘
```

The scripts never create, modify, or even read the contents of your existing resources. They only:

1. Adds a `GatewaySubnet` to your VNet
2. Creates a public IP in your chosen resource group
3. Creates a VPN Gateway and attaches it to the GatewaySubnet
4. Configures the gateway with Entra ID auth + a VPN client pool

## Cost

Base VPN gateway:

| Component | Monthly (USD) |
|---|---|
| VpnGw1AZ gateway | ~$140 |
| Standard Public IP | ~$4 |
| **Subtotal** | **~$144** |

Optional DNS scripts (if you also deploy split-horizon + forwarder):

| Component | Monthly (USD) |
|---|---|
| Private DNS Zone | ~$0.50 + ~$0.40 per million queries (negligible) |
| Forwarder VM (Standard_B1s) | ~$8 |
| Forwarder managed disk (30 GB Standard SSD) | ~$2.40 |
| **DNS subtotal (single VM)** | **~$11** |
| Forwarder HA mode adds a second VM | +~$10 |

**Total with full DNS stack: ~$155/month** for the gateway + single-VM forwarder.

Higher gateway SKUs are available (VpnGw2AZ ~$370, VpnGw3AZ ~$900) for higher throughput needs. The Basic SKU (~$30/month) is cheaper but **does not support Entra ID authentication** — only certificate-based or RADIUS. If you need to keep cost down and don't mind managing certificates per device, edit the script to use Basic SKU; otherwise VpnGw1AZ is the practical minimum.

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

### Add-AzureSplitHorizonDNS.ps1

| Parameter | Default | Description |
|---|---|---|
| `-PublicZoneName` | (required) | Name of the existing public DNS zone to mirror, e.g. `contoso.com` |
| `-PublicZoneResourceGroup` | (required) | RG containing the public zone |
| `-VNetName` | (required) | VNet to link the private zone to |
| `-VNetResourceGroup` | (required) | RG containing the VNet |
| `-PrivateZoneResourceGroup` | = VNetResourceGroup | Where to create the private zone |
| `-PrivateRecords` | empty | Hashtable: `@{ 'erpnext' = '10.0.2.4' }` or detailed form `@{ 'mail' = @{Type='CNAME'; Value='outlook.com'} }` |
| `-CopyPublicRecords` | off | Smart-copy public records with mail-DNS exclusion and override flagging |
| `-PrivateZoneLinkName` | derived from VNet name | Name for the VNet-to-zone link |
| `-EnableAutoRegistration` | off | Auto-register VMs in the linked VNet into the zone |
| `-DefaultTTL` | 3600 | Default TTL (seconds) for records the script adds |
| `-ConfirmContext`, `-TenantId`, `-SubscriptionId` | | Multi-tenant safety (same pattern as other scripts) |

### Add-AzureDNSForwarder.ps1

| Parameter | Default | Description |
|---|---|---|
| `-VNetName` | (required) | VNet to deploy the forwarder into |
| `-VNetResourceGroup` | (required) | RG containing the VNet |
| `-ResourceGroupName` | `<VNet RG>-dns-rg` | RG for the forwarder VM resources |
| `-NamePrefix` | derived from VNet name | Prefix for VM/NSG/NIC names |
| `-ExistingSubnetName` | (none) | Use an existing subnet instead of creating a new one |
| `-DNSSubnetCIDR` | auto-derived | CIDR for the new DNS subnet (if not using existing) |
| `-VMSize` | `Standard_B1s` | VM size for the forwarder |
| `-AdminUsername` | `azureadmin` | Admin user for the forwarder VM |
| `-SSHPublicKeyPath` | (none) | SSH key for VM auth; if omitted, a random password is generated |
| `-HighAvailability` | off | Provision two forwarder VMs for active/active redundancy |
| `-VPNClientAddressPool` | (none) | CIDR of the VPN client pool; opens port 53 in the NSG to this range |
| `-NoUpdateVNetDNS` | off | Skip updating the VNet's `DhcpOptions.DnsServers` |
| `-AllowedSSHSourceCIDR` | `VirtualNetwork` | NSG source CIDR for SSH access |
| `-ConfirmContext`, `-TenantId`, `-SubscriptionId` | | Multi-tenant safety (same pattern as other scripts) |

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

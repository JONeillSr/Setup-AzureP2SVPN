# Setup-AzureP2SVPN — User Guide

A practical walkthrough for provisioning, using, and tearing down Azure Point-to-Site VPN with Entra ID authentication, including the optional DNS scripts that complete the access pattern for VPN clients.

**Author:** John O'Neill Sr. — Azure Innovators
**Last Updated:** 05/18/2026
**Applies to script versions:** Setup 1.0.9+, Remove 1.0.3+, DNS scripts 1.0.0+

---

## Table of contents

1. [When to use this](#when-to-use-this)
2. [Prerequisites](#prerequisites)
3. [Architecture decisions explained](#architecture-decisions-explained)
4. [Step-by-step deployment](#step-by-step-deployment)
5. [Client setup (Windows, macOS, iOS, Android)](#client-setup)
6. [DNS for VPN clients](#dns-for-vpn-clients)
7. [Common deployment scenarios](#common-deployment-scenarios)
8. [Troubleshooting](#troubleshooting)
9. [Security considerations](#security-considerations)
10. [Operations and maintenance](#operations-and-maintenance)
11. [Tearing down](#tearing-down)
12. [Frequently asked questions](#frequently-asked-questions)

---

## When to use this

P2S VPN with Entra ID is the right architecture when:

- **You have private resources in an Azure VNet** that authorized people need to reach (admin consoles, internal apps, databases, RDP/SSH to private VMs)
- **You don't want those resources publicly accessible** (no public IPs, NSG rules locked down to VirtualNetwork service tag)
- **Users authenticate with their existing Microsoft accounts** (no certificate management overhead, no separate identity store)
- **Connectivity is per-user, not site-to-site** (each person connects from their own device, not from an office network)

If your situation differs, consider:

| Need | Better fit |
|---|---|
| Office network → Azure VNet always-on | Site-to-Site VPN or ExpressRoute |
| Browser-only access to admin consoles | Azure Bastion |
| Certificate-based auth (no Entra) | Same script with Basic SKU + certificate config (requires editing) |
| Hundreds of concurrent users | VpnGw2 or higher SKU |
| Compliance requires PFS, specific ciphers | Edit the script to add `-VpnClientIpsecPolicy` |

---

## Prerequisites

### Software

- **PowerShell 7.2+** — Windows PowerShell 5.1 will not work. Verify with `$PSVersionTable.PSVersion`.
- **Az PowerShell modules** version 9.0+:
  ```powershell
  Install-Module Az -Scope CurrentUser -Force
  Connect-AzAccount
  ```

### Azure access

- **Subscription role:** Contributor or Owner on the subscription where the gateway will live
- **VNet permissions:** Network Contributor (or higher) on the VNet's resource group — needed to add the GatewaySubnet
- **Entra role:** None needed if using the default Microsoft-registered audience. If you pass `-UseLegacyAudience`, you'll need Global Administrator or Application Administrator for the one-time tenant consent step.

### Network plan

Before running the script, decide on:

1. **GatewaySubnet CIDR.** Must fit inside your VNet's address space and not overlap any existing subnet. Default is `10.0.3.0/27` (32 IPs). Microsoft requires at least a /29 (8 IPs), but `/27` is recommended for future features.
2. **VPN client address pool.** A separate CIDR (must NOT overlap your VNet) that gets handed out to connected clients. Default is `172.16.100.0/24` (256 IPs). The pool should be sized for the maximum concurrent users you expect plus headroom.
3. **Gateway region.** Must match the VNet's region. The script enforces this.
4. **Gateway SKU.** VpnGw1AZ is the default. Higher SKUs are available; see [the SKU table in the README](README.md#cost). As of 2026, Azure requires AZ-variant SKUs for new gateways — non-AZ SKUs (VpnGw1, VpnGw2, etc.) are no longer accepted.

### VNet must already exist

The script doesn't create or modify your VNet — it joins an existing one. If you don't have a VNet yet, create one in the portal first or with `New-AzVirtualNetwork`.

---

## Architecture decisions explained

The script's defaults reflect specific choices. Here's the reasoning so you can decide whether to override them.

### Why VpnGw1AZ by default, not Basic?

**Basic SKU is ~$30/month vs VpnGw1AZ's ~$140/month**, so the cheaper option is tempting. But:

- **Basic SKU does not support Entra ID authentication.** Only certificate-based or RADIUS. This is the dealbreaker — Entra ID is what makes this whole setup pleasant to operate (no per-device cert management, instant offboarding via disabling the user in Entra).
- Basic SKU is being deprecated for public IPs. The migration tool moves Basic to VpnGw1AZ automatically.
- **As of 2026, Azure no longer allows new gateway creation with non-AZ SKUs** (VpnGw1, VpnGw2, etc. without the AZ suffix). Only the AZ variants (VpnGw1AZ, VpnGw2AZ, etc.) can be created. AZ SKUs cost the same and provide higher SLA through availability-zone-redundant deployment.

If you're truly cost-constrained and willing to manage certificates manually, you can edit the script to use Basic SKU and add `-VpnClientRootCertificates`. But for most use cases, the $110/month premium for Entra ID auth pays for itself the first time you onboard a new user.

### Why OpenVPN protocol only?

Azure VPN Gateway supports multiple tunneling protocols (IKEv2, SSTP, OpenVPN). **OpenVPN is required for Entra ID authentication** — the other protocols don't support modern OAuth2 flows. Since this script's whole point is Entra ID auth, OpenVPN is the only choice.

This is fine because the Azure VPN Client app supports OpenVPN across all major platforms (Windows, macOS, iOS, Android, Linux).

### Why the Microsoft-registered audience by default?

There are two app IDs that work for Azure VPN authentication:

| App ID | Origin | Tenant Consent? | Linux Support? |
|---|---|---|---|
| `c632b3df-fb67-4d84-bdcf-b95ad541b5c8` | Microsoft-registered (newer) | **Not required** | Yes |
| `41b23e61-6c1e-4545-b367-cd054e0ed4b4` | Manually-registered (legacy) | Required (one-time per tenant) | No |

The newer audience is strictly better — no consent ceremony, supports Linux clients, same security posture. The script defaults to it. The `-UseLegacyAudience` switch exists only for backward compatibility with older Azure VPN Client versions that haven't been updated since 2023.

### Why 10.0.3.0/27 for GatewaySubnet, not /29?

`/29` is the minimum size Microsoft requires (8 IPs). `/27` (32 IPs) gives headroom for future features like ExpressRoute coexistence, active-active gateway pairs, or scale-up — none of which require a bigger subnet *today*, but adding address space to a gateway subnet later requires deleting and recreating the gateway, which is a 30-minute outage. The 24 extra IPs are essentially free.

### Why 172.16.100.0/24 for the client pool?

Three reasons:

1. **Doesn't overlap with common VNet ranges.** Most Azure VNets are in `10.0.0.0/8`. The client pool must be different, and `172.16.0.0/12` is the next RFC 1918 block that's almost never used in Azure.
2. **Plenty of room.** 254 usable client IPs (Azure reserves a few). Far more than you'll need unless you have a huge user base.
3. **Easy to remember.** `172.16.100.x` is distinct enough from your VNet that you'll recognize "this connection came from a VPN client" at a glance in logs.

Override with `-VPNClientAddressPool` if you have a conflict (e.g., your on-premises network already uses `172.16.x.x`).

### Why join an existing VNet rather than creating one?

In practice, P2S VPN is almost always added to an existing VNet that has the resources people need to reach. Creating a fresh VNet just for VPN access doesn't help — you'd then need to peer it to the production VNet, which adds complexity without security benefit. The script reflects this by making `-VNetName` mandatory.

If you genuinely want a dedicated VPN VNet, create it first with `New-AzVirtualNetwork`, then point the script at it.

---

## Step-by-step deployment

### Step 1: Verify your environment

```powershell
# Confirm PowerShell version
$PSVersionTable.PSVersion

# Connect to Azure
Connect-AzAccount

# Verify you're in the right tenant + subscription
Get-AzContext
```

### Step 2: Find your VNet's address space

```powershell
Get-AzVirtualNetwork -Name 'YOUR-VNET-NAME' -ResourceGroupName 'YOUR-VNET-RG' |
    Select-Object Name, @{N='AddressSpace';E={$_.AddressSpace.AddressPrefixes -join ', '}}, Location
```

Confirm the VNet has room for a `/27` (32 IPs) inside one of its address prefixes. If not, expand it first:

```powershell
$vnet = Get-AzVirtualNetwork -Name 'YOUR-VNET-NAME' -ResourceGroupName 'YOUR-VNET-RG'
$vnet.AddressSpace.AddressPrefixes.Add('10.0.3.0/24')   # or whatever fits
$vnet | Set-AzVirtualNetwork
```

Adding an address space to a VNet is non-disruptive — existing resources keep working.

### Step 3: Run the setup script

```powershell
.\Setup-AzureP2SVPN.ps1 -ConfirmContext `
    -VNetName 'YOUR-VNET-NAME' `
    -VNetResourceGroup 'YOUR-VNET-RG' `
    -Location 'YOUR-VNET-REGION'
```

You'll see a context confirmation prompt:

```
ACTIVE AZURE CONTEXT
  Account:        you@example.com
  Tenant:         abc12345-...
  Subscription:   Production (sub-id-...)

Is this the correct context? (yes/no): yes
```

Type `yes` to proceed. Then the script:

1. Runs pre-flight checks (~30 seconds)
2. Shows the deployment plan
3. Creates the GatewaySubnet (~5 seconds)
4. Creates the Public IP (~5 seconds)
5. **Provisions the gateway** — this is the slow part, 25-35 minutes
6. Applies Entra ID configuration (~1-2 minutes)
7. Generates a downloadable VPN client config bundle

Total time: **~30 minutes**. Most of that is Azure's gateway provisioning, which is fundamentally slow — there's no way to speed it up.

### Step 4: Save the client config URL

When the script finishes, it prints:

```
Download the VPN Client Package:
  URL: https://....blob.core.windows.net/.../vpnconfig.zip?sv=...
  (Expires after 1 hour. Save the file before then.)
```

**Download this file immediately.** The URL expires in 1 hour. If you miss the window, regenerate it from the Azure portal: VPN Gateway → Point-to-site configuration → Download VPN client.

---

## Client setup

After downloading and extracting the config bundle, you'll see folders like:

```
vpnclientconfiguration/
├── AzureVPN/                  ← Use this folder for Entra ID auth
│   └── azurevpnconfig.xml
├── Generic/
└── OpenVPN/
```

### Windows

1. Install the **Azure VPN Client** from the Microsoft Store: https://aka.ms/azvpnclientdownload
2. Open the app
3. Click **+** → **Import** at the bottom left
4. Browse to `AzureVPN/azurevpnconfig.xml` and select it
5. Confirm the connection name and click **Save**
6. Click **Connect** on the new connection
7. Sign in with your Microsoft account when prompted

### macOS

1. Install **Azure VPN Client** from the Mac App Store
2. Open the app
3. Click **+** → **Import** → select `AzureVPN/azurevpnconfig.xml`
4. Click **Save**, then **Connect**
5. Sign in with your Microsoft account

### iOS

1. Install **Azure VPN** from the App Store
2. Email the `azurevpnconfig.xml` file to yourself (or use AirDrop / iCloud Drive)
3. Open the file on your iOS device — it will offer to open it in Azure VPN
4. Tap **Connect** in the app
5. Sign in with your Microsoft account

### Android

1. Install **Azure VPN Client** from the Play Store
2. Transfer the `azurevpnconfig.xml` to your device (Google Drive, email, USB)
3. In the app, tap **Import** → select the file
4. Tap **Connect**
5. Sign in with your Microsoft account

### Verifying the connection

Once connected, your device gets an IP from the client pool (e.g., `172.16.100.4`).

```bash
# Linux/macOS
ifconfig | grep 172.16.100

# Windows
ipconfig | findstr 172.16.100
```

Then test reachability to a private resource in the VNet:

```bash
# Replace 10.0.2.4 with the private IP of something in your VNet
curl http://10.0.2.4/        # or whatever protocol/port

# Or just ping it
ping 10.0.2.4
```

If you get a response, you're in.

---

## DNS for VPN clients

After completing the gateway setup, VPN-connected clients can reach private IPs but they can't yet resolve internal hostnames (`erpnext.contoso.com`, `wiki.contoso.com`) to those private IPs. This section walks through the two scripts that complete the access pattern.

### Why this is non-trivial

The naive expectation is "I'll just add `erpnext → 10.0.2.4` to a DNS zone somewhere and VPN clients will pick it up." Unfortunately the Azure platform has three constraints that make this harder than it looks:

1. **Azure's built-in DNS resolver (`168.63.129.16`) only answers queries from inside the VNet.** VPN clients can't query it directly even when connected — the IP is reachable, but the service refuses queries not originating from a VNet-internal interface.

2. **VPN clients don't automatically inherit VNet DNS settings.** When you set `DhcpOptions.DnsServers` on a VNet, that pushes DNS info to resources INSIDE the VNet (VMs, App Services with VNet integration). VPN clients connect to the VNet but don't pick up those settings from the VNet — they pick them up from the **VPN client profile XML**, which is generated by the gateway based on... `DhcpOptions.DnsServers`. So in theory it works, but only after a profile regeneration step that's easy to forget.

3. **Public Azure DNS zones and Private Azure DNS zones are separate resources.** They have the same naming format but they're different objects. You can have `contoso.com` as a public zone (delegated from your registrar) AND `contoso.com` as a private zone (linked to your VNet) — same name, different records, served to different audiences. This is the "split-horizon" or "split-brain" pattern.

The two scripts in `scripts/` handle each piece.

### The complete pattern

```
                    Public DNS (your registrar → Azure DNS)
                         erpnext.contoso.com → 1.2.3.4 (or nothing)
                                        ▲
                                        │ Internet users
                                        │
   ──────────────────────────────────────────────────────────────────
                                        │ VPN-connected users (different DNS path)
                                        ▼
                       VPN client laptop
                              │
                              │ DNS query routed via NRPT to forwarder
                              ▼
                  ┌───────────────────────────────┐
                  │  Forwarder VM (10.0.3.36)      │
                  │  dnsmasq forwards → 168.63...  │
                  └───────────────┬───────────────┘
                                  ▼
                  ┌───────────────────────────────┐
                  │  Azure DNS (168.63.129.16)    │
                  │  → linked Private Zone        │
                  │  → erpnext.contoso.com →      │
                  │     10.0.2.4                  │
                  └───────────────────────────────┘
```

### Step 1: Create the Private DNS Zone

```powershell
.\scripts\Add-AzureSplitHorizonDNS.ps1 -ConfirmContext `
    -PublicZoneName 'contoso.com' `
    -PublicZoneResourceGroup 'contoso-dns-rg' `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -PrivateRecords @{
        'erpnext' = '10.0.2.4'
        'wiki'    = '10.0.2.5'
        'db'      = '10.0.1.10'
    } `
    -CopyPublicRecords
```

What this does:

1. Creates an Azure Private DNS Zone named `contoso.com` (same name as your public zone). Azure recognizes this is allowed because public and private DNS zones are different resource types.
2. Links it to `contoso-prod-vnet`. Once linked, any resource INSIDE the VNet (or anyone using a DNS resolver that targets `168.63.129.16` from inside the VNet) sees the private zone's records.
3. Adds the three explicit records you specified.
4. With `-CopyPublicRecords`, walks every record in the public zone and copies them into the private zone, with smart exclusion:
   - **MX/SPF/DKIM/DMARC records are skipped** — mail flow should still use public DNS, even from inside the VNet (your VPN-connected laptop sends mail through real mail servers via the internet, not through your private DNS).
   - **A/AAAA records pointing to public IPs are flagged** — these get copied but the script warns you they're probably candidates for an explicit override. Example: your public `app.contoso.com → 13.65.x.x` doesn't make sense as `13.65.x.x` from inside the VNet; you probably want it to point to the internal IP instead.

After this step, resources INSIDE the VNet already resolve internal names correctly. VMs, App Services with VNet integration, and the forwarder VM (next step) all see the private zone via Azure DNS.

What's still missing: VPN clients. They can't query `168.63.129.16` directly. That's what the next script solves.

### Step 2: Provision the DNS forwarder VM

```powershell
.\scripts\Add-AzureDNSForwarder.ps1 -ConfirmContext `
    -VNetName 'contoso-prod-vnet' `
    -VNetResourceGroup 'contoso-network-rg' `
    -VPNClientAddressPool '172.16.100.0/24' `
    -SSHPublicKeyPath '~/.ssh/id_ed25519.pub'
```

What this does:

1. Creates a small dedicated subnet (`/28`, auto-derived from the next available range in the VNet) for the forwarder. Specify `-DNSSubnetCIDR '10.0.3.32/28'` if you want to control where it lands.
2. Builds an NSG: port 53 (UDP+TCP) from `VirtualNetwork` + the VPN client pool, SSH from `VirtualNetwork` only. Everything else denied. This NSG is locked tight.
3. Creates a NIC with a **static private IP** (typically `.36` — first usable after Azure's reserved `.0/.1/.2/.3`). The static IP is critical: this is the address that gets pushed to VPN clients via the VNet's DNS settings, and you can't have it changing after a reboot.
4. Provisions a Standard_B1s Ubuntu 24.04 VM. cloud-init installs and configures dnsmasq, disables systemd-resolved's stub listener (the Ubuntu 24.04 default that would conflict on port 53), and enables unattended security upgrades.
5. Updates the VNet's `DhcpOptions.DnsServers` to include the forwarder's IP. This is what causes the next-generated VPN client profile to include the forwarder as the DNS server VPN clients should use.

Cost is ~$11/month for the single-VM setup (VM + disk). Use `-HighAvailability` to get two VMs for ~$22/month total if you need redundancy.

### Step 3: Regenerate the VPN client profile

The previous step updated the VNet's DNS setting, but existing VPN client profiles were generated BEFORE that update and have no idea about the forwarder. Regenerate the profile so new client downloads include the new DNS server:

```powershell
$url = New-AzVpnClientConfiguration -ResourceGroupName 'contoso-network-rg' `
    -Name 'contoso-vpngw' -AuthenticationMethod EAPTLS
Invoke-WebRequest -Uri $url.VpnProfileSASUrl -OutFile 'C:\temp\vpnclient-new.zip'
Expand-Archive 'C:\temp\vpnclient-new.zip' -DestinationPath 'C:\temp\vpnclient-new' -Force
```

Then in the Azure VPN Client app:

1. **Disconnect** from your current VPN profile
2. **Delete** the old profile (hover, click `...`, Remove)
3. **Import** the new `azurevpnconfig.xml` from `C:\temp\vpnclient-new\AzureVPN\`
4. **Connect**

### Step 4: Verify

```powershell
# Confirm Windows picked up the new DNS server via NRPT
Get-DnsClientNrptPolicy | Where-Object { $_.NameServers }
# Should show your forwarder IP (e.g., 10.0.3.36) as NameServers

# Test resolution
Resolve-DnsName erpnext.contoso.com
# Should return your private IP (10.0.2.4)
```

A subtle gotcha: **`nslookup` lies to you here.** `nslookup` bypasses Windows' NRPT (Name Resolution Policy Table) and talks directly to the OS default DNS server, which is still your ISP. It'll show NXDOMAIN even when everything is working correctly. Use `Resolve-DnsName` to test (it uses Windows DNS APIs including NRPT, same as your browser).

If `Resolve-DnsName` returns the private IP, browsers will work. If you specifically want to confirm via `nslookup`, you can explicitly query the forwarder: `nslookup erpnext.contoso.com 10.0.3.36`.

### Troubleshooting the DNS path

**Symptom**: `Resolve-DnsName erpnext.contoso.com` returns NXDOMAIN

Check, in order:

1. Is the VPN connected? `Test-NetConnection 10.0.3.36 -Port 53` should succeed.
2. Did you regenerate and import the NEW VPN profile? `Get-DnsClientNrptPolicy` should show the forwarder IP as NameServers.
3. Does the forwarder itself resolve correctly? SSH to it and run `dig @127.0.0.1 erpnext.contoso.com +short` — should return the private IP.
4. Is the private zone linked to the VNet? `Get-AzPrivateDnsVirtualNetworkLink -ZoneName contoso.com -ResourceGroupName contoso-dns-rg`
5. Does the record exist in the zone? `Get-AzPrivateDnsRecordSet -ZoneName contoso.com -ResourceGroupName contoso-dns-rg -RecordType A`

**Symptom**: `Test-NetConnection 10.0.3.36 -Port 53` times out

The forwarder VM is unreachable. Either:
- VPN isn't connected (check the Azure VPN Client app status)
- NSG is blocking traffic from your VPN client IP (check the NSG rule for port 53; the script's default allows the entire `-VPNClientAddressPool` you specified)
- The VM is stopped (check Azure portal, restart if needed)
- dnsmasq isn't running on the VM (SSH in, `sudo systemctl status dnsmasq`)

**Symptom**: Some VPN clients work, others don't

Profile regeneration matters per client. Each client that had the OLD profile imported won't pick up the new DNS server until they delete the old profile and import the new one.

---

## Common deployment scenarios

### Scenario A: Standalone application VNet

You have one VNet hosting a single application's infrastructure. Add VPN access for admins.

```powershell
.\Setup-AzureP2SVPN.ps1 -ConfirmContext `
    -VNetName 'myapp-prod-vnet' `
    -VNetResourceGroup 'myapp-prod-rg' `
    -Location 'eastus'
```

Result: gateway lives in the same RG as the VNet. Simple.

### Scenario B: Hub-spoke topology

You have a hub VNet for shared services (DNS, AD, VPN) and spoke VNets for applications. The gateway lives in the hub.

```powershell
.\Setup-AzureP2SVPN.ps1 -ConfirmContext `
    -VNetName 'hub-vnet' `
    -VNetResourceGroup 'shared-services-rg' `
    -Location 'eastus' `
    -ResourceGroupName 'vpn-infra-rg'
```

Result: gateway in `vpn-infra-rg`, subnet in the hub VNet's RG (`shared-services-rg`). VPN clients can reach the hub directly; spoke VNet access requires VNet peering with **"Use the remote virtual network's gateway"** enabled on the spoke side.

### Scenario C: Shared VNet for multiple workloads

You have one VNet hosting multiple unrelated workloads (a common pattern for small teams managing a few clients). VPN access goes to the shared VNet.

```powershell
.\Setup-AzureP2SVPN.ps1 -ConfirmContext `
    -VNetName 'shared-prod-vnet' `
    -VNetResourceGroup 'shared-infra-rg' `
    -Location 'eastus'
```

VPN clients can reach **all resources** in the VNet's address space. If you want to restrict access per-workload, use NSGs on each workload's subnet — the VPN gateway itself doesn't do user-level filtering (that's done with Entra ID groups + NSG rules referencing those groups, an advanced topic).

### Scenario D: Cross-region with peering

Production is in West US 2. You want admins to connect via West US 2 and reach resources in both West US 2 and East US 2 via VNet peering.

1. Deploy the gateway in the West US 2 VNet:
   ```powershell
   .\Setup-AzureP2SVPN.ps1 -ConfirmContext `
       -VNetName 'wus2-prod-vnet' `
       -VNetResourceGroup 'wus2-rg' `
       -Location 'westus2'
   ```

2. Set up VNet peering from wus2-prod-vnet to eus2-prod-vnet (and vice versa) via the portal or `Add-AzVirtualNetworkPeering`.

3. On the wus2-prod-vnet → eus2-prod-vnet peering, enable **"Allow gateway transit"**. On the reverse peering, enable **"Use remote virtual network's gateway"**.

VPN clients connect to West US 2 and can now reach both VNets.

---

## Troubleshooting

### Pre-deployment

**"Subnet CIDR is outside the VNet's address space"**

The default GatewaySubnet (`10.0.3.0/27`) doesn't fit inside your VNet. Either:

- Pick a different `-GatewaySubnetPrefix` that fits, or
- Expand the VNet's address space (see [Step 2](#step-2-find-your-vnets-address-space))

**"VPN client address pool overlaps the VNet address prefix"**

The default client pool (`172.16.100.0/24`) overlaps something in your VNet. This is rare — VNets in Azure are usually in `10.0.0.0/8`. Pick a different pool with `-VPNClientAddressPool`, e.g., `172.20.100.0/24`.

**"VNet is in region X but the script is targeting Y"**

You ran the script with a `-Location` that doesn't match the VNet's region. Either re-run with `-Location` set to the VNet's region, or move/recreate the VNet in your target region.

### During gateway provisioning

**Gateway provisioning seems stuck at the same minute**

The poll interval is 60 seconds, so the minute counter only ticks once per minute. Watch the state field — it should progress: `NotStarted` → `Running` → `Completed`. If it sits in `Running` for the whole 30+ minutes, that's normal.

**Job state shows `Blocked`**

A `Blocked` state for more than 2 minutes triggers an explicit abort. This indicates a confirmation prompt inside the background runspace that can't reach the console. The script's `Force` defaults handle this in normal operation; if you hit it anyway, the error message will tell you to re-run synchronously (without `-AsJob`).

**Gateway provisioning fails after 30+ minutes**

Possible causes:

- **Quota:** VPN Gateway is a paid resource and counts against subscription quotas. Check Azure Portal → Subscription → Usage + quotas → Network → Virtual Network Gateway.
- **Region capacity:** Some regions occasionally run short on gateway capacity. Try a different region (and a different VNet in that region) to confirm.
- **Subscription policies:** Azure Policy assignments may block gateway creation. Check Portal → Policy → Assignments.

If none of those apply, the job's error output will name the specific Azure error. Common codes:

- `SubscriptionNotRegistered` — Run `Register-AzResourceProvider -ProviderNamespace Microsoft.Network`
- `InvalidResourceLocation` — Region mismatch (script should catch this in pre-flight, but if it slips through, the gateway region must match the VNet region exactly)

### After deployment

**Azure VPN Client says "The remote network has been disconnected" immediately on connect**

Likely causes:

- **Wrong configuration file imported.** Use `AzureVPN/azurevpnconfig.xml`, not the ones in `Generic/` or `OpenVPN/`.
- **Old client config.** If you regenerated the config bundle after changing settings, you must re-import the new file. The client doesn't auto-refresh.
- **Audience mismatch.** Verify you're using the same audience type the gateway is configured with. If you used `-UseLegacyAudience` for deployment, the older Azure VPN Client (pre-2023) is needed; current versions expect the Microsoft-registered audience.

**Connection succeeds but can't reach VNet IPs**

- **Routing:** When connected, run `route print` (Windows) or `netstat -rn` (macOS/Linux). You should see routes for the VNet's address space pointing to the VPN tunnel. If not, the client config didn't include the right routes.
- **NSG rules:** The destination resource's NSG might block traffic from the VPN client pool. NSG rules using the `VirtualNetwork` service tag should allow VPN clients automatically (the service tag includes the VPN client pool by Azure design). NSG rules with explicit IP source restrictions won't.
- **DNS:** The VPN doesn't push DNS configuration by default. To resolve private DNS zones, set up Azure Private DNS and configure the gateway with custom DNS servers.

**"User not authorized" on sign-in**

- The user must exist in the Entra tenant the gateway is configured against
- If you used `-UseLegacyAudience`, verify tenant admin consent was granted to the legacy app
- Conditional Access policies might be blocking sign-in (check Entra ID → Sign-in logs)

---

## Security considerations

### What this VPN does and doesn't do

**It does:**

- Encrypt all traffic between the VPN client and the gateway (OpenVPN/TLS)
- Authenticate users via Entra ID with whatever Conditional Access policies you have configured
- Provide network-layer access to resources in the VNet's address space

**It doesn't:**

- Filter traffic by user or group (every authenticated user can reach the entire VNet)
- Encrypt traffic past the gateway (gateway → VNet resources is unencrypted, relying on Azure's backbone for isolation)
- Replace per-resource authentication (the resources you're VPNing to still need their own auth — SSH keys, app passwords, etc.)

### Recommended layered security

1. **VPN as the network perimeter** — only people with valid Entra accounts + VPN client config can reach private IPs
2. **NSGs as the second layer** — even VPN-connected users can only reach resources their subnet permits
3. **Resource-level auth as the final layer** — SSH keys, RBAC, API tokens, etc., on each resource
4. **Conditional Access** — require MFA, compliant device, specific locations, etc., on VPN sign-in

### Per-user vs. per-group access control

Out of the box, every Entra user in your tenant can connect (subject to Conditional Access). To restrict to specific groups, configure user-group-to-IP-pool mapping per [Microsoft's user groups documentation](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-user-groups-portal). This advanced configuration isn't automated by this script.

### Audit and logging

VPN connections show up in:

- **Entra ID → Sign-in logs** — every authentication attempt
- **VPN Gateway → Logs** (if you've enabled diagnostic settings to a Log Analytics workspace) — connection events
- **Azure Activity Log** — gateway configuration changes

Enable diagnostic settings on the gateway right after creation if compliance requirements demand audit logs.

---

## Operations and maintenance

### Routine checks

**Monthly:** Verify the gateway is still healthy:

```powershell
Get-AzVirtualNetworkGateway -Name 'YOUR-VPNGW' -ResourceGroupName 'YOUR-RG' |
    Select-Object Name, ProvisioningState, GatewayType, EnableBgp, Sku
```

**Quarterly:** Test the VPN from a fresh machine to verify the client config still works end-to-end.

### When users leave the company

Just disable the user in Entra ID. They're locked out immediately — no certificate revocation, no gateway change needed.

### When you need to change settings

| Change | How |
|---|---|
| Add/remove tunnel protocols | Portal → Gateway → Point-to-site config → Tunnel type |
| Change client address pool | Portal → Gateway → Point-to-site config → Address pool (NOTE: existing clients must re-download config) |
| Switch audience | `Set-AzVirtualNetworkGateway -AadAudienceId <new-id>` |
| Upgrade SKU | Portal → Gateway → Configuration → Gateway SKU (downtime: 30-45 min during resize) |

**Any setting change requires regenerating + re-distributing the client config bundle to users.** Existing connections drop when the gateway updates.

### Backup / disaster recovery

The gateway has no user data — it's infrastructure. If a region outage destroys it, you recreate it (30 minutes), regenerate the client config, and distribute. Plan for that lead time.

For redundancy, consider an active-active gateway pair (requires VpnGw2+ SKU). This script doesn't currently configure active-active — modify `-EnableActiveActiveFeature` and add a second IP config if needed.

---

## Tearing down

When you no longer need the VPN (project ended, switching to a different access pattern, etc.):

```powershell
.\Remove-AzureP2SVPN.ps1 -Force `
    -VNetName 'YOUR-VNET' `
    -VNetResourceGroup 'YOUR-VNET-RG' `
    -RemoveGatewaySubnet
```

Removes (in order):

1. The VPN Gateway (10-15 min)
2. The Gateway's Public IP
3. The GatewaySubnet from your VNet (only if you pass `-RemoveGatewaySubnet`)

**The VNet itself is never touched.** The script leaves it exactly as it was before the VPN was set up, minus the GatewaySubnet if you opted to remove it.

**Cost stops accruing the moment the gateway is deleted.** No partial-month proration weirdness — just stop the meter.

### When NOT to use `-RemoveGatewaySubnet`

- If you're not the owner of the VNet — let the VNet owner decide whether to keep or remove the (now-empty) GatewaySubnet
- If you might add the VPN back later — leaving the subnet in place makes redeployment slightly faster

---

## Frequently asked questions

**Q: Why is this so much slower than Connect-AzAccount?**

Because Azure VPN Gateways are real virtual machines (well, virtual appliances) that Azure has to provision behind the scenes. There's no shortcut — even Microsoft's portal flow takes the same 30 minutes. The script just makes the wait less painful by polling and reporting progress.

**Q: Can I run this multiple times?**

Yes. The script is idempotent. If the gateway, public IP, and subnet already exist, it reuses them. Useful for recovery after a failed run, or for re-applying configuration changes.

**Q: Does this work with Azure Government / China / Germany clouds?**

The Microsoft-registered audience values are different in sovereign clouds. The script currently hardcodes the Azure Public value (`c632b3df-...`). For sovereign clouds, edit `Get-AzureVPNAudienceValue` to use:

- Government: `51bb15d4-3a4f-4ebf-9dca-40096fe32426`
- (China and Germany have their own — see [Microsoft docs](https://learn.microsoft.com/en-us/azure/vpn-gateway/openvpn-azure-ad-tenant))

Pull requests adding cloud detection would be welcome.

**Q: Can users in a different tenant connect?**

Yes, with B2B guest access. Invite the external user as a guest in your tenant. They'll authenticate against your tenant when connecting to the VPN. Their home tenant doesn't need to know anything about the VPN.

**Q: Can I use this for site-to-site (S2S) as well as P2S?**

The gateway type the script creates supports both. The script only configures P2S, but after deployment you can add S2S connections via the portal or `New-AzVirtualNetworkGatewayConnection`. S2S configuration is out of scope for this script because it's highly site-specific (depends on your on-premises VPN device).

**Q: What happens if I delete the GatewaySubnet by mistake while the gateway exists?**

You can't — Azure will refuse, with a message about the subnet being in use. The teardown script does this in the right order: gateway first, then optionally subnet.

**Q: How do I see who's currently connected?**

Portal → VPN Gateway → **Point-to-site sessions**. Shows username, client IP from the pool, allocated bandwidth.

**Q: My corporate network already uses 172.16.x.x. Will the default client pool conflict?**

Yes — when connected to the VPN, your laptop won't know whether `172.16.100.x` means "VPN client pool" or "corporate network." Override with `-VPNClientAddressPool` set to a CIDR your corporate network doesn't use. `192.168.250.0/24` is often safe.

**Q: Can I script the client setup?**

The `azurevpnconfig.xml` import isn't directly scriptable for end users (the Azure VPN Client doesn't expose a CLI). For automated client provisioning, look at deploying the config via Intune or another MDM platform.

---

## See also

- [README.md](README.md) — Quick start and parameter reference
- [CHANGELOG.md](CHANGELOG.md) — Version history
- [Microsoft Learn: P2S with Entra ID](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-entra-gateway)
- [Microsoft Learn: VPN Gateway SKUs](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings)
- [Azure VPN Client downloads](https://learn.microsoft.com/en-us/azure/vpn-gateway/azure-vpn-client-versions)

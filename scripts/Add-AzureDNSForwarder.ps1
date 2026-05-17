<#
.SYNOPSIS
    Provisions a lightweight Ubuntu VM running dnsmasq inside an existing Azure
    VNet to act as a DNS forwarder for VPN-connected clients. Configures the
    VNet's DNS server setting to point to the forwarder so VPN clients pick it
    up automatically after regenerating their profile.

.DESCRIPTION
    Azure's built-in DNS resolver (168.63.129.16) is only reachable from
    resources INSIDE a VNet - VPN clients cannot query it directly even when
    connected through a Point-to-Site VPN. This breaks the typical use case of
    "connect VPN, type erpnext.mycompany.com, hit the private IP via Private
    DNS Zone".

    The fix is to put a small DNS forwarder VM inside the VNet that VPN clients
    CAN reach. The forwarder accepts DNS queries from clients and forwards them
    to 168.63.129.16, which resolves them against linked Private DNS Zones,
    Azure-internal records, and the public internet as appropriate.

    This script:

    1. Creates a dedicated subnet for the DNS forwarder (or uses one you
       specify with -ExistingSubnetName).

    2. Creates a hardened NSG allowing port 53 (UDP+TCP) only from inside the
       VNet and from the VPN client address pool. Denies everything else.

    3. Provisions a small Ubuntu 24.04 VM (B1s by default) with a STATIC private
       IP. The static IP is important: it's the address VPN clients will be
       configured to query, and reboots/redeployments cannot change it.

    4. Installs and configures dnsmasq via cloud-init. The dnsmasq config:
       - Forwards all queries to 168.63.129.16
       - Disables systemd-resolved's port 53 listener (Ubuntu 24.04 default)
       - Listens on all interfaces inside the VNet
       - Logs queries to syslog for troubleshooting

    5. Updates the VNet's DhcpOptions.DnsServers to include the forwarder's
       private IP. This is what propagates to VPN clients via their profile
       configuration. Existing custom DNS servers are PRESERVED (we add to,
       not replace, the list - per Microsoft guidance).

    6. (Optional, with -HighAvailability) Provisions a SECOND VM with a second
       static IP for redundancy. dnsmasq is stateless so active/active works
       perfectly - clients will round-robin between the two.

    7. Prints next-steps for regenerating the VPN client profile so connected
       clients pick up the new DNS server.

    The script is idempotent: re-running on an existing setup updates without
    removing anything you've configured manually.

.PARAMETER VNetName
    Name of the VNet to deploy the forwarder into. VPN clients must already
    be able to reach this VNet.

.PARAMETER VNetResourceGroup
    Resource group containing the VNet.

.PARAMETER ResourceGroupName
    Resource group where the forwarder VM(s) will be created. Defaults to a
    new RG named '<VNet RG>-dns-rg', or uses an existing one if specified.

.PARAMETER NamePrefix
    Prefix for resource names. Default: derived from VNet name. Example:
    if VNet is 'jtcustomtr-vnet' and NamePrefix is 'jtc', resources are named
    'jtc-dns-vm', 'jtc-dns-nsg', etc.

.PARAMETER ExistingSubnetName
    Name of an existing subnet to deploy into instead of creating a new one.
    Useful if you have an established subnet pattern. The subnet must have
    enough free private IPs (2 for HA, 1 otherwise).

.PARAMETER DNSSubnetCIDR
    CIDR for the new dedicated DNS subnet to be created within the VNet's
    address space. Default: derived as the next available /28 inside the VNet.
    Ignored if -ExistingSubnetName is specified.

.PARAMETER Location
    Azure region for the forwarder VM. Defaults to the VNet's location.

.PARAMETER VMSize
    Azure VM size. Default: 'Standard_B1s' (~$8/month). DNS forwarding is
    near-zero load; the smallest VM is plenty. Use larger only if you need to
    layer additional services on the VM.

.PARAMETER AdminUsername
    Username for the VM's admin account. Default: 'azureadmin'.

.PARAMETER SSHPublicKeyPath
    Path to an SSH public key file (e.g., ~/.ssh/id_ed25519.pub). If specified,
    the VM is configured with SSH key authentication only (no password). If
    omitted, a random strong password is generated and printed once at the end.
    SSH key auth is strongly recommended.

.PARAMETER HighAvailability
    Provision TWO forwarder VMs with sequential static IPs for redundancy.
    dnsmasq is stateless so this is true active/active. Default: single VM.

.PARAMETER VPNClientAddressPool
    CIDR of the VPN client address pool (e.g., '172.16.100.0/24'). Used to
    open port 53 in the NSG for VPN-connected clients. If not specified, the
    NSG only allows queries from inside the VNet.

.PARAMETER NoUpdateVNetDNS
    Skip updating the VNet's DnsServers setting. Useful if you want to
    deploy the forwarder first and update VNet settings manually later.

.PARAMETER AllowedSSHSourceCIDR
    Source CIDR allowed to SSH to the forwarder VM. Default: 'VirtualNetwork'
    (i.e., only from inside the VNet or via VPN). Specify a public CIDR if
    you need to SSH directly without going through the VPN.

.PARAMETER ConfirmContext
    Multi-tenant safety bypass: accept the current Azure context without an
    explicit -SubscriptionId.

.PARAMETER TenantId
    Entra tenant ID. Defaults to the current authenticated context.

.PARAMETER SubscriptionId
    Subscription ID. Defaults to the current authenticated context.

.EXAMPLE
    PS> .\Add-AzureDNSForwarder.ps1 -ConfirmContext `
            -VNetName 'jtcustomtr-2e886f0313-vnet' `
            -VNetResourceGroup 'JTC-Prod-WP-WestUS2-rg' `
            -SSHPublicKeyPath '~/.ssh/id_ed25519.pub' `
            -VPNClientAddressPool '172.16.100.0/24'

    Minimal deployment: single forwarder VM in a new dedicated DNS subnet,
    with SSH key auth, NSG opens port 53 to the VPN client pool.

.EXAMPLE
    PS> .\Add-AzureDNSForwarder.ps1 -ConfirmContext `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -SSHPublicKeyPath '~/.ssh/id_ed25519.pub' `
            -VPNClientAddressPool '172.16.100.0/24' `
            -HighAvailability `
            -NamePrefix 'contoso'

    HA deployment: two forwarder VMs for redundancy, prefixed naming.

.EXAMPLE
    PS> .\Add-AzureDNSForwarder.ps1 -ConfirmContext `
            -VNetName 'corp-vnet' `
            -VNetResourceGroup 'corp-net-rg' `
            -ExistingSubnetName 'shared-infra-subnet' `
            -SSHPublicKeyPath '~/.ssh/id_ed25519.pub' `
            -VPNClientAddressPool '172.16.0.0/16' `
            -VMSize 'Standard_B2s'

    Deploys into an existing subnet using a larger VM. Useful if you already
    have an "infrastructure" subnet pattern with NSG rules established.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Created:          05/17/2026
    Version:          1.0.0
    Last Updated:     05/17/2026

    REQUIREMENTS:
    - PowerShell 7.2 or later
    - Az.Network, Az.Compute, Az.Accounts, Az.Resources modules
    - Owner or Contributor role on the target subscription
    - Network Contributor on the VNet's resource group (to update DnsServers)

    COST:
    - VM (B1s): ~$8/month per VM (16/mo for HA)
    - Managed disk (Standard SSD, 30GB): ~$2.40/month per VM
    - Public IP: none (the forwarder is internal-only)
    - Total: ~$10-12/month single, ~$20-24/month HA

    NEXT STEPS AFTER DEPLOYMENT:
    1. Regenerate the VPN client profile so it picks up the new VNet DNS
       servers. From the Azure portal: P2S configuration -> Download VPN
       client. Or via PowerShell:
         $url = New-AzVpnClientConfiguration -ResourceGroupName <RG> \`
                  -Name <gatewayname> -AuthenticationMethod EAPTLS
         Invoke-WebRequest -Uri $url.VpnProfileSASUrl -OutFile vpnclient.zip
    2. Disconnect, delete the old profile in Azure VPN Client, import the new
       azurevpnconfig.xml from the AzureVPN/ folder of the new bundle.
    3. Reconnect. Verify with:
         nslookup erpnext.awesomewildstuff.com
       (Should return your private IP like 10.0.2.4)

    SECURITY NOTES:
    - The NSG locks the forwarder to port 53 from VNet/VPN-pool only by default.
    - SSH is locked to the VNet (or your -AllowedSSHSourceCIDR) - you'll need
      to be VPN-connected to administer it.
    - The VM is patched via unattended-upgrades enabled by cloud-init.
    - No public IP is assigned - the VM is internal-only.

    TROUBLESHOOTING:
    - dnsmasq logs to /var/log/syslog. Grep for 'dnsmasq' to see queries.
    - 'sudo systemctl status dnsmasq' shows service health.
    - 'dig @<forwarder-ip> erpnext.awesomewildstuff.com' from a VNet VM
      tests resolution directly.

.LINK
    https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-name-resolution-for-vms-and-role-instances
    https://thekelleys.org.uk/dnsmasq/doc.html
#>

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Network, Az.Compute, Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'TenantId/SubscriptionId/ConfirmContext are used by Resolve-AzureContext via script-scope reference; PSScriptAnalyzer does not trace script-scope parameter usage from within nested functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Used to convert the dynamically-generated VM admin password (from New-SecurePassword) into a SecureString for the New-AzVM credential object. No hardcoded production secrets.')]
param(
    [Parameter(Mandatory, HelpMessage = 'Name of the VNet to deploy into.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetName,

    [Parameter(Mandatory, HelpMessage = 'Resource group containing the VNet.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetResourceGroup,

    [Parameter(HelpMessage = 'Resource group for the forwarder VM. Defaults to <VNet RG>-dns-rg.')]
    [string]$ResourceGroupName,

    [Parameter(HelpMessage = 'Prefix for resource names. Defaults to derived from VNet name.')]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,16}$')]
    [string]$NamePrefix,

    [Parameter(HelpMessage = 'Name of an existing subnet to use. If not specified, a new dns-subnet is created.')]
    [string]$ExistingSubnetName,

    [Parameter(HelpMessage = 'CIDR for the new dns-subnet (ignored if -ExistingSubnetName is set). Default: auto-derived.')]
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
    [string]$DNSSubnetCIDR,

    [Parameter(HelpMessage = 'Azure region. Defaults to the VNet location.')]
    [string]$Location,

    [Parameter(HelpMessage = 'VM size. Default: Standard_B1s (~$8/month).')]
    [string]$VMSize = 'Standard_B1s',

    [Parameter(HelpMessage = 'Admin username for the VM. Default: azureadmin.')]
    [ValidatePattern('^[a-z][a-z0-9_-]{2,30}$')]
    [string]$AdminUsername = 'azureadmin',

    [Parameter(HelpMessage = 'Path to SSH public key file. If omitted, a random password is generated.')]
    [string]$SSHPublicKeyPath,

    [Parameter(HelpMessage = 'Provision two VMs for HA. Default: single VM.')]
    [switch]$HighAvailability,

    [Parameter(HelpMessage = 'CIDR of the VPN client address pool. Used to open port 53 in the NSG.')]
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
    [string]$VPNClientAddressPool,

    [Parameter(HelpMessage = 'Skip updating the VNet DnsServers setting.')]
    [switch]$NoUpdateVNetDNS,

    [Parameter(HelpMessage = 'Source CIDR for SSH access. Default: VirtualNetwork (only from inside VNet/VPN).')]
    [string]$AllowedSSHSourceCIDR = 'VirtualNetwork',

    [Parameter(HelpMessage = 'Multi-tenant safety bypass: accept current Azure context without -SubscriptionId.')]
    [switch]$ConfirmContext,

    [Parameter(HelpMessage = 'Entra tenant ID. Defaults to current authenticated context.')]
    [string]$TenantId,

    [Parameter(HelpMessage = 'Subscription ID. Defaults to current authenticated context.')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# Azure's built-in DNS resolver - what dnsmasq forwards to.
$AzureDNSResolverIP = '168.63.129.16'

# Logging
$LogTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $PSScriptRoot "Add-AzureDNSForwarder_${LogTimestamp}.log"

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

function Write-LogMessage {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug', 'Skip')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
        'Skip'    { 'DarkYellow' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Resolve-AzureContext {
    <#
    .SYNOPSIS
        Resolves the active Azure context with multi-tenant safety.
        Same pattern as the rest of the toolkit.
    #>
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No active Azure context. Run Connect-AzAccount first.'
    }
    if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
        Write-LogMessage "Switching to tenant $TenantId..." -Level Info
        $context = Set-AzContext -TenantId $TenantId -ErrorAction Stop
    }
    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-LogMessage "Switching to subscription $SubscriptionId..." -Level Info
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    Write-Host ''
    Write-Host 'ACTIVE AZURE CONTEXT' -ForegroundColor Cyan
    Write-Host "  Account:        $($context.Account.Id)"
    Write-Host "  Tenant:         $($context.Tenant.Id)"
    Write-Host "  Subscription:   $($context.Subscription.Name) ($($context.Subscription.Id))"
    Write-Host ''

    if (-not $SubscriptionId) {
        $accessibleSubs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                            Where-Object { $_.State -eq 'Enabled' })
        if ($accessibleSubs.Count -gt 1 -and -not $ConfirmContext) {
            Write-LogMessage "Account has access to $($accessibleSubs.Count) subscriptions but none was pinned." -Level Error
            Write-LogMessage 'Multi-tenant safety: pass one of the following to proceed:' -Level Error
            Write-LogMessage '  -SubscriptionId <id>     (explicit target)' -Level Error
            Write-LogMessage '  -TenantId <id>           (explicit tenant)' -Level Error
            Write-LogMessage '  -ConfirmContext          (accept current context)' -Level Error
            throw 'Context not confirmed. See log for guidance.'
        }
    }

    Write-LogMessage "Resolved context: $($context.Account.Id) / $($context.Subscription.Name)" -Level Success
    return $context
}

function New-SecurePassword {
    <#
    .SYNOPSIS
        Generates a strong random password meeting Azure VM complexity rules.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function that generates a random password string; does not change system state.')]
    param(
        [ValidateRange(12, 128)] [int]$Length = 24
    )

    $lower  = 'abcdefghijkmnopqrstuvwxyz'        # no l
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'         # no I, O
    $digits = '23456789'                          # no 0, 1
    $symbol = '!@#$%^&*+-_=?'

    # Ensure at least one from each class
    $chars = @(
        ($lower.ToCharArray() | Get-Random)
        ($upper.ToCharArray() | Get-Random)
        ($digits.ToCharArray() | Get-Random)
        ($symbol.ToCharArray() | Get-Random)
    )
    # Fill the rest
    $pool = ($lower + $upper + $digits + $symbol).ToCharArray()
    while ($chars.Count -lt $Length) {
        $chars += ($pool | Get-Random)
    }
    # Shuffle
    -join ($chars | Sort-Object { Get-Random })
}

function Get-NextAvailableSubnetCIDR {
    <#
    .SYNOPSIS
        Finds the next available /28 inside the VNet's address space that
        doesn't overlap with any existing subnet.

        Strategy: iterate /28 blocks starting from the FIRST address space
        until we find one that doesn't overlap any existing subnet.
    #>
    param(
        [Parameter(Mandatory)] $VNet
    )

    # We'll search the first VNet address space, /28 blocks.
    $vnetPrefix = $VNet.AddressSpace.AddressPrefixes[0]
    $parts = $vnetPrefix -split '/'
    $base = $parts[0]
    $vnetMask = [int]$parts[1]

    # Convert base to UInt32
    $octets = $base -split '\.'
    $baseInt = ([UInt32]$octets[0] -shl 24) -bor ([UInt32]$octets[1] -shl 16) -bor ([UInt32]$octets[2] -shl 8) -bor [UInt32]$octets[3]

    # /28 = 16 addresses
    $subnetSize = 16
    # Last address in the VNet
    $vnetTotal = [UInt32]([Math]::Pow(2, 32 - $vnetMask))
    $vnetEnd = $baseInt + $vnetTotal - 1

    # Existing subnet ranges
    $existingRanges = @()
    foreach ($s in $VNet.Subnets) {
        foreach ($p in $s.AddressPrefix) {
            $sp = $p -split '/'
            $so = $sp[0] -split '\.'
            $sStart = ([UInt32]$so[0] -shl 24) -bor ([UInt32]$so[1] -shl 16) -bor ([UInt32]$so[2] -shl 8) -bor [UInt32]$so[3]
            $sSize = [UInt32]([Math]::Pow(2, 32 - [int]$sp[1]))
            $existingRanges += [PSCustomObject]@{ Start = $sStart; End = $sStart + $sSize - 1 }
        }
    }

    # Scan /28 blocks
    $current = $baseInt
    while ($current + $subnetSize - 1 -le $vnetEnd) {
        $candidateEnd = $current + $subnetSize - 1
        $overlaps = $false
        foreach ($r in $existingRanges) {
            if ($current -le $r.End -and $candidateEnd -ge $r.Start) {
                $overlaps = $true
                # Skip past this conflicting range
                $current = $r.End + 1
                # Align to /28 boundary
                $remainder = $current % $subnetSize
                if ($remainder -ne 0) {
                    $current += ($subnetSize - $remainder)
                }
                break
            }
        }
        if (-not $overlaps) {
            # Found one
            $a = ($current -shr 24) -band 0xFF
            $b = ($current -shr 16) -band 0xFF
            $c = ($current -shr 8) -band 0xFF
            $d = $current -band 0xFF
            return "$a.$b.$c.$d/28"
        }
    }

    throw "Could not find a free /28 inside VNet address space $vnetPrefix. Specify -DNSSubnetCIDR explicitly or use -ExistingSubnetName."
}

function Get-CloudInitForDnsmasq {
    <#
    .SYNOPSIS
        Generates the cloud-init user-data for the forwarder VM.

        Configures:
        - Disables systemd-resolved's port 53 stub listener (Ubuntu 24.04 default)
        - Installs dnsmasq
        - dnsmasq forwards all queries to 168.63.129.16 (Azure DNS)
        - dnsmasq listens on all interfaces inside the VNet
        - Logs queries to syslog
        - Enables unattended-upgrades for security patches
    #>

    # NOTE: the cloud-init YAML is built as a heredoc string. Indentation matters.
    # The forwarded resolver IP and other values are interpolated from the
    # PowerShell scope BEFORE the script runs on the VM.
    $cloudInit = @"
#cloud-config
package_update: true
package_upgrade: true

packages:
  - dnsmasq
  - unattended-upgrades

write_files:
  # Disable systemd-resolved's port 53 stub listener. On Ubuntu 24.04 it
  # listens on 127.0.0.53:53 by default, which conflicts with dnsmasq.
  - path: /etc/systemd/resolved.conf.d/disable-stub.conf
    content: |
      [Resolve]
      DNSStubListener=no
    permissions: '0644'

  # Replace /etc/resolv.conf to bypass systemd-resolved's symlink.
  # We need a real file pointing at 168.63.129.16 so dnsmasq can use
  # the upstream resolver before being reconfigured to do so itself.
  - path: /etc/resolv.conf
    content: |
      # Managed by Add-AzureDNSForwarder cloud-init
      nameserver $AzureDNSResolverIP
      options edns0
    permissions: '0644'

  # Main dnsmasq configuration. Forwards everything to Azure DNS.
  - path: /etc/dnsmasq.d/azure-forwarder.conf
    content: |
      # Azure Innovators - DNS Forwarder
      # Forwards all queries to Azure DNS (168.63.129.16) which resolves
      # against linked Private DNS Zones, Azure-internal records, and the
      # public internet as appropriate.

      # Listen on all interfaces (we're behind an NSG so this is safe).
      interface=eth0
      bind-interfaces

      # Don't read /etc/resolv.conf for upstream - use only what we specify here.
      # Otherwise dnsmasq would loop back through systemd-resolved.
      no-resolv

      # Send all queries to Azure DNS.
      server=$AzureDNSResolverIP

      # Cache size - small but useful for repeat queries.
      cache-size=1000

      # Log queries to syslog for troubleshooting.
      # Disable in production if log volume is a concern.
      log-queries

      # Don't be authoritative for any local zone.
      # We want all answers to come from upstream.
      no-hosts
      addn-hosts=/dev/null

      # Drop incoming requests with malformed domain names early.
      domain-needed
      bogus-priv
    permissions: '0644'

  # Enable unattended security upgrades.
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";
    permissions: '0644'

runcmd:
  # Apply the systemd-resolved override and restart it
  - systemctl daemon-reload
  - systemctl restart systemd-resolved

  # Make sure dnsmasq starts on boot and is running now
  - systemctl enable dnsmasq
  - systemctl restart dnsmasq

  # Verify dnsmasq is listening on port 53
  - sleep 5
  - ss -tulnp | grep ':53' || echo "WARN: dnsmasq not listening on :53"

  # Quick self-test
  - dig @127.0.0.1 microsoft.com +short || echo "WARN: dnsmasq self-test failed"

final_message: "DNS forwarder ready. dnsmasq listening on port 53, forwarding to $AzureDNSResolverIP."
"@
    return $cloudInit
}

function Get-NextAvailableIPInSubnet {
    <#
    .SYNOPSIS
        Returns the next available IP address in the subnet's CIDR range,
        skipping Azure-reserved addresses and existing NIC allocations.

        Azure reserves the first 4 IPs (.0 network, .1 default gateway,
        .2 and .3 reserved for Azure DNS mapping) and the last (.broadcast).
    #>
    param(
        [Parameter(Mandatory)] [string]$SubnetCIDR,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$VNetName,
        [Parameter(Mandatory)] [string]$SubnetName,
        [int]$Skip = 0
    )

    $parts = $SubnetCIDR -split '/'
    $base = $parts[0]
    $mask = [int]$parts[1]
    $octets = $base -split '\.'
    $baseInt = ([UInt32]$octets[0] -shl 24) -bor ([UInt32]$octets[1] -shl 16) -bor ([UInt32]$octets[2] -shl 8) -bor [UInt32]$octets[3]
    $size = [UInt32]([Math]::Pow(2, 32 - $mask))

    # Azure reserves first 4 and last 1
    $firstUsable = $baseInt + 4
    $lastUsable = $baseInt + $size - 2

    # Build a hashset of taken IPs
    $taken = New-Object System.Collections.Generic.HashSet[UInt32]
    $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        foreach ($ipc in $nic.IpConfigurations) {
            if ($ipc.Subnet.Id -match "/virtualNetworks/$VNetName/subnets/$SubnetName$") {
                $o = $ipc.PrivateIpAddress -split '\.'
                $ipInt = ([UInt32]$o[0] -shl 24) -bor ([UInt32]$o[1] -shl 16) -bor ([UInt32]$o[2] -shl 8) -bor [UInt32]$o[3]
                [void]$taken.Add($ipInt)
            }
        }
    }

    $skipped = 0
    for ($i = $firstUsable; $i -le $lastUsable; $i++) {
        if (-not $taken.Contains($i)) {
            if ($skipped -lt $Skip) {
                $skipped++
                continue
            }
            $a = ($i -shr 24) -band 0xFF
            $b = ($i -shr 16) -band 0xFF
            $c = ($i -shr 8) -band 0xFF
            $d = $i -band 0xFF
            return "$a.$b.$c.$d"
        }
    }

    throw "No available IP in subnet $SubnetCIDR (subnet $SubnetName)."
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

Write-Host '==============================================================='
Write-Host "  Azure DNS Forwarder Provisioning Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host '  Azure Innovators'
Write-Host "  Log: $LogFile"
Write-Host '==============================================================='
Write-Host ''

try {
    # ---- Pre-flight: context ----
    Write-LogMessage 'Running pre-flight checks...' -Level Info
    $context = Resolve-AzureContext

    # ---- Pre-flight: VNet exists ----
    Write-LogMessage "Verifying VNet: $VNetName (RG: $VNetResourceGroup)" -Level Info
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup -ErrorAction SilentlyContinue
    if (-not $vnet) {
        throw "VNet '$VNetName' not found in resource group '$VNetResourceGroup'."
    }
    Write-LogMessage "  VNet found. Location: $($vnet.Location)" -Level Success

    # Default Location to VNet's location
    if (-not $Location) {
        $Location = $vnet.Location
    }

    # Default NamePrefix from VNet name (trim trailing -vnet, take first 12 chars)
    if (-not $NamePrefix) {
        $NamePrefix = ($VNetName -replace '-vnet$', '') -replace '[^a-zA-Z0-9-]', ''
        if ($NamePrefix.Length -gt 12) {
            $NamePrefix = $NamePrefix.Substring(0, 12)
        }
    }

    # Default ResourceGroupName
    if (-not $ResourceGroupName) {
        $ResourceGroupName = "$VNetResourceGroup-dns-rg"
    }

    # Derive resource names from NamePrefix
    $nsgName       = "$NamePrefix-dns-nsg"
    $subnetName    = if ($ExistingSubnetName) { $ExistingSubnetName } else { "$NamePrefix-dns-subnet" }
    $vmCount       = if ($HighAvailability) { 2 } else { 1 }
    $vmNames       = @(1..$vmCount | ForEach-Object { "$NamePrefix-dns-vm$_" })
    $nicNames      = @(1..$vmCount | ForEach-Object { "$NamePrefix-dns-nic$_" })

    # ---- Pre-flight: SSH key (if specified) ----
    $sshKeyContent = $null
    if ($SSHPublicKeyPath) {
        $expandedPath = $SSHPublicKeyPath
        if ($SSHPublicKeyPath.StartsWith('~')) {
            $expandedPath = $SSHPublicKeyPath.Replace('~', $HOME)
        }
        if (-not (Test-Path -LiteralPath $expandedPath)) {
            throw "SSH public key file not found: $expandedPath"
        }
        $sshKeyContent = (Get-Content -LiteralPath $expandedPath -Raw).Trim()
        if (-not $sshKeyContent.StartsWith('ssh-')) {
            throw "File at $expandedPath does not appear to be a valid SSH public key (should start with 'ssh-')."
        }
        Write-LogMessage "  SSH public key loaded ($(($sshKeyContent -split ' ')[0]))." -Level Success
    }

    # ---- Pre-flight: existing subnet check ----
    if ($ExistingSubnetName) {
        $existingSubnet = $vnet.Subnets | Where-Object { $_.Name -eq $ExistingSubnetName }
        if (-not $existingSubnet) {
            throw "Subnet '$ExistingSubnetName' not found in VNet '$VNetName'. Available subnets: $($vnet.Subnets.Name -join ', ')"
        }
        Write-LogMessage "  Using existing subnet: $ExistingSubnetName ($($existingSubnet.AddressPrefix))" -Level Info
        $subnetCIDR = $existingSubnet.AddressPrefix[0]
    } else {
        # Need to figure out the CIDR for the new subnet
        if (-not $DNSSubnetCIDR) {
            $DNSSubnetCIDR = Get-NextAvailableSubnetCIDR -VNet $vnet
            Write-LogMessage "  Auto-derived dns-subnet CIDR: $DNSSubnetCIDR" -Level Info
        }
        $subnetCIDR = $DNSSubnetCIDR
    }

    # ---- Plan output ----
    Write-Host ''
    Write-Host 'DEPLOYMENT PLAN' -ForegroundColor Cyan
    Write-Host "  Account:                $($context.Account.Id)"
    Write-Host "  Subscription:           $($context.Subscription.Name)"
    Write-Host "  Location:               $Location"
    Write-Host "  VNet:                   $VNetName (RG: $VNetResourceGroup)"
    Write-Host "  Forwarder RG:           $ResourceGroupName"
    Write-Host "  Name Prefix:            $NamePrefix"
    Write-Host "  Subnet:                 $subnetName ($subnetCIDR)"
    Write-Host "  NSG:                    $nsgName"
    Write-Host "  VM Count:               $vmCount $(if ($HighAvailability) { '(HA)' } else { '(single)' })"
    Write-Host "  VM Names:               $($vmNames -join ', ')"
    Write-Host "  VM Size:                $VMSize"
    Write-Host "  Admin Username:         $AdminUsername"
    Write-Host "  Auth Method:            $(if ($sshKeyContent) { 'SSH Key' } else { 'Password (auto-generated)' })"
    if ($VPNClientAddressPool) {
        Write-Host "  VPN Client Pool:        $VPNClientAddressPool (port 53 allowed)"
    }
    Write-Host "  Update VNet DNS:        $(-not $NoUpdateVNetDNS)"
    Write-Host ''

    # ---- Step 1: Resource group ----
    Write-LogMessage 'Step 1/7: Resource Group' -Level Info
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($rg) {
        Write-LogMessage "  Resource group '$ResourceGroupName' already exists." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $Location")) {
            New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
                Project = 'DNS-Forwarder'
                ManagedBy = 'Add-AzureDNSForwarder'
                ParentVNet = $VNetName
            } | Out-Null
            Write-LogMessage "  Created resource group." -Level Success
        }
    }

    # ---- Step 2: Subnet ----
    Write-LogMessage 'Step 2/7: Subnet' -Level Info
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    if ($subnet) {
        Write-LogMessage "  Subnet '$subnetName' already exists. Reusing." -Level Info
    } else {
        # Build the new subnet config and add it to the VNet
        if ($PSCmdlet.ShouldProcess($subnetName, "Add subnet $subnetCIDR to VNet $VNetName")) {
            # We need to refresh the VNet, modify, and Set-
            $vnetRefresh = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup
            $vnetRefresh = Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetCIDR `
                -VirtualNetwork $vnetRefresh
            $vnet = $vnetRefresh | Set-AzVirtualNetwork
            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
            Write-LogMessage "  Created subnet $subnetName ($subnetCIDR)." -Level Success
        }
    }

    # ---- Step 3: NSG ----
    Write-LogMessage 'Step 3/7: Network Security Group' -Level Info
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nsg) {
        Write-LogMessage "  NSG '$nsgName' already exists. Reusing." -Level Info
    } else {
        # Build rules
        $rules = @()

        # Allow DNS UDP from inside VNet
        $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-DNS-UDP-VNet' `
            -Protocol Udp -Direction Inbound -Priority 1000 `
            -SourceAddressPrefix 'VirtualNetwork' -SourcePortRange '*' `
            -DestinationAddressPrefix '*' -DestinationPortRange '53' `
            -Access Allow

        # Allow DNS TCP from inside VNet
        $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-DNS-TCP-VNet' `
            -Protocol Tcp -Direction Inbound -Priority 1010 `
            -SourceAddressPrefix 'VirtualNetwork' -SourcePortRange '*' `
            -DestinationAddressPrefix '*' -DestinationPortRange '53' `
            -Access Allow

        # If a VPN client address pool was specified, allow DNS from there too
        if ($VPNClientAddressPool) {
            $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-DNS-UDP-VPN' `
                -Protocol Udp -Direction Inbound -Priority 1020 `
                -SourceAddressPrefix $VPNClientAddressPool -SourcePortRange '*' `
                -DestinationAddressPrefix '*' -DestinationPortRange '53' `
                -Access Allow
            $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-DNS-TCP-VPN' `
                -Protocol Tcp -Direction Inbound -Priority 1030 `
                -SourceAddressPrefix $VPNClientAddressPool -SourcePortRange '*' `
                -DestinationAddressPrefix '*' -DestinationPortRange '53' `
                -Access Allow
        }

        # SSH from configured source
        $rules += New-AzNetworkSecurityRuleConfig -Name 'Allow-SSH' `
            -Protocol Tcp -Direction Inbound -Priority 1100 `
            -SourceAddressPrefix $AllowedSSHSourceCIDR -SourcePortRange '*' `
            -DestinationAddressPrefix '*' -DestinationPortRange '22' `
            -Access Allow

        if ($PSCmdlet.ShouldProcess($nsgName, 'Create NSG with DNS + SSH rules')) {
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location `
                -Name $nsgName -SecurityRules $rules
            Write-LogMessage "  Created NSG with $($rules.Count) rules." -Level Success
        }
    }

    # Associate NSG with subnet (idempotent: only if not already associated)
    if ($subnet.NetworkSecurityGroup -and $subnet.NetworkSecurityGroup.Id -eq $nsg.Id) {
        Write-LogMessage "  NSG already associated with subnet." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess($subnetName, "Associate NSG $nsgName")) {
            $vnetRefresh = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup
            $subnetRefresh = $vnetRefresh.Subnets | Where-Object { $_.Name -eq $subnetName }
            $subnetRefresh.NetworkSecurityGroup = $nsg
            $vnet = $vnetRefresh | Set-AzVirtualNetwork
            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
            Write-LogMessage "  Associated NSG with subnet." -Level Success
        }
    }

    # ---- Step 4: NICs with static IPs ----
    Write-LogMessage 'Step 4/7: Network Interfaces (static IPs)' -Level Info
    $forwarderIPs = @()
    $nics = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        $nicName = $nicNames[$i]
        $existingNic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($existingNic) {
            Write-LogMessage "  NIC $nicName already exists (IP: $($existingNic.IpConfigurations[0].PrivateIpAddress)). Reusing." -Level Info
            $forwarderIPs += $existingNic.IpConfigurations[0].PrivateIpAddress
            $nics += $existingNic
        } else {
            # Pick the next available static IP in the subnet, skipping any taken
            $ipAddr = Get-NextAvailableIPInSubnet -SubnetCIDR $subnetCIDR -ResourceGroup $ResourceGroupName `
                -VNetName $VNetName -SubnetName $subnetName -Skip $i

            if ($PSCmdlet.ShouldProcess($nicName, "Create NIC with static IP $ipAddr")) {
                $ipConfig = New-AzNetworkInterfaceIpConfig -Name 'ipconfig1' `
                    -SubnetId $subnet.Id -PrivateIpAddress $ipAddr -PrivateIpAddressVersion IPv4
                $newNic = New-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Location $Location `
                    -Name $nicName -IpConfiguration $ipConfig
                Write-LogMessage "  Created NIC $nicName with static IP $ipAddr." -Level Success
                $forwarderIPs += $ipAddr
                $nics += $newNic
            }
        }
    }

    # ---- Step 5: VMs ----
    Write-LogMessage 'Step 5/7: Virtual Machines' -Level Info

    # Build cloud-init once - same config for all forwarders
    $cloudInitContent = Get-CloudInitForDnsmasq
    $cloudInitBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudInitContent))

    # Build credentials (only used if SSH key not provided)
    $vmPassword = $null
    if (-not $sshKeyContent) {
        $vmPassword = New-SecurePassword -Length 24
    }

    for ($i = 0; $i -lt $vmCount; $i++) {
        $vmName = $vmNames[$i]
        $nic = $nics[$i]
        $existingVM = Get-AzVM -Name $vmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($existingVM) {
            Write-LogMessage "  VM $vmName already exists. Skipping provisioning." -Level Info
            continue
        }

        if ($PSCmdlet.ShouldProcess($vmName, "Create $VMSize Ubuntu VM")) {
            $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $VMSize

            if ($sshKeyContent) {
                # SSH key auth
                $securePlaceholder = ConvertTo-SecureString -String 'unused-placeholder-pw' -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential($AdminUsername, $securePlaceholder)
                $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmName `
                    -Credential $cred -DisablePasswordAuthentication
                $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $sshKeyContent `
                    -Path "/home/$AdminUsername/.ssh/authorized_keys"
            } else {
                # Password auth
                $securePw = ConvertTo-SecureString -String $vmPassword -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential($AdminUsername, $securePw)
                $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmName -Credential $cred
            }

            # Inject cloud-init as custom data
            $vmConfig.OSProfile.CustomData = $cloudInitBase64

            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'Canonical' `
                -Offer 'ubuntu-24_04-lts' -Skus 'server' -Version 'latest'
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage `
                -StorageAccountType StandardSSD_LRS -DiskSizeInGB 30
            $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

            Write-LogMessage "  Creating VM $vmName (this can take 2-4 minutes)..." -Level Info
            $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig
            Write-LogMessage "  Created VM $vmName." -Level Success
        }
    }

    # ---- Step 6: Update VNet DNS Servers ----
    Write-LogMessage 'Step 6/7: VNet DNS Server Configuration' -Level Info
    if ($NoUpdateVNetDNS) {
        Write-LogMessage "  Skipped (-NoUpdateVNetDNS specified)." -Level Skip
    } else {
        # Refresh the VNet to get current state
        $vnetCurrent = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup

        $currentDnsServers = @()
        if ($vnetCurrent.DhcpOptions -and $vnetCurrent.DhcpOptions.DnsServers) {
            $currentDnsServers = @($vnetCurrent.DhcpOptions.DnsServers)
        }

        # Build the desired DNS server list:
        # - Our forwarder IPs FIRST (so clients try them first)
        # - Then any existing custom DNS servers (preserve operator's intent)
        # - We do NOT add 168.63.129.16 to the VNet list - the forwarders use it
        #   internally but VPN clients can't reach it directly anyway.
        $desiredDnsServers = @($forwarderIPs)
        foreach ($existing in $currentDnsServers) {
            if ($existing -notin $desiredDnsServers -and $existing -ne $AzureDNSResolverIP) {
                $desiredDnsServers += $existing
            }
        }

        # Compare
        $currentSorted = ($currentDnsServers | Sort-Object) -join ','
        $desiredSorted = ($desiredDnsServers | Sort-Object) -join ','

        if ($currentSorted -eq $desiredSorted) {
            Write-LogMessage "  VNet DNS already configured: $($desiredDnsServers -join ', ')" -Level Info
        } else {
            if ($PSCmdlet.ShouldProcess($VNetName, "Update VNet DNS servers to: $($desiredDnsServers -join ', ')")) {
                Write-LogMessage "  Updating VNet DNS: $($currentDnsServers -join ', ') -> $($desiredDnsServers -join ', ')" -Level Info
                $vnetCurrent.DhcpOptions = New-Object Microsoft.Azure.Commands.Network.Models.PSDhcpOptions
                $vnetCurrent.DhcpOptions.DnsServers = $desiredDnsServers
                $vnetCurrent | Set-AzVirtualNetwork | Out-Null
                Write-LogMessage "  Updated VNet DNS servers." -Level Success
            }
        }
    }

    # ---- Step 7: Wait briefly for VMs to boot and dnsmasq to be ready ----
    Write-LogMessage 'Step 7/7: Initialization wait' -Level Info
    Write-LogMessage '  Waiting 60 seconds for VMs to complete cloud-init (dnsmasq install)...' -Level Info
    Start-Sleep -Seconds 60
    Write-LogMessage '  cloud-init may continue running in background; verify with SSH if needed.' -Level Info

    # ---- Summary ----
    Write-Host ''
    Write-Host '==============================================================='
    Write-Host '  DNS FORWARDER DEPLOYMENT COMPLETE' -ForegroundColor Green
    Write-Host '==============================================================='
    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-Host "  Resource Group:     $ResourceGroupName"
    Write-Host "  VM(s):              $($vmNames -join ', ')"
    Write-Host "  Forwarder IP(s):    $($forwarderIPs -join ', ')"
    Write-Host "  Subnet:             $subnetName ($subnetCIDR)"
    if (-not $NoUpdateVNetDNS) {
        Write-Host "  VNet DNS Updated:   Yes"
    }
    Write-Host ''

    if ($vmPassword) {
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host 'IMPORTANT: VM ADMIN PASSWORD' -ForegroundColor Yellow
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host '  Username: ' -NoNewline; Write-Host $AdminUsername -ForegroundColor Cyan
        Write-Host '  Password: ' -NoNewline; Write-Host $vmPassword -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'This password is shown ONCE. Save it now (e.g., to a password manager).' -ForegroundColor Yellow
        Write-Host 'It is also logged to the script log file. Consider deleting the log' -ForegroundColor Yellow
        Write-Host 'after copying the password, or use -SSHPublicKeyPath next time.' -ForegroundColor Yellow
        Write-Host ''
        # Log it too (this is unavoidable if the user wanted password auth)
        Add-Content -Path $LogFile -Value "[CREDENTIALS] VM Admin: $AdminUsername / $vmPassword"
    }

    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '1. WAIT a couple of minutes for cloud-init to finish installing'
    Write-Host '   dnsmasq on the VM(s). You can SSH in and check status:'
    Write-Host "     ssh $AdminUsername@$($forwarderIPs[0])"
    Write-Host '     sudo systemctl status dnsmasq'
    Write-Host '     sudo cat /var/log/cloud-init-output.log'
    Write-Host ''
    Write-Host '2. TEST resolution from a VM inside the VNet:'
    Write-Host "     dig @$($forwarderIPs[0]) microsoft.com +short"
    Write-Host "     dig @$($forwarderIPs[0]) erpnext.awesomewildstuff.com +short"
    Write-Host ''
    Write-Host '3. REGENERATE your VPN client profile so it picks up the new'
    Write-Host '   VNet DNS server setting:'
    Write-Host '     - Azure portal: P2S configuration -> Download VPN client'
    Write-Host '     - Or PowerShell:'
    Write-Host "       `$url = New-AzVpnClientConfiguration -ResourceGroupName 'YOUR-VPNGW-RG' \``"
    Write-Host "                 -Name 'YOUR-VPNGW-NAME' -AuthenticationMethod EAPTLS"
    Write-Host "       Invoke-WebRequest -Uri `$url.VpnProfileSASUrl -OutFile vpnclient.zip"
    Write-Host ''
    Write-Host '4. DISCONNECT, delete the old profile in Azure VPN Client, import'
    Write-Host '   the new azurevpnconfig.xml from the AzureVPN/ folder.'
    Write-Host ''
    Write-Host '5. RECONNECT and verify from your laptop:'
    Write-Host '     nslookup erpnext.awesomewildstuff.com'
    Write-Host "     (Should return your private IP, not a public one)"
    Write-Host ''
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host '==============================================================='

    # Return a structured result object
    [PSCustomObject]@{
        ResourceGroupName  = $ResourceGroupName
        VNetName           = $VNetName
        SubnetName         = $subnetName
        SubnetCIDR         = $subnetCIDR
        NSGName            = $nsgName
        VMNames            = $vmNames
        ForwarderIPs       = $forwarderIPs
        HighAvailability   = $HighAvailability.IsPresent
        VNetDNSUpdated     = (-not $NoUpdateVNetDNS)
        AdminUsername      = $AdminUsername
        AuthMethod         = if ($sshKeyContent) { 'SSHKey' } else { 'Password' }
        LogFile            = $LogFile
        ScriptVersion      = $ScriptVersion
        DeploymentTime     = (Get-Date -Format 'o')
    }

} catch {
    Write-LogMessage "DEPLOYMENT FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    throw
}

<#
.SYNOPSIS
    Provisions an Azure VPN Gateway for Point-to-Site (P2S) access with Entra ID authentication.

.DESCRIPTION
    Creates a VPN Gateway in an existing VNet so authorized users can connect to private
    Azure resources from anywhere. Designed for the Azure Innovators consulting workflow:
    one-time setup per VNet, then reused across all deployments that live in that VNet.

    The script handles:
    - GatewaySubnet creation in the existing VNet (Azure requires this exact name)
    - Public IP for the gateway's internet-facing endpoint
    - VPN Gateway resource (VpnGw1 SKU, the minimum that supports Entra ID auth)
    - Point-to-Site configuration with Entra ID as the authentication source
    - VPN client address pool configuration
    - Output of the URL where you download the VPN client config bundle

    The script does NOT handle:
    - Tenant-wide consent to the Azure VPN enterprise application. That's a one-time
      portal action (one click) that has to happen per tenant before VPN clients can
      authenticate. The script detects whether it's been granted and provides the exact
      URL if not.
    - Installing the Azure VPN Client app on user machines. That's a manual install per
      device (Microsoft Store on Windows; App Store on macOS/iOS; Play Store on Android).

    PROVISIONING TIME WARNING:
    Azure VPN Gateways take 25-35 minutes to provision. This is by far the longest
    operation in the script. The provisioning runs asynchronously - the script polls
    every 60 seconds and reports progress.

.PARAMETER ResourceGroupName
    Resource group where the VPN Gateway and its public IP will be created. The gateway
    is typically deployed alongside the VNet it serves, so this defaults to the VNet's
    RG if not specified explicitly.

.PARAMETER VNetName
    Name of the existing VNet to attach the gateway to. Required - the script will not
    create a VNet.

.PARAMETER VNetResourceGroup
    Resource group containing the VNet. Defaults to the deployment RG if not specified.

.PARAMETER Location
    Azure region. Must match the VNet's region. Default: westus2.

.PARAMETER GatewaySubnetPrefix
    CIDR for the GatewaySubnet that will be created in the VNet. Microsoft requires
    this subnet to be named exactly 'GatewaySubnet'. Default: 10.0.3.0/27.

.PARAMETER VPNClientAddressPool
    CIDR for the address pool assigned to VPN clients when they connect. Must NOT
    overlap any VNet address space. Default: 172.16.100.0/24.

.PARAMETER NamePrefix
    Resource naming prefix. When provided, the script names all VPN resources
    using the pattern "<NamePrefix>-vpngw", "<NamePrefix>-vpngw-pip", etc.
    This matches the convention used by sibling Azure Innovators deployment
    scripts (Deploy-ERPNextToAzure, Remove-ERPNextAzureDeployment).

    Example: -NamePrefix 'JTC-prod-westus2' produces:
      Gateway:    JTC-prod-westus2-vpngw
      Public IP:  JTC-prod-westus2-vpngw-pip
      IP Config:  JTC-prod-westus2-vpngw-ipconfig

    If not specified, names are derived from the VNet name (e.g., a VNet
    called 'contoso-prod-vnet' yields a gateway named 'contoso-prod-vpngw').
    This fallback works well when the script is used standalone against
    a VNet whose naming you don't control.

.PARAMETER GatewayName
    Name of the VPN Gateway resource. Overrides naming derivation entirely.
    Default: derived from -NamePrefix if given, otherwise from VNet name.

.PARAMETER GatewaySku
    SKU of the VPN Gateway. VpnGw1AZ is the minimum that supports Entra ID auth.
    Default: VpnGw1AZ. As of 2026, Azure requires AZ-variant SKUs for new
    gateways.

.PARAMETER TenantId
    Entra tenant ID. Defaults to the current authenticated context's tenant. The VPN
    will authenticate users against this tenant.

.PARAMETER ConfirmContext
    Multi-tenant safety bypass. If your Azure account can see more than one
    subscription and you didn't pin one via -SubscriptionId, the script will
    refuse to run without this flag. Passing -ConfirmContext means "I've
    verified the active context is correct; proceed using it."

    This is NOT an interactive prompt - the script accepts the current
    context silently when this flag is set. Use -SubscriptionId or
    -TenantId for explicit targeting; use -ConfirmContext to acknowledge
    you intentionally want the current default.

.PARAMETER SkipPublicIP
    Skip public IP creation (assume it already exists with the conventional name).
    Used for re-runs or recovery scenarios.

.PARAMETER WhatIf
    Show what the script would do without actually creating resources.

.EXAMPLE
    PS> .\Setup-AzureP2SVPN.ps1 -ConfirmContext `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -Location 'eastus'

    Provisions a VpnGw1 gateway in an existing VNet with Entra ID authentication.
    The gateway joins the named VNet, creates a GatewaySubnet at 10.0.3.0/27 by
    default, and configures the Microsoft-registered Azure VPN Client audience
    (no tenant admin consent required).

.EXAMPLE
    PS> .\Setup-AzureP2SVPN.ps1 -ConfirmContext `
            -VNetName 'shared-hub-vnet' `
            -VNetResourceGroup 'shared-infra-rg' `
            -ResourceGroupName 'vpn-rg' `
            -Location 'westus2' `
            -GatewaySubnetPrefix '10.1.255.0/27' `
            -VPNClientAddressPool '172.16.200.0/24'

    Hub-spoke topology variant: gateway lives in its own dedicated RG (vpn-rg)
    while joining a shared hub VNet in a different RG (shared-infra-rg). Custom
    CIDRs accommodate a different VNet address plan.

.EXAMPLE
    PS> .\Setup-AzureP2SVPN.ps1 `
            -VNetName 'jtcustomtr-2e886f0313-vnet' `
            -VNetResourceGroup 'JTC-Prod-WP-WestUS2-rg' `
            -Location 'westus2' `
            -NamePrefix 'JTC-prod-westus2'

    Uses ERPNext-style naming for VPN resources, regardless of what the
    underlying VNet is named. Produces 'JTC-prod-westus2-vpngw' and related
    resources. Recommended for Azure Innovators engagements where the VPN
    deployment should look consistent with sibling deployments.

.EXAMPLE
    PS> .\Setup-AzureP2SVPN.ps1 -ConfirmContext `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -Location 'eastus' `
            -UseLegacyAudience

    For deployments that need backward compatibility with older Azure VPN Client
    versions (pre-2023). Requires a one-time tenant admin consent to the legacy
    Azure VPN enterprise app; the script will print the consent URL if needed.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Created:          05/16/2026
    Version:          1.0.8
    Last Updated:     05/17/2026

    REQUIREMENTS:
    - PowerShell 7.2 or later
    - Az.Network module 5.0+
    - Az.Accounts module
    - Az.Resources module
    - Owner or Contributor role on the target subscription
    - Application Administrator or Global Administrator role in Entra (one-time, for tenant consent)

    COST: VpnGw1 SKU is ~$140/month USD. The public IP attached to it is ~$4/month.
    Total monthly cost for the VPN: ~$144 USD per VNet that has a gateway.

    PREREQUISITES:
    1. The target VNet must already exist.
    2. The VNet's address space must accommodate the GatewaySubnet (default /27).
    3. Tenant-wide admin consent must be granted to the Azure VPN enterprise application.
       This is a one-time portal action; the script will provide the URL if missing.

.LINK
    https://learn.microsoft.com/en-us/azure/vpn-gateway/openvpn-azure-ad-tenant
    https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-howto-point-to-site-resource-manager-portal
#>

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Network, Az.Resources

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, HelpMessage='Name of the existing VNet to attach the gateway to.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetName,

    [Parameter(HelpMessage='Resource group containing the existing VNet.')]
    [string]$VNetResourceGroup,

    [Parameter(HelpMessage='Resource group where the VPN Gateway and its public IP will be created. Defaults to the VNet RG.')]
    [string]$ResourceGroupName,

    [Parameter(HelpMessage='Azure region. Must match the VNet region. Default: westus2.')]
    [ValidateNotNullOrEmpty()]
    [string]$Location = 'westus2',

    [Parameter(HelpMessage='CIDR for the GatewaySubnet. Microsoft requires this subnet to be named exactly GatewaySubnet. Default: 10.0.3.0/27.')]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$')]
    [string]$GatewaySubnetPrefix = '10.0.3.0/27',

    [Parameter(HelpMessage='CIDR for the address pool assigned to VPN clients. Must not overlap VNet address space. Default: 172.16.100.0/24.')]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$')]
    [string]$VPNClientAddressPool = '172.16.100.0/24',

    [Parameter(HelpMessage='Resource naming prefix. When provided, all VPN resources are named "<NamePrefix>-vpngw", "<NamePrefix>-vpngw-pip", etc. Matches the convention used by sibling Azure Innovators deployment scripts (Deploy-ERPNextToAzure, etc). If not specified, names are derived from the VNet name.')]
    [string]$NamePrefix,

    [Parameter(HelpMessage='Name of the VPN Gateway. Overrides naming derivation entirely. Derived from -NamePrefix or VNet name if not set.')]
    [string]$GatewayName,

    [Parameter(HelpMessage='VPN Gateway SKU. VpnGw1AZ is the minimum that supports Entra ID auth. Non-AZ SKUs (VpnGw1/2/3 without the AZ suffix) are no longer supported for new gateways by Azure as of 2026.')]
    [ValidateSet('VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ', 'VpnGw4AZ', 'VpnGw5AZ', 'VpnGw1', 'VpnGw2', 'VpnGw3')]
    [string]$GatewaySku = 'VpnGw1AZ',

    [Parameter(HelpMessage='Entra tenant ID. Defaults to the current authenticated context.')]
    [string]$TenantId,

    [Parameter(HelpMessage='Subscription ID. Defaults to the current authenticated context.')]
    [string]$SubscriptionId,

    [Parameter(HelpMessage='Use the legacy manually-registered Azure VPN Client app ID instead of the Microsoft-registered one. Requires tenant admin consent to a separate enterprise app. Only use this if you have older Azure VPN Client versions deployed (pre-2023).')]
    [switch]$UseLegacyAudience,

    [Parameter(HelpMessage='Multi-tenant safety bypass: accept the current Azure context without an explicit -SubscriptionId. Required if your account can see multiple subscriptions. The script does not prompt - this is a non-interactive flag.')]
    [switch]$ConfirmContext,

    [Parameter(HelpMessage='Skip public IP creation (assume it already exists).')]
    [switch]$SkipPublicIP,

    [Parameter(HelpMessage='Override the default gateway provisioning timeout (in minutes). Azure VPN Gateways take 25-35 minutes for non-AZ SKUs, 30-60+ minutes for AZ-variant SKUs (which deploy zone-redundantly).')]
    [ValidateRange(15, 120)]
    [int]$ProvisioningTimeoutMinutes = 75
)

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.8'

# Default the deployment RG to the VNet RG if not specified
if (-not $ResourceGroupName) {
    $ResourceGroupName = $VNetResourceGroup
}
if (-not $VNetResourceGroup) {
    throw 'Either -VNetResourceGroup must be specified, or -ResourceGroupName must be specified (and it will be used for both).'
}
if (-not $ResourceGroupName) {
    $ResourceGroupName = $VNetResourceGroup
}

# Resource naming. Precedence:
#   1. Explicit -GatewayName wins (operator knows exactly what they want)
#   2. -NamePrefix produces "<prefix>-vpngw" (matches sibling Azure Innovators scripts)
#   3. Fall back to VNet-derived name (replace -vnet suffix with -vpngw)
if (-not $GatewayName) {
    if ($NamePrefix) {
        $GatewayName = "$NamePrefix-vpngw"
    } elseif ($VNetName -match '-vnet$') {
        $GatewayName = $VNetName -replace '-vnet$', '-vpngw'
    } else {
        $GatewayName = "$VNetName-vpngw"
    }
}

# Derived names follow the established <primary-resource>-<resource-type> pattern.
# This matches the ERPNext deployment script's convention:
#   <vmname>-nic, <vmname>-nsg, <vmname>-pip
# For VPN, the primary resource is the gateway:
#   <gatewayname>-pip, <gatewayname>-ipconfig
$GatewayPublicIPName = "$GatewayName-pip"
$GatewayIPConfigName = "$GatewayName-ipconfig"

# Logging setup
$LogTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $PSScriptRoot "Setup-AzureP2SVPN_${LogTimestamp}.log"

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

function Write-LogMessage {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Resolve-AzureContext {
    <#
    .SYNOPSIS
        Resolves the active Azure context. Provides multi-tenant safety:
        if the account can see multiple subscriptions and the caller didn't
        pin one explicitly, refuses to proceed unless -ConfirmContext is set.

    .DESCRIPTION
        Same pattern as the ERPNext deployment script. -ConfirmContext is a
        SAFETY BYPASS, not a prompt trigger - it means "I've checked the
        active context and I accept it."

        Decision tree:
        - If -SubscriptionId is explicit: switch to it, no further check
        - If -TenantId is explicit: switch tenants first
        - If account has only one accessible subscription: proceed silently
        - If account has multiple subscriptions and -ConfirmContext is set: proceed silently
        - If account has multiple subscriptions and -ConfirmContext is NOT set: refuse and explain
    #>
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No active Azure context. Run Connect-AzAccount first.'
    }

    # Apply explicit tenant/subscription if given
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

    # Multi-tenant safety: if more than one subscription is accessible and the
    # caller didn't explicitly pin one, require -ConfirmContext to proceed.
    # This prevents accidentally deploying into the wrong client's tenant.
    if (-not $SubscriptionId) {
        # WarningAction SilentlyContinue: Get-AzSubscription emits warnings when it
        # encounters tenants requiring fresh MFA. Those warnings are not failures
        # and they pollute the output. Subscriptions we CAN see still come back.
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

function Get-AzureVPNAudienceValue {
    <#
    .SYNOPSIS
        Returns the appropriate Audience value (Entra app ID) for the VPN configuration.

    .DESCRIPTION
        Two options exist:

        1. The Microsoft-registered Azure VPN Client app ID (RECOMMENDED, 2023+):
           c632b3df-fb67-4d84-bdcf-b95ad541b5c8
           - No tenant consent step required (Microsoft pre-registered globally)
           - Supports all current Azure VPN Client versions including Linux
           - This is the default in v1.0+ of this script

        2. The legacy manually-registered Azure VPN app ID:
           41b23e61-6c1e-4545-b367-cd054e0ed4b4
           - Requires a one-time tenant admin consent action via portal URL
           - Original pre-2023 mechanism
           - Use only for backward compatibility with older Azure VPN Client versions

        Pass -UseLegacyAudience to get option 2; default is option 1.
    #>
    param([Parameter(Mandatory)] [bool]$Legacy)

    if ($Legacy) {
        return @{
            AppId    = '41b23e61-6c1e-4545-b367-cd054e0ed4b4'
            Label    = 'Legacy (manually-registered) Azure VPN Client app'
            NeedsConsent = $true
        }
    } else {
        return @{
            AppId    = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
            Label    = 'Microsoft-registered Azure VPN Client app (recommended)'
            NeedsConsent = $false
        }
    }
}

function Test-LegacyAzureVPNConsent {
    <#
    .SYNOPSIS
        Only relevant for the legacy audience: checks whether tenant consent has been
        granted to the legacy Azure VPN enterprise app (app ID 41b23e61-...).

        If using the Microsoft-registered app (default), this function does not need to
        be called - that app is pre-registered globally and requires no consent action.
    #>
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$LegacyAppId
    )

    try {
        $token = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop
        $headers = @{
            Authorization = "Bearer $($token.Token)"
            'Content-Type' = 'application/json'
        }
        $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$LegacyAppId'"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop

        if ($response.value.Count -gt 0) {
            Write-LogMessage 'Legacy Azure VPN enterprise app is consented in this tenant.' -Level Success
            return $true
        }

        $consentUrl = "https://login.microsoftonline.com/$($Context.Tenant.Id)/oauth2/authorize?client_id=$LegacyAppId&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent"
        Write-LogMessage 'Legacy Azure VPN enterprise app is NOT yet consented in this tenant.' -Level Warning
        Write-LogMessage 'A tenant admin must visit this URL once and click Accept BEFORE VPN clients can authenticate:' -Level Warning
        Write-Host ''
        Write-Host '  Consent URL:' -ForegroundColor Yellow
        Write-Host "    $consentUrl" -ForegroundColor White
        Write-Host ''
        Write-LogMessage 'The script will continue (gateway can be provisioned without consent), but clients will fail to authenticate until consent is granted.' -Level Warning
        Write-LogMessage 'TIP: Skip the consent step entirely by re-running this script WITHOUT -UseLegacyAudience (uses Microsoft-registered app which needs no consent).' -Level Info
        return $false

    } catch {
        Write-LogMessage "Could not check consent status: $($_.Exception.Message)" -Level Warning
        Write-LogMessage 'TIP: Avoid this check entirely by re-running this script WITHOUT -UseLegacyAudience.' -Level Info
        return $null
    }
}

function Test-CIDRInVNet {
    <#
    .SYNOPSIS
        Returns $true if a CIDR is contained inside any of a VNet's address prefixes.

    .DESCRIPTION
        Used to verify that the GatewaySubnet prefix actually fits in the VNet's
        address space before attempting subnet creation. Uses arithmetic instead
        of bitwise operators to avoid PowerShell signed-int pitfalls.
    #>
    param(
        [Parameter(Mandatory)] [string]$CIDR,
        [Parameter(Mandatory)] [string[]]$VNetPrefixes
    )

    function Convert-CIDRToRange($cidrStr) {
        $parts = $cidrStr -split '/'
        $ipBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $b0 = [uint64]$ipBytes[0]
        $b1 = [uint64]$ipBytes[1]
        $b2 = [uint64]$ipBytes[2]
        $b3 = [uint64]$ipBytes[3]
        $ipInt = ($b3 * 16777216) + ($b2 * 65536) + ($b1 * 256) + $b0
        $prefix = [int]$parts[1]
        $hostBits = 32 - $prefix
        $blockSize = [uint64][math]::Pow(2, $hostBits)
        $maxAddr = [uint64]4294967295
        $mask = if ($prefix -eq 0) { [uint64]0 } else { $maxAddr - ($blockSize - 1) }
        $start = $ipInt -band $mask
        $end = $start + $blockSize - 1
        return @($start, $end)
    }

    $r1 = Convert-CIDRToRange $CIDR
    foreach ($vp in $VNetPrefixes) {
        $r2 = Convert-CIDRToRange $vp
        # CIDR is fully contained if its start >= prefix start AND its end <= prefix end
        if (($r1[0] -ge $r2[0]) -and ($r1[1] -le $r2[1])) {
            return $true
        }
    }
    return $false
}

function Test-CIDROverlap {
    <#
    .SYNOPSIS
        Returns $true if two CIDR blocks overlap (used to check that the VPN
        client pool doesn't conflict with VNet address space).
    #>
    param([Parameter(Mandatory)] [string]$CIDR1, [Parameter(Mandatory)] [string]$CIDR2)

    function ConvertTo-Range($cidrStr) {
        $parts = $cidrStr -split '/'
        $ipBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $b0 = [uint64]$ipBytes[0]
        $b1 = [uint64]$ipBytes[1]
        $b2 = [uint64]$ipBytes[2]
        $b3 = [uint64]$ipBytes[3]
        $ipInt = ($b3 * 16777216) + ($b2 * 65536) + ($b1 * 256) + $b0
        $prefix = [int]$parts[1]
        $hostBits = 32 - $prefix
        $blockSize = [uint64][math]::Pow(2, $hostBits)
        $maxAddr = [uint64]4294967295
        $mask = if ($prefix -eq 0) { [uint64]0 } else { $maxAddr - ($blockSize - 1) }
        $start = $ipInt -band $mask
        $end = $start + $blockSize - 1
        return @($start, $end)
    }
    $r1 = ConvertTo-Range $CIDR1
    $r2 = ConvertTo-Range $CIDR2
    return ($r1[0] -le $r2[1]) -and ($r2[0] -le $r1[1])
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

Write-Host '==============================================================='
Write-Host "  Azure P2S VPN Setup Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host '  Azure Innovators'
Write-Host "  Log: $LogFile"
Write-Host '==============================================================='
Write-Host ''

try {
    # ---- Pre-flight: Azure context ----
    Write-LogMessage 'Running pre-flight checks...' -Level Info
    $context = Resolve-AzureContext

    # ---- Pre-flight: target VNet exists ----
    Write-LogMessage "Verifying target VNet: $VNetName (RG: $VNetResourceGroup)" -Level Info
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup -ErrorAction SilentlyContinue
    if (-not $vnet) {
        throw "VNet '$VNetName' not found in resource group '$VNetResourceGroup'."
    }
    Write-LogMessage "  VNet found. Address space: $($vnet.AddressSpace.AddressPrefixes -join ', ')" -Level Success

    # ---- Pre-flight: VNet region matches ----
    if ($vnet.Location -ne $Location) {
        throw "VNet '$VNetName' is in region '$($vnet.Location)' but the script is targeting '$Location'. Re-run with -Location '$($vnet.Location)'."
    }

    # ---- Pre-flight: GatewaySubnet prefix fits in VNet ----
    $vnetPrefixes = @($vnet.AddressSpace.AddressPrefixes)
    if (-not (Test-CIDRInVNet -CIDR $GatewaySubnetPrefix -VNetPrefixes $vnetPrefixes)) {
        $vnetSpaceList = $vnetPrefixes -join ', '
        throw @"
Requested GatewaySubnet CIDR $GatewaySubnetPrefix does not fit inside the VNet's address space ($vnetSpaceList).
Either pass -GatewaySubnetPrefix with a CIDR inside that range, or expand the VNet's address space first:

  `$vnet = Get-AzVirtualNetwork -Name '$VNetName' -ResourceGroupName '$VNetResourceGroup'
  `$vnet.AddressSpace.AddressPrefixes.Add('10.0.3.0/24')
  `$vnet | Set-AzVirtualNetwork

Then re-run this script.
"@
    }

    # ---- Pre-flight: VPN client pool doesn't overlap VNet ----
    foreach ($vp in $vnetPrefixes) {
        if (Test-CIDROverlap -CIDR1 $VPNClientAddressPool -CIDR2 $vp) {
            throw "VPN client address pool $VPNClientAddressPool overlaps the VNet address prefix $vp. Pick a different -VPNClientAddressPool (e.g., 172.16.100.0/24 or 192.168.200.0/24)."
        }
    }
    Write-LogMessage "  VPN client pool $VPNClientAddressPool does not overlap VNet space." -Level Success

    # ---- Pre-flight: SKU is AZ-capable (Azure no longer accepts non-AZ SKUs) ----
    # As of 2026, Azure rejects new gateway creation with non-AZ SKUs (VpnGw1/2/3)
    # with ErrorCode NonAzSkusNotAllowedForVPNGateway. Only VpnGw1AZ/2AZ/etc. work.
    # We keep non-AZ values in the ValidateSet to allow operations against
    # pre-existing non-AZ gateways, but block creation up front.
    $existingGwForSkuCheck = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $existingGwForSkuCheck -and $GatewaySku -notmatch 'AZ$') {
        throw "GatewaySku '$GatewaySku' is a non-AZ SKU. Azure no longer accepts new gateway creation with non-AZ SKUs; only VpnGw*AZ variants are allowed. Re-run with '-GatewaySku VpnGw1AZ' (same price as VpnGw1, with higher SLA from availability-zone redundancy). See: https://learn.microsoft.com/en-us/azure/vpn-gateway/gateway-sku-consolidation"
    }

    # ---- Pre-flight: Audience selection and consent check (if legacy) ----
    $audienceInfo = Get-AzureVPNAudienceValue -Legacy:$UseLegacyAudience.IsPresent
    Write-LogMessage "Audience: $($audienceInfo.Label) (app ID: $($audienceInfo.AppId))" -Level Info

    $consentStatus = $null
    if ($audienceInfo.NeedsConsent) {
        Write-LogMessage 'Checking legacy Azure VPN enterprise app consent in this tenant...' -Level Info
        $consentStatus = Test-LegacyAzureVPNConsent -Context $context -LegacyAppId $audienceInfo.AppId
    } else {
        Write-LogMessage 'No tenant consent action required - the Microsoft-registered Azure VPN app is pre-registered globally.' -Level Success
    }

    # ---- Plan output ----
    Write-Host ''
    Write-Host 'SETUP PLAN' -ForegroundColor Cyan
    Write-Host "  Account:                $($context.Account.Id)"
    Write-Host "  Tenant:                 $($context.Tenant.Id)"
    Write-Host "  Subscription:           $($context.Subscription.Name)"
    Write-Host "  Location:               $Location"
    Write-Host "  VNet:                   $VNetName (RG: $VNetResourceGroup)"
    Write-Host "  Deployment RG:          $ResourceGroupName"
    Write-Host "  GatewaySubnet:          $GatewaySubnetPrefix"
    Write-Host "  Gateway Name:           $GatewayName"
    Write-Host "  Gateway SKU:            $GatewaySku"
    Write-Host "  Gateway Public IP:      $GatewayPublicIPName"
    Write-Host "  VPN Client Pool:        $VPNClientAddressPool"
    Write-Host "  Authentication:         Entra ID (tenant $($context.Tenant.Id))"
    Write-Host "  Audience Type:          $($audienceInfo.Label)"
    Write-Host "  Provisioning Timeout:   $ProvisioningTimeoutMinutes minutes"
    if ($audienceInfo.NeedsConsent) {
        if ($consentStatus -eq $false) {
            Write-Host "  Enterprise app consent: NOT GRANTED (action required - see above)" -ForegroundColor Yellow
        } elseif ($consentStatus -eq $true) {
            Write-Host "  Enterprise app consent: Granted" -ForegroundColor Green
        } else {
            Write-Host "  Enterprise app consent: Unknown" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Enterprise app consent: Not required (Microsoft-registered app)" -ForegroundColor Green
    }
    Write-Host ''

    # ---- Ensure deployment RG exists ----
    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    $deployRG = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $deployRG) {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
            New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
                Project = 'VPN'
                ManagedBy = 'Setup-AzureP2SVPN'
            } | Out-Null
            Write-LogMessage '  Created.' -Level Success
        }
    } else {
        Write-LogMessage '  Already exists.' -Level Info
    }

    # ---- Step 1: GatewaySubnet ----
    # Azure requires the subnet for a VPN gateway to be named EXACTLY 'GatewaySubnet'.
    # No NSG should be attached to it (Azure docs say NSGs on GatewaySubnet are
    # unsupported and cause unexpected behavior).
    Write-LogMessage 'Step 1/4: GatewaySubnet' -Level Info
    $existingGwSubnet = $vnet.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' }
    if ($existingGwSubnet) {
        Write-LogMessage "  GatewaySubnet already exists at $($existingGwSubnet.AddressPrefix). Reusing." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess("GatewaySubnet in $VNetName", "Create at $GatewaySubnetPrefix")) {
            Add-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet `
                -AddressPrefix $GatewaySubnetPrefix | Out-Null
            $vnet | Set-AzVirtualNetwork | Out-Null
            $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup
            Write-LogMessage "  Created GatewaySubnet at $GatewaySubnetPrefix." -Level Success
        }
    }
    $gatewaySubnet = $vnet.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' }

    # ---- Step 2: Public IP for the gateway ----
    Write-LogMessage 'Step 2/4: Public IP for the gateway' -Level Info

    # For AZ-variant gateways, the Public IP must also be zone-redundant.
    # Azure rejects gateway creation with ErrorCode
    # VmssVpnGatewayPublicIpsMustHaveZonesConfigured if a regional (non-zonal)
    # public IP is attached to an AZ gateway. Zones are set at creation time
    # and immutable, so an existing non-zonal PIP must be recreated.
    $needsZonalPip = $GatewaySku -match 'AZ$'
    $desiredZones  = if ($needsZonalPip) { @('1', '2', '3') } else { @() }

    if ($SkipPublicIP) {
        $gatewayPip = Get-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        Write-LogMessage "  Reusing existing Public IP: $($gatewayPip.IpAddress)" -Level Info
    } else {
        $gatewayPip = Get-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

        # If a PIP exists, check whether its zone configuration matches what
        # the gateway SKU requires. If not, we have to recreate it.
        if ($gatewayPip) {
            $existingZones = @($gatewayPip.Zones)
            $zonesAreCorrect = if ($needsZonalPip) {
                # AZ gateway needs zone-redundant PIP (zones 1, 2, 3)
                ($existingZones.Count -eq 3 -and ($existingZones | Sort-Object) -join ',' -eq '1,2,3')
            } else {
                # Non-AZ gateway uses regional PIP (no zones)
                $existingZones.Count -eq 0
            }

            if (-not $zonesAreCorrect) {
                $existingDesc = if ($existingZones.Count -eq 0) { 'regional (no zones)' } else { "zones $($existingZones -join ',')" }
                $desiredDesc  = if ($needsZonalPip) { 'zone-redundant (zones 1,2,3)' } else { 'regional (no zones)' }
                Write-LogMessage "  Existing Public IP has $existingDesc but gateway SKU $GatewaySku requires $desiredDesc." -Level Warning
                Write-LogMessage '  Zone configuration is immutable; recreating the Public IP...' -Level Warning

                # Safety check: don't delete a PIP that's currently attached to something.
                if ($gatewayPip.IpConfiguration) {
                    throw "Public IP '$GatewayPublicIPName' is currently attached to resource '$($gatewayPip.IpConfiguration.Id)' and cannot be recreated automatically. Detach or delete that resource first."
                }

                if ($PSCmdlet.ShouldProcess($GatewayPublicIPName, 'Delete and recreate Public IP for zone compatibility')) {
                    Remove-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName -Force -Confirm:$false
                    Write-LogMessage '  Old Public IP removed.' -Level Info
                    $gatewayPip = $null
                }
            } else {
                Write-LogMessage "  Public IP already exists with correct zone config: $($gatewayPip.IpAddress)" -Level Info
            }
        }

        # Create the PIP if it doesn't exist (either never existed, or we just removed it).
        if (-not $gatewayPip) {
            if ($PSCmdlet.ShouldProcess($GatewayPublicIPName, 'Create Public IP for VPN Gateway')) {
                # Standard SKU + Static allocation. Zone-redundant for AZ gateway SKUs.
                $pipParams = @{
                    Name              = $GatewayPublicIPName
                    ResourceGroupName = $ResourceGroupName
                    Location          = $Location
                    AllocationMethod  = 'Static'
                    Sku               = 'Standard'
                }
                if ($needsZonalPip) {
                    $pipParams['Zone'] = $desiredZones
                    Write-LogMessage "  Creating zone-redundant Public IP (zones: $($desiredZones -join ','))..." -Level Info
                } else {
                    Write-LogMessage '  Creating regional Public IP (no zones)...' -Level Info
                }
                $gatewayPip = New-AzPublicIpAddress @pipParams
                Write-LogMessage "  Created Public IP: $($gatewayPip.IpAddress)" -Level Success
            }
        }
    }

    # ---- Step 3: VPN Gateway (the slow part) ----
    # Compose Phase 2 (AAD) settings up front. These are reused whether we create
    # the gateway here or reuse an existing one.
    $aadTenantUri = "https://login.microsoftonline.com/$($context.Tenant.Id)"
    $aadIssuerUri = "https://sts.windows.net/$($context.Tenant.Id)/"
    $aadAudience  = $audienceInfo.AppId

    Write-LogMessage 'Step 3/4: VPN Gateway provisioning' -Level Info
    $existingGw = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingGw) {
        Write-LogMessage "  Gateway '$GatewayName' already exists (ProvisioningState: $($existingGw.ProvisioningState))." -Level Info
        # If the existing gateway is still being provisioned, wait for it to finish.
        # This happens when an earlier run timed out but Azure kept working.
        if ($existingGw.ProvisioningState -in @('Updating', 'Creating')) {
            Write-LogMessage "  Gateway is still being provisioned by an earlier run. Waiting for it to reach Succeeded..." -Level Warning
            $waitStart = Get-Date
            $waitDeadline = $waitStart.AddMinutes($ProvisioningTimeoutMinutes)
            while ($existingGw.ProvisioningState -in @('Updating', 'Creating')) {
                if ((Get-Date) -gt $waitDeadline) {
                    throw "Timed out waiting for existing gateway to finish provisioning (state still: $($existingGw.ProvisioningState))."
                }
                $waitMin = [int]((Get-Date) - $waitStart).TotalMinutes
                Write-LogMessage "  Waiting for existing gateway... ($waitMin min, state: $($existingGw.ProvisioningState))" -Level Debug
                Start-Sleep -Seconds 60
                $existingGw = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName
            }
            Write-LogMessage "  Existing gateway provisioning completed (state: $($existingGw.ProvisioningState))." -Level Success
        }
        $gateway = $existingGw
    } else {
        Write-LogMessage '  Provisioning the gateway. AZ SKUs take 30-60 minutes; non-AZ take 25-35.' -Level Warning
        Write-LogMessage "  Timeout configured: $ProvisioningTimeoutMinutes minutes." -Level Info

        if ($PSCmdlet.ShouldProcess($GatewayName, "Create VPN Gateway (SKU: $GatewaySku)")) {
            # Build the gateway IP configuration object
            $gwIpConfig = New-AzVirtualNetworkGatewayIpConfig `
                -Name $GatewayIPConfigName `
                -Subnet $gatewaySubnet `
                -PublicIpAddress $gatewayPip

            $startTime = Get-Date
            Write-LogMessage "  Gateway provisioning started at $($startTime.ToString('HH:mm:ss'))" -Level Info

            # Two-phase creation because newer Az.Network versions removed the
            # VpnClientAad* parameters from New-AzVirtualNetworkGateway. The flow is now:
            #   Phase 1: Create the gateway with basic settings (no AAD)
            #   Phase 2: Apply AAD configuration via Set-AzVirtualNetworkGateway
            # Both phases use -AsJob so we can poll for progress.
            #
            # PHASE 1: Create the gateway (the long step, 30-60 minutes for AZ SKUs)
            Write-LogMessage '  Phase 1/2: Provisioning gateway (basic settings)...' -Level Info
            $gwJob = New-AzVirtualNetworkGateway `
                -Name $GatewayName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -IpConfigurations $gwIpConfig `
                -GatewayType Vpn `
                -VpnType RouteBased `
                -GatewaySku $GatewaySku `
                -VpnClientProtocol @('OpenVPN') `
                -VpnClientAddressPool $VPNClientAddressPool `
                -AsJob

            $deadline = $startTime.AddMinutes($ProvisioningTimeoutMinutes)
            $terminalStates = @('Completed', 'Failed', 'Stopped')

            while ($gwJob.State -notin $terminalStates) {
                if ((Get-Date) -gt $deadline) {
                    Write-LogMessage "Gateway provisioning exceeded $ProvisioningTimeoutMinutes minute timeout." -Level Warning
                    Write-LogMessage "The gateway may STILL be provisioning in Azure. Check the portal or re-run the script - it will resume from where it left off." -Level Warning
                    Stop-Job $gwJob -ErrorAction SilentlyContinue
                    Remove-Job $gwJob -Force -ErrorAction SilentlyContinue
                    throw "Timeout creating VPN Gateway after $ProvisioningTimeoutMinutes minutes. Re-run the script in 5-10 minutes; it will detect the now-completed gateway and continue with Phase 2 (AAD configuration)."
                }
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                Write-LogMessage "  Gateway provisioning... ($elapsed min elapsed, state: $($gwJob.State))" -Level Debug
                Start-Sleep -Seconds 60
            }

            if ($gwJob.State -eq 'Failed') {
                $jobErrors = Receive-Job $gwJob -ErrorAction Continue 2>&1
                Remove-Job $gwJob -Force
                Write-LogMessage 'Gateway provisioning failed:' -Level Error
                foreach ($e in $jobErrors) { Write-LogMessage "  $e" -Level Error }
                throw 'VPN Gateway creation failed.'
            }

            $gateway = Receive-Job $gwJob
            Remove-Job $gwJob -Force
            $phase1Min = [int]((Get-Date) - $startTime).TotalMinutes
            Write-LogMessage "  Phase 1 complete in $phase1Min minutes." -Level Success
        }
    }

    # PHASE 2: Apply AAD configuration. Runs whether the gateway was just created
    # or already existed (idempotent — Set-AzVirtualNetworkGateway with the same
    # values is a no-op if AAD is already configured to match).
    $gateway = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName

    # Safely determine whether AAD is already configured. We can't just access
    # $gateway.VpnClientConfiguration.AadTenantUri because Set-StrictMode throws
    # on missing properties (a brand-new gateway has no VpnClientConfiguration
    # object at all, let alone its AAD sub-properties).
    $aadAlreadyConfigured = $false
    if ($null -ne $gateway.VpnClientConfiguration) {
        $vpc = $gateway.VpnClientConfiguration
        # Use PSObject.Properties to test for property existence under strict mode.
        $hasTenantUri  = $vpc.PSObject.Properties.Name -contains 'AadTenantUri'
        $hasAudienceId = $vpc.PSObject.Properties.Name -contains 'AadAudienceId'
        $hasIssuerUri  = $vpc.PSObject.Properties.Name -contains 'AadIssuerUri'
        if ($hasTenantUri -and $hasAudienceId -and $hasIssuerUri) {
            $aadAlreadyConfigured = ($null -ne $vpc.AadTenantUri) -and
                                    ($vpc.AadAudienceId -eq $aadAudience) -and
                                    ($vpc.AadTenantUri  -eq $aadTenantUri) -and
                                    ($vpc.AadIssuerUri  -eq $aadIssuerUri)
        }
    }

    if ($aadAlreadyConfigured) {
        Write-LogMessage '  Phase 2/2: Entra ID authentication already configured. Skipping.' -Level Info
    } else {
        Write-LogMessage '  Phase 2/2: Applying Entra ID authentication configuration...' -Level Info
        $phase2Start = Get-Date
        $gateway = Set-AzVirtualNetworkGateway `
            -VirtualNetworkGateway $gateway `
            -AadTenantUri $aadTenantUri `
            -AadAudienceId $aadAudience `
            -AadIssuerUri $aadIssuerUri
        $phase2Min = [math]::Round(((Get-Date) - $phase2Start).TotalMinutes, 1)
        Write-LogMessage "  Phase 2 complete in $phase2Min minutes." -Level Success
    }

    # ---- Step 4: Verify and produce client config download URL ----
    Write-LogMessage 'Step 4/4: Verifying gateway and producing client config' -Level Info

    # Re-fetch the gateway to get its current state
    $gateway = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName
    Write-LogMessage "  Gateway provisioning state: $($gateway.ProvisioningState)" -Level Info

    # Get the gateway's public IP for documentation
    $gatewayPip = Get-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName
    Write-LogMessage "  Gateway Public IP: $($gatewayPip.IpAddress)" -Level Info

    # Generate VPN client config download URL
    # Azure CLI / portal exposes this; via PS we use Get-AzVpnClientConfiguration
    # which returns a URL to a ZIP containing the OS-specific config files.
    try {
        Write-LogMessage '  Generating VPN client configuration package...' -Level Info
        $clientPackage = New-AzVpnClientConfiguration `
            -ResourceGroupName $ResourceGroupName `
            -Name $GatewayName `
            -AuthenticationMethod EAPTLS
        Write-LogMessage '  VPN client package generated. Download from the URL in the next section.' -Level Success
    } catch {
        Write-LogMessage "  Could not generate client config (this is non-fatal): $($_.Exception.Message)" -Level Warning
        Write-LogMessage '  You can generate the package later from the Azure portal: VPN Gateway -> Point-to-site configuration -> Download VPN client.' -Level Warning
        $clientPackage = $null
    }

    # ---- Summary ----
    Write-Host ''
    Write-Host '==============================================================='
    Write-Host '  VPN GATEWAY SETUP COMPLETE' -ForegroundColor Green
    Write-Host '==============================================================='
    Write-Host ''
    Write-Host 'Gateway Details:' -ForegroundColor Cyan
    Write-Host "  Name:              $GatewayName"
    Write-Host "  Resource Group:    $ResourceGroupName"
    Write-Host "  Location:          $Location"
    Write-Host "  SKU:               $GatewaySku"
    Write-Host "  Public IP:         $($gatewayPip.IpAddress)"
    Write-Host "  VNet:              $VNetName"
    Write-Host "  Client Pool:       $VPNClientAddressPool"
    Write-Host "  Authentication:    Entra ID"
    Write-Host ''
    Write-Host 'Download the VPN Client Package:' -ForegroundColor Cyan
    if ($clientPackage -and $clientPackage.VPNProfileSASUrl) {
        Write-Host "  URL: $($clientPackage.VPNProfileSASUrl)" -ForegroundColor White
        Write-Host '  (Expires after 1 hour. Save the file before then.)'
    } else {
        Write-Host '  Generate from the Azure portal:'
        Write-Host "  Portal -> Resource Groups -> $ResourceGroupName -> $GatewayName"
        Write-Host '  -> Point-to-site configuration -> Download VPN client'
    }
    Write-Host ''
    Write-Host 'Install the Azure VPN Client app on your device:' -ForegroundColor Cyan
    Write-Host '  Windows:   Microsoft Store -> search "Azure VPN Client"'
    Write-Host '  macOS:     Mac App Store -> search "Azure VPN Client"'
    Write-Host '  iOS:       App Store -> "Azure VPN Client"'
    Write-Host '  Android:   Play Store -> "Azure VPN Client"'
    Write-Host ''
    Write-Host 'To connect:' -ForegroundColor Cyan
    Write-Host '  1. Download and unzip the VPN client package above'
    Write-Host '  2. Open Azure VPN Client -> Import -> select the AzureVPN/azurevpnconfig.xml file from the zip'
    Write-Host '  3. Click Connect, sign in with your Microsoft account'
    Write-Host '  4. Once connected, you can reach private IPs in the VNet, e.g. http://10.0.2.4'
    Write-Host ''

    if ($audienceInfo.NeedsConsent -and $consentStatus -eq $false) {
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host 'IMPORTANT: Tenant consent for legacy Azure VPN enterprise app is REQUIRED' -ForegroundColor Yellow
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Before any user can authenticate to the VPN, a Global Admin or'
        Write-Host 'Application Admin must grant tenant-wide consent by visiting:'
        Write-Host ''
        Write-Host "  https://login.microsoftonline.com/$($context.Tenant.Id)/oauth2/authorize?client_id=$($audienceInfo.AppId)&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent" -ForegroundColor White
        Write-Host ''
        Write-Host 'After consent is granted, VPN clients will be able to sign in.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'TIP: Avoid this consent step entirely on future runs by NOT passing' -ForegroundColor Cyan
        Write-Host '     -UseLegacyAudience (the default uses the Microsoft-registered app).' -ForegroundColor Cyan
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host ''
    }

    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host '==============================================================='
    Write-Host ''

    # Return a structured result object
    $result = [PSCustomObject]@{
        GatewayName        = $GatewayName
        ResourceGroup      = $ResourceGroupName
        Location           = $Location
        SKU                = $GatewaySku
        PublicIP           = $gatewayPip.IpAddress
        VNetName           = $VNetName
        VNetResourceGroup  = $VNetResourceGroup
        GatewaySubnet      = $GatewaySubnetPrefix
        ClientAddressPool  = $VPNClientAddressPool
        TenantId           = $context.Tenant.Id
        AuthenticationMethod = 'EntraID'
        AudienceType       = $audienceInfo.Label
        AudienceAppId      = $audienceInfo.AppId
        ClientPackageURL   = if ($clientPackage) { $clientPackage.VPNProfileSASUrl } else { $null }
        ProvisioningState  = $gateway.ProvisioningState
        LogFile            = $LogFile
        ScriptVersion      = $ScriptVersion
        DeploymentTime     = (Get-Date -Format 'o')
    }
    $result

} catch {
    Write-LogMessage "SETUP FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    Write-Host ''
    Write-Host 'To investigate and/or clean up:' -ForegroundColor Yellow
    Write-Host "  Portal: Resource Groups -> $ResourceGroupName"
    Write-Host "  Cleanup: Remove-AzResourceGroup -Name $ResourceGroupName -Force"
    Write-Host ''
    throw
}

<#
.SYNOPSIS
    Sets up split-horizon DNS in Azure by creating a Private DNS Zone that mirrors
    an existing Public DNS Zone, linking it to a VNet, and (optionally) smart-copying
    public records into the private zone with conflict flagging.

.DESCRIPTION
    Split-horizon DNS (also called split-brain DNS) is the pattern where the same
    DNS name resolves to different IPs depending on where the resolver is. From
    inside your VNet (or via a DNS forwarder accessible through VPN),
    'erpnext.example.com' resolves to a private IP. From the public internet,
    it resolves to a public IP (or doesn't exist at all). This is the standard
    pattern for accessing internal services using your real domain name without
    exposing them publicly.

    This script handles the FIRST half of the split-horizon setup:

    1. CREATE the Azure Private DNS Zone matching your Public Zone name.

    2. LINK the Private Zone to your VNet. This automatically gives all resources
       INSIDE the VNet (App Services, VMs, etc.) DNS resolution via Azure's
       built-in resolver at 168.63.129.16.

    3. ADD records to the Private Zone:
       - Explicit private records you want to add (-PrivateRecords hashtable)
       - Optional smart copy of all public records (-CopyPublicRecords)
         with conflict flagging (records you specified manually win)

    The SECOND half - making VPN clients use this private DNS - requires a
    separate piece of infrastructure since VPN clients cannot reach Azure's
    built-in DNS resolver (168.63.129.16). Use Add-AzureDNSForwarder.ps1 to
    provision a small Ubuntu VM running dnsmasq that bridges the gap.

    The script is idempotent: re-running on an existing setup adds/updates records
    without removing anything you've configured manually.

.PARAMETER PublicZoneName
    Name of the existing public DNS zone to mirror. e.g. 'awesomewildstuff.com'.
    The private zone created will have the same name.

.PARAMETER PublicZoneResourceGroup
    Resource group containing the public DNS zone.

.PARAMETER VNetName
    Name of the VNet to link the private zone to. Resources inside the VNet
    automatically use the private zone via Azure's 168.63.129.16 resolver.

.PARAMETER VNetResourceGroup
    Resource group containing the VNet.

.PARAMETER PrivateZoneResourceGroup
    Resource group where the new private DNS zone will be created. If not
    specified, defaults to the VNet's RG. (Often a dedicated DNS RG is preferred.)

.PARAMETER PrivateRecords
    Hashtable of private records to add. Keys are record names (use '@' for
    apex/root), values are either an IP string (creates an A record) or a
    hashtable of {Type='A'|'CNAME'|...; Value='...'; TTL=3600}.

    Examples:
      @{ 'erpnext' = '10.0.2.4' }                              # Simple A record
      @{ 'erpnext' = @{ Type='A'; Value='10.0.2.4'; TTL=300 }} # Detailed form
      @{ 'mail' = @{ Type='CNAME'; Value='outlook.com' }}      # CNAME

.PARAMETER CopyPublicRecords
    Smart-copy public records into the private zone. Records you specified
    explicitly in -PrivateRecords always win. The script flags conflicts and
    records that probably should NOT be copied (e.g., MX records that should
    still point to public mail servers even from inside the VNet).

.PARAMETER PrivateZoneLinkName
    Name for the VNet-to-Private-Zone link. Default: derived from VNet name.

.PARAMETER EnableAutoRegistration
    Enable auto-registration on the VNet link. If enabled, VMs in the VNet
    automatically register their hostname into the private zone. Useful for
    dynamic environments; usually NOT what you want for production with manual
    record management. Default: off.

.PARAMETER DefaultTTL
    Default TTL (in seconds) for records added by the script. Default: 3600 (1 hour).

.PARAMETER ConfirmContext
    Multi-tenant safety bypass: accept the current Azure context without an
    explicit -SubscriptionId. Required if your account can see multiple
    subscriptions. Non-interactive flag.

.PARAMETER TenantId
    Entra tenant ID. Defaults to the current authenticated context.

.PARAMETER SubscriptionId
    Subscription ID. Defaults to the current authenticated context.

.EXAMPLE
    PS> .\Add-AzureSplitHorizonDNS.ps1 -ConfirmContext `
            -PublicZoneName 'contoso.com' `
            -PublicZoneResourceGroup 'contoso-dns-rg' `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -PrivateRecords @{ 'erpnext' = '10.0.2.4' }

    Minimal split-horizon setup: creates private zone, links it to the VNet,
    adds a single private record for erpnext. Reachable from inside the VNet
    automatically. For VPN-client access, also run Add-AzureDNSForwarder.ps1.

.EXAMPLE
    PS> .\Add-AzureSplitHorizonDNS.ps1 -ConfirmContext `
            -PublicZoneName 'contoso.com' `
            -PublicZoneResourceGroup 'contoso-dns-rg' `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -PrivateRecords @{
                'erpnext'   = '10.0.2.4'
                'wp-admin'  = '10.0.0.5'
                'db'        = '10.0.1.10'
            } `
            -CopyPublicRecords

    Full setup with multiple private records and smart copy of public records.
    The script flags MX/SPF/DKIM-style records that typically shouldn't be copied.

.EXAMPLE
    PS> .\Add-AzureSplitHorizonDNS.ps1 -ConfirmContext `
            -PublicZoneName 'awesomewildstuff.com' `
            -PublicZoneResourceGroup 'JTC-DNS-rg' `
            -VNetName 'jtcustomtr-2e886f0313-vnet' `
            -VNetResourceGroup 'JTC-Prod-WP-WestUS2-rg' `
            -PrivateZoneResourceGroup 'JTC-DNS-rg' `
            -PrivateRecords @{ 'erpnext' = '10.0.2.4' } `
            -CopyPublicRecords

    Real-world JTC scenario: split-horizon for awesomewildstuff.com with the
    erpnext private record and smart copy of public records.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Created:          05/17/2026
    Version:          1.0.0
    Last Updated:     05/17/2026

    REQUIREMENTS:
    - PowerShell 7.2 or later
    - Az.Network module 5.0+
    - Az.PrivateDns module
    - Az.Dns module (for reading public zone records)
    - Az.Accounts module
    - Az.Resources module
    - Owner or Contributor role on the target subscription
    - DNS Zone Contributor (or higher) on the target zone RGs

    COST: Azure Private DNS Zones are billed at ~$0.50/zone/month + DNS query
    volume (~$0.40 per million queries). Negligible for typical use.

    PREREQUISITES:
    - The public DNS zone must already exist.
    - The VNet must already exist.

    WHY VPN CLIENTS NEED EXTRA INFRASTRUCTURE:
    Azure's built-in DNS resolver (168.63.129.16) is only reachable from inside
    a VNet - VPN clients can't query it directly even when connected. To make
    VPN-connected laptops resolve names against the private zone, you need
    either:
      (a) A DNS forwarder VM inside the VNet that VPN clients query
          (use Add-AzureDNSForwarder.ps1 to provision this)
      (b) Azure DNS Private Resolver (managed service, ~$170/month)
      (c) Manual edits to each VPN client's azurevpnconfig.xml

    Option (a) is the cheapest and most flexible for SMB/single-client scenarios.

    WHAT THE 'SMART COPY' DOES:
    When -CopyPublicRecords is set, the script reads all records from the public
    zone and considers each one:

    - A/AAAA records: copied as-is unless you've defined a private override
      with the same name (your override wins). These are flagged as
      "PROBABLY OVERRIDE" since A records pointing to public IPs likely
      shouldn't be reachable from inside the VNet.

    - CNAME records: copied as-is. Usually safe.

    - MX records: NOT copied by default. Mail flow should go through public
      DNS even when you're inside the VNet (your VPN-connected laptop sends
      mail through real mail servers via the internet).

    - SPF/DKIM/DMARC TXT records: NOT copied by default. Same reason as MX.

    - NS records at apex: NEVER copied. Private zones use Azure's own NS.

    - SOA at apex: NEVER copied. Each zone has its own SOA.

    Records the script skips by default ARE logged so you can decide to add
    them manually if your use case differs.

.LINK
    https://learn.microsoft.com/en-us/azure/dns/private-dns-overview
    https://learn.microsoft.com/en-us/azure/dns/private-dns-virtual-network-links
#>

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Network, Az.PrivateDns, Az.Dns, Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'TenantId/SubscriptionId/ConfirmContext are used by Resolve-AzureContext via script-scope reference; PSScriptAnalyzer does not trace script-scope parameter usage from within nested functions.')]
param(
    [Parameter(Mandatory, HelpMessage = 'Name of the public DNS zone to mirror (e.g., contoso.com).')]
    [ValidateNotNullOrEmpty()]
    [string]$PublicZoneName,

    [Parameter(Mandatory, HelpMessage = 'Resource group containing the public DNS zone.')]
    [ValidateNotNullOrEmpty()]
    [string]$PublicZoneResourceGroup,

    [Parameter(Mandatory, HelpMessage = 'Name of the VNet to link the private zone to.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetName,

    [Parameter(Mandatory, HelpMessage = 'Resource group containing the VNet.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetResourceGroup,

    [Parameter(HelpMessage = 'Resource group for the new private DNS zone. Defaults to the VNet RG.')]
    [string]$PrivateZoneResourceGroup,

    [Parameter(HelpMessage = 'Hashtable of private records: name=IP (simple) or name=@{Type;Value;TTL} (detailed).')]
    [hashtable]$PrivateRecords = @{},

    [Parameter(HelpMessage = 'Smart-copy public records into the private zone with conflict flagging.')]
    [switch]$CopyPublicRecords,

    [Parameter(HelpMessage = 'Name for the VNet-to-Private-Zone link. Default: derived from VNet name.')]
    [string]$PrivateZoneLinkName,

    [Parameter(HelpMessage = 'Enable auto-registration on the VNet link (VMs register their hostnames automatically).')]
    [switch]$EnableAutoRegistration,

    [Parameter(HelpMessage = 'Default TTL (in seconds) for records added by this script. Default: 3600.')]
    [ValidateRange(60, 86400)]
    [int]$DefaultTTL = 3600,

    [Parameter(HelpMessage = 'Multi-tenant safety bypass: accept the current Azure context without an explicit -SubscriptionId.')]
    [switch]$ConfirmContext,

    [Parameter(HelpMessage = 'Entra tenant ID. Defaults to the current authenticated context.')]
    [string]$TenantId,

    [Parameter(HelpMessage = 'Subscription ID. Defaults to the current authenticated context.')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# Default the private zone RG to the VNet RG if not specified
if (-not $PrivateZoneResourceGroup) {
    $PrivateZoneResourceGroup = $VNetResourceGroup
}

# Default the link name
if (-not $PrivateZoneLinkName) {
    $PrivateZoneLinkName = "$VNetName-link"
}

# Logging
$LogTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $PSScriptRoot "Add-AzureSplitHorizonDNS_${LogTimestamp}.log"

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
        Same pattern as Setup-AzureP2SVPN.ps1.
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

function ConvertTo-RecordSpec {
    <#
    .SYNOPSIS
        Normalizes a -PrivateRecords value into a canonical record spec:
        @{ Type='A'; Value='10.0.2.4'; TTL=3600 }

        The input can be a plain IP string (becomes an A record), or a hashtable
        with Type/Value/TTL keys.
    #>
    param(
        [Parameter(Mandatory)] [string]$RecordName,
        [Parameter(Mandatory)] $InputSpec
    )

    if ($InputSpec -is [string]) {
        # Plain string: assume IPv4 A record (or IPv6 if it has colons)
        if ($InputSpec -match ':') {
            return @{ Type = 'AAAA'; Value = $InputSpec; TTL = $DefaultTTL }
        }
        return @{ Type = 'A'; Value = $InputSpec; TTL = $DefaultTTL }
    }

    if ($InputSpec -is [hashtable]) {
        $spec = @{
            Type  = if ($InputSpec.ContainsKey('Type')) { $InputSpec.Type } else { 'A' }
            Value = if ($InputSpec.ContainsKey('Value')) { $InputSpec.Value } else { throw "Record '$RecordName' missing 'Value' key." }
            TTL   = if ($InputSpec.ContainsKey('TTL')) { $InputSpec.TTL } else { $DefaultTTL }
        }
        return $spec
    }

    throw "Record '$RecordName' has an unsupported spec type: $($InputSpec.GetType().FullName). Expected string or hashtable."
}

function Add-PrivateDnsRecord {
    <#
    .SYNOPSIS
        Idempotently adds or updates a record in the private DNS zone.
        If the record already exists with the same value, no change. If it
        exists with a different value, the script logs the difference and
        UPDATES (overwriting). If it doesn't exist, creates new.
    #>
    param(
        [Parameter(Mandatory)] [string]$ZoneName,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$RecordName,
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [int]$TTL,
        [string]$Note = ''
    )

    $displayName = if ($RecordName -eq '@') { '(apex)' } else { $RecordName }
    $valueDisplay = if ($Value -is [array]) { $Value -join ', ' } else { $Value }
    $noteSuffix = if ($Note) { " [$Note]" } else { '' }

    # Build the appropriate record-config object based on the type.
    # Az.PrivateDns has type-specific *config* cmdlets.
    $configs = switch ($Type) {
        'A'     { @($Value | ForEach-Object { New-AzPrivateDnsRecordConfig -IPv4Address $_ }) }
        'AAAA'  { @($Value | ForEach-Object { New-AzPrivateDnsRecordConfig -IPv6Address $_ }) }
        'CNAME' {
            if ($Value -is [array] -and $Value.Count -gt 1) {
                throw "CNAME record '$RecordName' cannot have multiple values."
            }
            $cname = if ($Value -is [array]) { $Value[0] } else { $Value }
            @(New-AzPrivateDnsRecordConfig -Cname $cname)
        }
        'TXT'   {
            @($Value | ForEach-Object {
                # Azure Private DNS TXT records are limited to 1024 chars per record.
                # Long TXT records (e.g., DKIM keys) need to be split into 255-char
                # chunks. The cmdlet handles this.
                New-AzPrivateDnsRecordConfig -Value $_
            })
        }
        'MX'    {
            @($Value | ForEach-Object {
                # MX values come in as 'priority exchange', e.g. '10 mail.example.com'
                if ($_ -is [hashtable]) {
                    New-AzPrivateDnsRecordConfig -Exchange $_.Exchange -Preference $_.Preference
                } else {
                    $parts = $_ -split '\s+', 2
                    New-AzPrivateDnsRecordConfig -Preference ([int]$parts[0]) -Exchange $parts[1]
                }
            })
        }
        default { throw "Unsupported record type '$Type' for '$RecordName'. Supported: A, AAAA, CNAME, TXT, MX." }
    }

    # Check if record set already exists.
    $existing = Get-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroup -ZoneName $ZoneName `
        -Name $RecordName -RecordType $Type -ErrorAction SilentlyContinue

    if ($existing) {
        # Build a string representation of existing values for comparison
        $existingValues = $existing.Records | ForEach-Object {
            switch ($Type) {
                'A'     { $_.Ipv4Address }
                'AAAA'  { $_.Ipv6Address }
                'CNAME' { $_.Cname }
                'TXT'   { ($_.Value -join '') }
                'MX'    { "$($_.Preference) $($_.Exchange)" }
            }
        }
        $newValues = $configs | ForEach-Object {
            switch ($Type) {
                'A'     { $_.Ipv4Address }
                'AAAA'  { $_.Ipv6Address }
                'CNAME' { $_.Cname }
                'TXT'   { ($_.Value -join '') }
                'MX'    { "$($_.Preference) $($_.Exchange)" }
            }
        }

        $existingStr = ($existingValues | Sort-Object) -join ','
        $newStr = ($newValues | Sort-Object) -join ','

        if ($existingStr -eq $newStr -and $existing.Ttl -eq $TTL) {
            Write-LogMessage "  $Type $displayName -> $valueDisplay (already correct)$noteSuffix" -Level Skip
            return
        }

        # Differs - update in place
        if ($PSCmdlet.ShouldProcess("$displayName ($Type) in $ZoneName", "Update record to $valueDisplay")) {
            Write-LogMessage "  $Type $displayName : existing=$existingStr -> new=$newStr$noteSuffix" -Level Warning
            $existing.Ttl = $TTL
            $existing.Records = $configs
            Set-AzPrivateDnsRecordSet -RecordSet $existing | Out-Null
            Write-LogMessage "  $Type $displayName -> $valueDisplay (updated)$noteSuffix" -Level Success
        }
    } else {
        if ($PSCmdlet.ShouldProcess("$displayName ($Type) in $ZoneName", "Create record pointing to $valueDisplay")) {
            New-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroup -ZoneName $ZoneName `
                -Name $RecordName -RecordType $Type -Ttl $TTL -PrivateDnsRecords $configs | Out-Null
            Write-LogMessage "  $Type $displayName -> $valueDisplay (created)$noteSuffix" -Level Success
        }
    }
}

function Test-RecordShouldBeSkipped {
    <#
    .SYNOPSIS
        Returns a reason string if a record should be SKIPPED during smart copy,
        or $null if it should be copied.
    #>
    param(
        [Parameter(Mandatory)] $RecordSet
    )

    # NS and SOA are managed by Azure; never copy.
    if ($RecordSet.RecordType -in @('NS', 'SOA')) {
        return 'Azure-managed record type (NS/SOA)'
    }

    # MX records typically should not be in the private zone - mail flow goes
    # through public MX hosts even from inside the VNet.
    if ($RecordSet.RecordType -eq 'MX') {
        return 'MX records: mail flow should use public DNS'
    }

    # TXT records that look like mail authentication infrastructure (SPF, DKIM, DMARC)
    if ($RecordSet.RecordType -eq 'TXT') {
        $textValues = $RecordSet.Records | ForEach-Object { $_.Value -join '' }
        foreach ($v in $textValues) {
            if ($v -match '^v=spf1' -or $v -match '^v=DKIM1' -or $v -match '^v=DMARC1' -or $v -match 'p=.*DKIM') {
                return 'Mail authentication TXT (SPF/DKIM/DMARC)'
            }
        }
    }

    return $null
}

function Test-IsPrivateIP {
    <#
    .SYNOPSIS
        Returns $true if the given IP string is in RFC 1918 private space
        (10/8, 172.16/12, 192.168/16) or IPv6 ULA (fc00::/7).
    #>
    param([Parameter(Mandatory)] [string]$IP)

    if ($IP -match ':') {
        # IPv6 - check for ULA (fc00::/7) or link-local (fe80::/10)
        return $IP -match '^[fF][cCdD]' -or $IP -match '^[fF][eE]8'
    }

    $octets = $IP -split '\.'
    if ($octets.Count -ne 4) { return $false }
    $first = [int]$octets[0]
    $second = [int]$octets[1]

    if ($first -eq 10) { return $true }
    if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return $true }
    if ($first -eq 192 -and $second -eq 168) { return $true }
    return $false
}

function Test-RecordIsProbableOverride {
    <#
    .SYNOPSIS
        Returns $true if the record's value LOOKS LIKE a public IP that probably
        shouldn't be reachable from inside the VNet (i.e., a candidate for the
        operator to define a private override).
    #>
    param(
        [Parameter(Mandatory)] $RecordSet
    )

    if ($RecordSet.RecordType -notin @('A', 'AAAA')) { return $false }

    # Check if any record value is a private IP. If ALL values are private,
    # this isn't an override candidate.
    foreach ($r in $RecordSet.Records) {
        $ip = if ($RecordSet.RecordType -eq 'A') { $r.Ipv4Address } else { $r.Ipv6Address }
        if (Test-IsPrivateIP $ip) { return $false }
    }
    return $true
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

Write-Host '==============================================================='
Write-Host "  Azure Split-Horizon DNS Setup Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host '  Azure Innovators'
Write-Host "  Log: $LogFile"
Write-Host '==============================================================='
Write-Host ''

try {
    # ---- Pre-flight: context ----
    Write-LogMessage 'Running pre-flight checks...' -Level Info
    $context = Resolve-AzureContext

    # ---- Pre-flight: public zone exists ----
    Write-LogMessage "Verifying public DNS zone: $PublicZoneName (RG: $PublicZoneResourceGroup)" -Level Info
    $publicZone = Get-AzDnsZone -Name $PublicZoneName -ResourceGroupName $PublicZoneResourceGroup -ErrorAction SilentlyContinue
    if (-not $publicZone) {
        throw "Public DNS zone '$PublicZoneName' not found in resource group '$PublicZoneResourceGroup'. Verify zone name and RG."
    }
    Write-LogMessage "  Public zone found." -Level Success

    # ---- Pre-flight: VNet exists ----
    Write-LogMessage "Verifying VNet: $VNetName (RG: $VNetResourceGroup)" -Level Info
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup -ErrorAction SilentlyContinue
    if (-not $vnet) {
        throw "VNet '$VNetName' not found in resource group '$VNetResourceGroup'."
    }
    Write-LogMessage "  VNet found. Location: $($vnet.Location)" -Level Success

    # ---- Pre-flight: private zone RG exists ----
    $privateRG = Get-AzResourceGroup -Name $PrivateZoneResourceGroup -ErrorAction SilentlyContinue
    if (-not $privateRG) {
        Write-LogMessage "Resource group '$PrivateZoneResourceGroup' does not exist. Creating..." -Level Info
        if ($PSCmdlet.ShouldProcess($PrivateZoneResourceGroup, "Create resource group in $($vnet.Location)")) {
            New-AzResourceGroup -Name $PrivateZoneResourceGroup -Location $vnet.Location -Tag @{
                Project = 'DNS'
                ManagedBy = 'Add-AzureSplitHorizonDNS'
            } | Out-Null
            Write-LogMessage "  Created." -Level Success
        }
    }

    # ---- Plan output ----
    Write-Host ''
    Write-Host 'SETUP PLAN' -ForegroundColor Cyan
    Write-Host "  Account:                $($context.Account.Id)"
    Write-Host "  Subscription:           $($context.Subscription.Name)"
    Write-Host "  Public Zone:            $PublicZoneName (RG: $PublicZoneResourceGroup)"
    Write-Host "  Private Zone:           $PublicZoneName (RG: $PrivateZoneResourceGroup)"
    Write-Host "  Linked VNet:            $VNetName (RG: $VNetResourceGroup)"
    Write-Host "  Link Name:              $PrivateZoneLinkName"
    Write-Host "  Auto-Registration:      $($EnableAutoRegistration.IsPresent)"
    Write-Host "  Explicit Records:       $($PrivateRecords.Count)"
    Write-Host "  Copy Public Records:    $($CopyPublicRecords.IsPresent)"
    Write-Host ''

    # ---- Step 1: Create Private DNS Zone ----
    Write-LogMessage 'Step 1/4: Private DNS Zone' -Level Info
    $privateZone = Get-AzPrivateDnsZone -Name $PublicZoneName -ResourceGroupName $PrivateZoneResourceGroup -ErrorAction SilentlyContinue
    if ($privateZone) {
        Write-LogMessage "  Private zone '$PublicZoneName' already exists in $PrivateZoneResourceGroup. Reusing." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess($PublicZoneName, 'Create Private DNS Zone')) {
            $privateZone = New-AzPrivateDnsZone -Name $PublicZoneName -ResourceGroupName $PrivateZoneResourceGroup
            Write-LogMessage "  Created Private DNS Zone: $PublicZoneName" -Level Success
        }
    }

    # ---- Step 2: Link Private Zone to VNet ----
    Write-LogMessage 'Step 2/4: VNet Link' -Level Info
    $existingLink = Get-AzPrivateDnsVirtualNetworkLink -ZoneName $PublicZoneName -ResourceGroupName $PrivateZoneResourceGroup -Name $PrivateZoneLinkName -ErrorAction SilentlyContinue
    if ($existingLink) {
        Write-LogMessage "  VNet link '$PrivateZoneLinkName' already exists. Reusing." -Level Info
        # Note: changing auto-registration on existing link requires a separate Set- call;
        # we don't change it automatically since it could disrupt running registrations.
        if ($existingLink.RegistrationEnabled -ne $EnableAutoRegistration.IsPresent) {
            Write-LogMessage "  (Auto-registration is currently $($existingLink.RegistrationEnabled); requested $($EnableAutoRegistration.IsPresent). Not changing automatically.)" -Level Warning
        }
    } else {
        if ($PSCmdlet.ShouldProcess($PrivateZoneLinkName, "Link VNet $VNetName to Private Zone $PublicZoneName")) {
            New-AzPrivateDnsVirtualNetworkLink -ZoneName $PublicZoneName -ResourceGroupName $PrivateZoneResourceGroup `
                -Name $PrivateZoneLinkName -VirtualNetworkId $vnet.Id -EnableRegistration:$EnableAutoRegistration | Out-Null
            Write-LogMessage "  Linked VNet $VNetName to Private Zone $PublicZoneName" -Level Success
        }
    }

    # ---- Step 3: Add explicit private records ----
    Write-LogMessage 'Step 3/4: Adding explicit private records' -Level Info
    if ($PrivateRecords.Count -eq 0) {
        Write-LogMessage "  No explicit records provided (-PrivateRecords was empty)." -Level Skip
    } else {
        foreach ($recordName in $PrivateRecords.Keys) {
            $spec = ConvertTo-RecordSpec -RecordName $recordName -InputSpec $PrivateRecords[$recordName]
            Add-PrivateDnsRecord -ZoneName $PublicZoneName -ResourceGroup $PrivateZoneResourceGroup `
                -RecordName $recordName -Type $spec.Type -Value $spec.Value -TTL $spec.TTL `
                -Note 'explicit'
        }
    }

    # ---- Step 4: Smart copy of public records ----
    Write-LogMessage 'Step 4/4: Smart copy of public records' -Level Info
    if (-not $CopyPublicRecords) {
        Write-LogMessage "  Skipped (-CopyPublicRecords not specified)." -Level Skip
    } else {
        $publicRecordSets = Get-AzDnsRecordSet -ZoneName $PublicZoneName -ResourceGroupName $PublicZoneResourceGroup

        $copied = 0
        $skipped = 0
        $overriddenByExplicit = 0
        $flaggedAsOverride = New-Object System.Collections.Generic.List[string]

        # Build a quick lookup of which records were already added explicitly,
        # so we don't overwrite them.
        $explicitRecordKeys = New-Object System.Collections.Generic.HashSet[string]
        foreach ($explicitName in $PrivateRecords.Keys) {
            $explicitSpec = ConvertTo-RecordSpec -RecordName $explicitName -InputSpec $PrivateRecords[$explicitName]
            $key = "$explicitName/$($explicitSpec.Type)"
            [void]$explicitRecordKeys.Add($key)
        }

        foreach ($rs in $publicRecordSets) {
            # The Name from Get-AzDnsRecordSet is the relative name ('@' for apex,
            # 'erpnext' for a subdomain, etc).
            $recordName = $rs.Name

            # Check skip rules first
            $skipReason = Test-RecordShouldBeSkipped -RecordSet $rs
            if ($skipReason) {
                Write-LogMessage "  SKIP: $($rs.RecordType) $recordName [$skipReason]" -Level Skip
                $skipped++
                continue
            }

            # Check if operator already defined this record explicitly
            $key = "$recordName/$($rs.RecordType)"
            if ($explicitRecordKeys.Contains($key)) {
                Write-LogMessage "  SKIP: $($rs.RecordType) $recordName (overridden by explicit -PrivateRecords entry)" -Level Skip
                $overriddenByExplicit++
                continue
            }

            # Check if this is an override candidate (public-IP A/AAAA record)
            $isOverrideCandidate = Test-RecordIsProbableOverride -RecordSet $rs

            # Extract values into the canonical form Add-PrivateDnsRecord expects
            $value = switch ($rs.RecordType) {
                'A'     { @($rs.Records | ForEach-Object { $_.Ipv4Address }) }
                'AAAA'  { @($rs.Records | ForEach-Object { $_.Ipv6Address }) }
                'CNAME' { $rs.Records[0].Cname }
                'TXT'   { @($rs.Records | ForEach-Object { $_.Value -join '' }) }
                'MX'    { @($rs.Records | ForEach-Object { "$($_.Preference) $($_.Exchange)" }) }
                default {
                    Write-LogMessage "  SKIP: $($rs.RecordType) $recordName (record type not currently supported for copy)" -Level Skip
                    $skipped++
                    continue
                }
            }

            $note = if ($isOverrideCandidate) { 'COPY but consider overriding to private IP' } else { 'copied from public' }
            Add-PrivateDnsRecord -ZoneName $PublicZoneName -ResourceGroup $PrivateZoneResourceGroup `
                -RecordName $recordName -Type $rs.RecordType -Value $value -TTL $rs.Ttl `
                -Note $note

            if ($isOverrideCandidate) {
                $flaggedAsOverride.Add("$($rs.RecordType) $recordName ($($value -join ', '))")
            }
            $copied++
        }

        Write-LogMessage "  Smart copy complete: $copied copied, $skipped skipped, $overriddenByExplicit overridden by explicit entries." -Level Info

        if ($flaggedAsOverride.Count -gt 0) {
            Write-Host ''
            Write-Host 'RECORDS FLAGGED FOR CONSIDERATION:' -ForegroundColor Yellow
            Write-Host 'The following A/AAAA records point to PUBLIC IPs. They were copied' -ForegroundColor Yellow
            Write-Host 'into the private zone, but if these resources have a private IP you' -ForegroundColor Yellow
            Write-Host 'want to use instead, consider re-running with an explicit override:' -ForegroundColor Yellow
            Write-Host ''
            foreach ($f in $flaggedAsOverride) {
                Write-Host "  - $f" -ForegroundColor Yellow
            }
            Write-Host ''
        }
    }

    # ---- Summary ----
    Write-Host '==============================================================='
    Write-Host '  SPLIT-HORIZON DNS SETUP COMPLETE' -ForegroundColor Green
    Write-Host '==============================================================='
    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-Host "  Private Zone:       $PublicZoneName"
    Write-Host "  Private Zone RG:    $PrivateZoneResourceGroup"
    Write-Host "  Linked to VNet:     $VNetName"
    Write-Host "  Explicit Records:   $($PrivateRecords.Count)"
    if ($CopyPublicRecords) {
        Write-Host "  Public Records:     Smart-copied (see log for details)"
    }
    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host 'IMPORTANT - VPN CLIENT DNS RESOLUTION:' -ForegroundColor Yellow
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Resources INSIDE the VNet (Azure VMs, App Services with VNet'
    Write-Host 'integration) can now resolve names against the private zone'
    Write-Host 'automatically via Azure DNS (168.63.129.16).'
    Write-Host ''
    Write-Host 'However, VPN-connected CLIENTS cannot reach 168.63.129.16'
    Write-Host 'directly. To make VPN clients use the private zone, run:'
    Write-Host ''
    Write-Host '  Add-AzureDNSForwarder.ps1 -ConfirmContext \`'
    Write-Host "      -VNetName '$VNetName' \``"
    Write-Host "      -VNetResourceGroup '$VNetResourceGroup'"
    Write-Host ''
    Write-Host 'This provisions a small Ubuntu VM running dnsmasq inside the'
    Write-Host 'VNet, then VPN clients automatically pick it up after'
    Write-Host 'regenerating their VPN profile.'
    Write-Host ''
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host '==============================================================='
    Write-Host ''

    # Return a structured result object
    [PSCustomObject]@{
        PrivateZoneName    = $PublicZoneName
        PrivateZoneRG      = $PrivateZoneResourceGroup
        VNetName           = $VNetName
        VNetResourceGroup  = $VNetResourceGroup
        LinkName           = $PrivateZoneLinkName
        ExplicitRecordsAdded = $PrivateRecords.Count
        PublicRecordsCopied  = $CopyPublicRecords.IsPresent
        LogFile            = $LogFile
        ScriptVersion      = $ScriptVersion
        DeploymentTime     = (Get-Date -Format 'o')
    }

} catch {
    Write-LogMessage "SETUP FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    throw
}

<#
.SYNOPSIS
    Removes an Azure P2S VPN Gateway created by Setup-AzureP2SVPN.ps1.

.DESCRIPTION
    Tears down a P2S VPN Gateway and its associated resources cleanly. Designed
    as the companion script to Setup-AzureP2SVPN.ps1.

    What gets removed (in order):
    1. VPN Gateway (the slow part - 10-15 minutes to delete)
    2. Gateway Public IP
    3. GatewaySubnet (optional - only if -RemoveGatewaySubnet is passed)

    What does NOT get removed (intentionally):
    - The VNet itself (it almost always has other resources in it - WordPress,
      databases, application VMs - that we should not touch)
    - The resource group (might contain other things, same reasoning)
    - Any consumer resources (VMs, App Services) that were using the VPN

    GATEWAY DELETION IS SLOW. Azure takes 10-15 minutes to actually delete a
    VPN Gateway. The script polls every 60 seconds and reports progress.

.PARAMETER GatewayName
    Name of the VPN Gateway to remove. If not specified, the script will
    attempt to derive it from -VNetName using the same convention
    Setup-AzureP2SVPN.ps1 uses (replace -vnet with -vpngw).

.PARAMETER ResourceGroupName
    Resource group containing the gateway. Defaults to -VNetResourceGroup
    if not specified.

.PARAMETER VNetName
    Name of the VNet the gateway is attached to. Used to:
    - Derive the default gateway name (if -GatewayName not given)
    - Locate the GatewaySubnet (if -RemoveGatewaySubnet is passed)

.PARAMETER VNetResourceGroup
    Resource group containing the VNet.

.PARAMETER RemoveGatewaySubnet
    Also remove the GatewaySubnet from the VNet after the gateway is gone.
    Default behavior is to leave the subnet in place since removing it
    requires VNet write permissions that the operator may not have on a
    shared VNet.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.PARAMETER TimeoutMinutes
    How long to wait for gateway deletion before declaring timeout.
    Default: 30 minutes (deletion typically takes 10-15).

.PARAMETER WhatIf
    Show what would be removed without actually deleting anything.

.EXAMPLE
    PS> .\Remove-AzureP2SVPN.ps1 -Force `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg'

    Removes the VPN gateway derived from the VNet name (gateway name:
    contoso-prod-vpngw). Leaves the GatewaySubnet in place.

.EXAMPLE
    PS> .\Remove-AzureP2SVPN.ps1 -Force `
            -VNetName 'contoso-prod-vnet' `
            -VNetResourceGroup 'contoso-network-rg' `
            -RemoveGatewaySubnet

    Same as above, but also removes the GatewaySubnet after the gateway
    is gone.

.EXAMPLE
    PS> .\Remove-AzureP2SVPN.ps1 -Force `
            -GatewayName 'my-explicit-vpngw-name' `
            -ResourceGroupName 'vpn-rg' `
            -VNetName 'shared-hub-vnet' `
            -VNetResourceGroup 'shared-infra-rg' `
            -RemoveGatewaySubnet

    Explicit names for the case where the gateway, public IP, and VNet
    live in different resource groups (hub-spoke pattern).

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Version:          1.0.2
    Created:          05/16/2026
    Last Updated:     05/16/2026

    SAFETY:
    The script will refuse to delete a gateway that has active connections.
    You must explicitly remove site-to-site connections (if any) before
    running this script. P2S clients can stay - those go away with the
    gateway.

.LINK
    https://github.com/JONeillSr/Setup-AzureP2SVPN
#>

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Network

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(HelpMessage='Name of the VPN Gateway to remove. Derived from -VNetName if not specified.')]
    [string]$GatewayName,

    [Parameter(HelpMessage='Resource group containing the gateway. Defaults to -VNetResourceGroup.')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, HelpMessage='Name of the VNet the gateway is attached to.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetName,

    [Parameter(Mandatory, HelpMessage='Resource group containing the VNet.')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetResourceGroup,

    [Parameter(HelpMessage='Resource naming prefix. When provided, the script locates resources named "<NamePrefix>-vpngw" and "<NamePrefix>-vpngw-pip". Should match the -NamePrefix used during Setup-AzureP2SVPN.')]
    [string]$NamePrefix,

    [Parameter(HelpMessage='Also remove the GatewaySubnet from the VNet after the gateway is deleted.')]
    [switch]$RemoveGatewaySubnet,

    [Parameter(HelpMessage='Skip the interactive confirmation prompt.')]
    [switch]$Force,

    [Parameter(HelpMessage='Entra tenant ID. Defaults to the current authenticated context.')]
    [string]$TenantId,

    [Parameter(HelpMessage='Subscription ID. Defaults to the current authenticated context.')]
    [string]$SubscriptionId,

    [Parameter(HelpMessage='Multi-tenant safety bypass: accept the current Azure context without an explicit -SubscriptionId. Required if your account can see multiple subscriptions. Non-interactive flag.')]
    [switch]$ConfirmContext,

    [Parameter(HelpMessage='Timeout in minutes for the gateway deletion operation.')]
    [ValidateRange(5, 90)]
    [int]$TimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.2'

# Default the deployment RG to the VNet RG if not specified
if (-not $ResourceGroupName) {
    $ResourceGroupName = $VNetResourceGroup
}

# Resource naming. Same precedence as Setup-AzureP2SVPN.ps1:
#   1. Explicit -GatewayName wins
#   2. -NamePrefix produces "<prefix>-vpngw" (matches sibling scripts)
#   3. Fall back to VNet-derived name
if (-not $GatewayName) {
    if ($NamePrefix) {
        $GatewayName = "$NamePrefix-vpngw"
    } elseif ($VNetName -match '-vnet$') {
        $GatewayName = $VNetName -replace '-vnet$', '-vpngw'
    } else {
        $GatewayName = "$VNetName-vpngw"
    }
}

$GatewayPublicIPName = "$GatewayName-pip"

# Logging
$LogTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $PSScriptRoot "Remove-AzureP2SVPN_${LogTimestamp}.log"

# Suppress confirmation prompts in the parent session when -Force is passed.
# Background-job runspaces don't inherit this; we set $ConfirmPreference
# explicitly inside any Start-Job script blocks.
if ($Force) {
    $ConfirmPreference = 'None'
    $PSDefaultParameterValues['*:Confirm'] = $false
}

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

    # Multi-tenant safety: same pattern as Setup-AzureP2SVPN.ps1.
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

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

Write-Host '==============================================================='
Write-Host "  Azure P2S VPN Teardown Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host '  Azure Innovators'
Write-Host "  Log: $LogFile"
Write-Host '==============================================================='
Write-Host ''

try {
    Write-LogMessage 'Running pre-flight checks...' -Level Info
    $context = Resolve-AzureContext

    # ---- Inventory what we'd remove ----
    Write-LogMessage 'Inventorying resources to remove...' -Level Info

    $gateway = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    $publicIp = Get-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup -ErrorAction SilentlyContinue
    $gatewaySubnet = if ($vnet) { $vnet.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' } } else { $null }

    if (-not $gateway -and -not $publicIp -and -not $gatewaySubnet) {
        Write-LogMessage 'Nothing to remove - no matching gateway, public IP, or GatewaySubnet found.' -Level Warning
        Write-Host ''
        Write-Host 'Checked for:' -ForegroundColor Cyan
        Write-Host "  Gateway:        $GatewayName (RG: $ResourceGroupName)"
        Write-Host "  Public IP:      $GatewayPublicIPName (RG: $ResourceGroupName)"
        Write-Host "  GatewaySubnet:  in $VNetName (RG: $VNetResourceGroup)"
        return
    }

    # ---- Safety: check for active S2S connections ----
    if ($gateway) {
        $connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
            Where-Object {
                $_.VirtualNetworkGateway1.Id -eq $gateway.Id -or
                ($_.VirtualNetworkGateway2 -and $_.VirtualNetworkGateway2.Id -eq $gateway.Id)
            }
        if ($connections) {
            Write-LogMessage "Gateway has $($connections.Count) active connection(s):" -Level Error
            foreach ($conn in $connections) {
                Write-LogMessage "  - $($conn.Name) (type: $($conn.ConnectionType))" -Level Error
            }
            Write-LogMessage 'Remove these connections first, then re-run the teardown.' -Level Error
            throw 'Cannot delete gateway with active connections. Remove connections first.'
        }
    }

    # ---- Teardown plan ----
    Write-Host ''
    Write-Host 'TEARDOWN PLAN' -ForegroundColor Cyan
    Write-Host "  Account:                 $($context.Account.Id)"
    Write-Host "  Tenant:                  $($context.Tenant.Id)"
    Write-Host "  Subscription:            $($context.Subscription.Name)"
    Write-Host '  Resources to delete:'
    if ($gateway)   { Write-Host "    Gateway:               $GatewayName (RG: $ResourceGroupName)" -ForegroundColor Yellow }
    if ($publicIp)  { Write-Host "    Public IP:             $GatewayPublicIPName ($($publicIp.IpAddress))" -ForegroundColor Yellow }
    if ($RemoveGatewaySubnet -and $gatewaySubnet) {
                      Write-Host "    GatewaySubnet:         $($gatewaySubnet.AddressPrefix) in $VNetName" -ForegroundColor Yellow
    } elseif ($gatewaySubnet) {
                      Write-Host "    GatewaySubnet:         leaving in place (pass -RemoveGatewaySubnet to remove)"
    }
    Write-Host "  Force:                   $($Force.IsPresent)"
    Write-Host "  WhatIf:                  $($WhatIfPreference)"
    Write-Host "  Timeout:                 $TimeoutMinutes minutes"
    Write-Host ''

    if (-not $Force -and -not $WhatIfPreference) {
        $resp = Read-Host 'Proceed with teardown? (yes/no)'
        if ($resp -ne 'yes') {
            Write-LogMessage 'Teardown cancelled by user.' -Level Info
            return
        }
    }

    # ---- Step 1: Delete the gateway (the slow part) ----
    if ($gateway) {
        Write-LogMessage "Deleting VPN Gateway '$GatewayName' (this takes 10-15 minutes typically)..." -Level Info
        if ($PSCmdlet.ShouldProcess($GatewayName, 'Delete VPN Gateway')) {
            $startTime = Get-Date

            # Use Start-Job with explicit ConfirmPreference inside the runspace.
            # Same pattern as Remove-ERPNextAzureDeployment learned the hard way:
            # background job runspaces don't inherit prompt suppression.
            $delJob = Start-Job -ScriptBlock {
                param($GwName, $RGName, $SubId, $TenantId)
                $ConfirmPreference = 'None'
                $PSDefaultParameterValues['*:Confirm'] = $false
                Import-Module Az.Network -ErrorAction Stop
                Import-Module Az.Accounts -ErrorAction Stop
                try { $null = Set-AzContext -Tenant $TenantId -SubscriptionId $SubId -ErrorAction SilentlyContinue } catch { }
                Remove-AzVirtualNetworkGateway -Name $GwName -ResourceGroupName $RGName -Force -Confirm:$false
            } -ArgumentList $GatewayName, $ResourceGroupName, $context.Subscription.Id, $context.Tenant.Id

            $deadline = $startTime.AddMinutes($TimeoutMinutes)
            $terminalStates = @('Completed', 'Failed', 'Stopped')
            $firstBlockedAt = $null

            while ($delJob.State -notin $terminalStates) {
                if ((Get-Date) -gt $deadline) {
                    Write-LogMessage "Gateway deletion exceeded $TimeoutMinutes minute timeout." -Level Error
                    Stop-Job $delJob
                    throw 'Timeout deleting VPN Gateway. Check the Azure portal for current state.'
                }
                if ($delJob.State -eq 'Blocked') {
                    if (-not $firstBlockedAt) { $firstBlockedAt = Get-Date }
                    elseif (((Get-Date) - $firstBlockedAt).TotalMinutes -gt 2) {
                        Write-LogMessage "Job has been 'Blocked' for over 2 minutes - aborting." -Level Error
                        Stop-Job $delJob
                        Remove-Job $delJob -Force
                        throw 'Background-job runspace blocked on prompt.'
                    }
                } else {
                    $firstBlockedAt = $null
                }
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                Write-LogMessage "  Gateway deletion in progress... ($elapsed min, state: $($delJob.State))" -Level Debug
                Start-Sleep -Seconds 60
            }

            if ($delJob.State -eq 'Failed') {
                $jobErrors = Receive-Job $delJob -ErrorAction Continue 2>&1
                Remove-Job $delJob -Force
                Write-LogMessage 'Gateway deletion failed:' -Level Error
                foreach ($e in $jobErrors) { Write-LogMessage "  $e" -Level Error }
                throw 'VPN Gateway deletion failed. Check Azure activity log.'
            }

            Receive-Job $delJob | Out-Null
            Remove-Job $delJob -Force

            # Verify deletion
            $stillThere = Get-AzVirtualNetworkGateway -Name $GatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            if ($stillThere) {
                throw "Job completed but gateway '$GatewayName' still exists."
            }
            $totalMin = [int]((Get-Date) - $startTime).TotalMinutes
            Write-LogMessage "  Gateway deleted in $totalMin minutes." -Level Success
        }
    } else {
        Write-LogMessage "Gateway '$GatewayName' not found. Skipping." -Level Info
    }

    # ---- Step 2: Delete the public IP ----
    if ($publicIp) {
        Write-LogMessage "Deleting Public IP '$GatewayPublicIPName'..." -Level Info
        if ($PSCmdlet.ShouldProcess($GatewayPublicIPName, 'Delete Public IP')) {
            Remove-AzPublicIpAddress -Name $GatewayPublicIPName -ResourceGroupName $ResourceGroupName -Force -Confirm:$false
            Write-LogMessage '  Public IP deleted.' -Level Success
        }
    } else {
        Write-LogMessage "Public IP '$GatewayPublicIPName' not found. Skipping." -Level Info
    }

    # ---- Step 3: Optionally remove the GatewaySubnet ----
    if ($RemoveGatewaySubnet) {
        if ($gatewaySubnet) {
            Write-LogMessage "Removing GatewaySubnet from VNet '$VNetName'..." -Level Info
            if ($PSCmdlet.ShouldProcess("GatewaySubnet in $VNetName", 'Remove subnet')) {
                # Re-fetch the VNet since we may have modified it earlier
                $vnetCurrent = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup
                $currentSubnet = $vnetCurrent.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' }
                if ($currentSubnet.IpConfigurations.Count -gt 0) {
                    Write-LogMessage "  GatewaySubnet still has $($currentSubnet.IpConfigurations.Count) IP config(s). The gateway may not have fully released its IP yet. Skipping subnet removal." -Level Warning
                    Write-LogMessage "  Wait 1-2 minutes and re-run with -RemoveGatewaySubnet if you want it removed." -Level Warning
                } else {
                    Remove-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnetCurrent | Out-Null
                    $vnetCurrent | Set-AzVirtualNetwork | Out-Null
                    Write-LogMessage '  GatewaySubnet removed.' -Level Success
                }
            }
        } else {
            Write-LogMessage 'GatewaySubnet not found in VNet. Skipping.' -Level Info
        }
    } else {
        if ($gatewaySubnet) {
            Write-LogMessage 'GatewaySubnet left in place (no -RemoveGatewaySubnet flag).' -Level Info
        }
    }

    # ---- Summary ----
    Write-Host ''
    Write-Host '==============================================================='
    Write-Host '  TEARDOWN COMPLETE' -ForegroundColor Green
    Write-Host '==============================================================='
    Write-Host ''
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ''

    $result = [PSCustomObject]@{
        GatewayName        = $GatewayName
        ResourceGroup      = $ResourceGroupName
        VNetName           = $VNetName
        VNetResourceGroup  = $VNetResourceGroup
        GatewayDeleted     = [bool]$gateway
        PublicIPDeleted    = [bool]$publicIp
        SubnetRemoved      = $RemoveGatewaySubnet -and $gatewaySubnet
        LogFile            = $LogFile
        ScriptVersion      = $ScriptVersion
        TeardownTime       = (Get-Date -Format 'o')
    }
    $result

} catch {
    Write-LogMessage "TEARDOWN FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    throw
}

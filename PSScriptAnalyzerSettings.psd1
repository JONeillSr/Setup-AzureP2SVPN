@{
    # PSScriptAnalyzer settings for the Setup-AzureP2SVPN repo.
    #
    # Reference: https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/readme

    # Run all built-in rules by default. The IncludeRules list lets us be explicit
    # about which ones we care about, even when PSScriptAnalyzer ships new rules.
    IncludeDefaultRules = $true

    # Severity levels surfaced by the CI workflow. Errors fail the build,
    # Warnings and Information are reported but non-blocking.
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-Host is used intentionally throughout for user-facing output.
        # Switching to Write-Information would mean callers need -InformationAction
        # Continue to see anything, which defeats the purpose.
        'PSAvoidUsingWriteHost',

        # The script uses convenience plural variables ($accessibleSubs, etc.)
        # that PSSA's PSUseSingularNouns rule flags. They're variables, not
        # function names, so the rule misfires anyway in current PSSA versions.
        'PSUseSingularNouns',

        # We deliberately use approved Verb-Noun naming for functions; this
        # rule sometimes mistakes script-block helpers for functions.
        # Re-enable if false positives drop in future PSSA versions.
        'PSUseApprovedVerbs'
    )

    Rules = @{
        # Enforce consistent indentation
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }

        # Require consistent whitespace around operators and after commas
        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        # OTBS = "One True Brace Style" - opening brace on same line as control statement
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        # Single quotes for plain strings (double only when interpolating)
        PSAvoidUsingDoubleQuotesForConstantString = @{
            Enable = $true
        }

        # Enforce ShouldProcess in cmdlets that need it (the scripts use -WhatIf)
        PSShouldProcess = @{
            Enable = $true
        }
    }
}

@{
    # PSScriptAnalyzer settings for Azure Innovators PowerShell automation scripts.
    #
    # Reference: https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/readme
    #
    # This file is shared verbatim between the ERPNext and Setup-AzureP2SVPN
    # repos. Keep them in sync when adjusting rules.

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

        # The scripts use convenience plural variables ($accessibleSubs, etc.)
        # that PSSA's PSUseSingularNouns rule flags. They're variables, not
        # function names, so the rule misfires anyway in current PSSA versions.
        'PSUseSingularNouns',

        # We deliberately use approved Verb-Noun naming for functions; this
        # rule sometimes mistakes script-block helpers for functions.
        # Re-enable if false positives drop in future PSSA versions.
        'PSUseApprovedVerbs',

        # False positive when -ArgumentList is used with Start-Job: PSSA can't
        # tell that variables are passed explicitly and received by the script
        # block's own param() declaration. Our Start-Job usage is correct;
        # we don't need $using: when we're using -ArgumentList.
        'PSUseUsingScopeModifierInNewRunspaces',

        # Cosmetic only. Single vs double quotes is not a real correctness
        # concern when no interpolation happens. We use double quotes
        # consistently for readability since most strings in this codebase
        # DO interpolate; mixing styles based on whether a single line
        # happens to have a $var is more visual noise than it's worth.
        'PSAvoidUsingDoubleQuotesForConstantString',

        # Misfires on intentional multi-line continuation indentation
        # (e.g., Where-Object pipelines aligned for readability). Real
        # indentation errors are caught by code review.
        'PSUseConsistentIndentation',

        # Style preference: we use `} else {` and `} catch {` on the same
        # line (the "Cuddled Else" style, common in PowerShell community
        # tooling). PSSA defaults to wanting a newline before `else` /
        # `catch`. Both are valid; we prefer the compact form for
        # readability when the body is short.
        'PSPlaceCloseBrace',

        # Informational only. Adding [OutputType()] attributes to internal
        # helper functions is good practice for module authors (improves
        # tab-completion and discoverability), but it's noise on the kind
        # of script-internal helpers used here. Real public-facing scripts
        # (those a user invokes) DO declare outputs via the result objects
        # they return. Re-enable when refactoring helpers into a module.
        'PSUseOutputTypeCorrectly',

        # Informational only. Trailing whitespace doesn't change script
        # behavior. Modern editors strip it automatically on save when
        # configured to do so.
        'PSAvoidTrailingWhitespace'
    )

    Rules = @{
        # OTBS = "One True Brace Style" - opening brace on same line as control statement
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        # Enforce ShouldProcess on functions that declare it (the scripts use -WhatIf).
        # This catches the bug where a function calls $PSCmdlet.ShouldProcess() but
        # doesn't have SupportsShouldProcess in its [CmdletBinding()] - a real silent
        # bug where -WhatIf has no effect.
        PSShouldProcess = @{
            Enable = $true
        }
    }
}

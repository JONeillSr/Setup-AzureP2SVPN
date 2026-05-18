# Contributing to Setup-AzureP2SVPN

Thanks for your interest in improving this repo. Whether you're filing a bug, suggesting a feature, or sending a pull request, here's what to expect.

## Reporting bugs

Open an issue using the **Bug report** template. The template asks for:

- Exact command you ran
- Script output (or attached `.log` file)
- Environment details (PowerShell version, Az module version, region, etc.)

The more specific you can be, the faster issues get resolved. Azure platform behavior varies by region, subscription type, and tenant configuration — these details matter.

## Suggesting features

Open an issue using the **Feature request** template. Be explicit about the problem you're trying to solve, not just the solution. A clear problem statement makes it easier to spot when an existing capability already addresses your need, or when the "ideal" solution would create downstream complexity.

## Pull requests

PRs are welcome. Before submitting:

1. **Open an issue first for non-trivial changes.** This avoids wasted effort on changes that don't fit the project's scope.
2. **Run PSScriptAnalyzer locally** before pushing:
   ```powershell
   Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   ```
   The GitHub Actions workflow runs the same check on every PR.
3. **Test against a real Azure subscription** if your change touches the deployment flow. The scripts are infrastructure automation — they have to work end-to-end, not just parse correctly.
4. **Update CHANGELOG.md** under the `[Unreleased]` section with a brief description of your change.
5. **Bump the script version** in the `$ScriptVersion` variable and the `Version:` line of the comment header if your change is user-visible.

## Code style

The scripts deliberately favor clarity over cleverness:

- **Prose comments explain *why*, not *what*.** Anyone can read PowerShell; explain the reasoning behind non-obvious choices.
- **Function names follow `Verb-Noun` convention** using approved verbs (`Get-Verb` for the list).
- **Helper functions live above the main flow.** No anonymous script blocks for anything that has a name worth giving.
- **Errors throw early with actionable messages.** When the script fails, the error message should tell the user what to do, not just what went wrong.

## Scope

This repo covers **Azure Point-to-Site VPN Gateway provisioning with Entra ID authentication, plus the DNS infrastructure that makes VPN access actually useful**.

In scope:

- VPN Gateway provisioning, configuration, and teardown
- Private DNS Zone setup for split-horizon DNS over VPN
- Lightweight DNS forwarder VM to bridge VPN clients to Azure DNS
- Helper tooling around the above (e.g., VPN client config generation)

Out of scope:

- Site-to-Site (S2S) VPN configuration (different cmdlets, different concerns)
- ExpressRoute (entirely different service)
- VPN gateway operations beyond setup/teardown (use Az.Network directly)
- Workload deployment that happens to sit behind a VPN (use workload-specific tools)
- Tenant-level Entra ID configuration (use the Entra portal or Microsoft Graph SDK)
- Heavyweight DNS infrastructure (Azure DNS Private Resolver, AD-integrated DNS) — the lightweight dnsmasq forwarder pattern in this repo is sized for SMB scenarios where the gateway already exists; larger deployments should use Azure DNS Private Resolver

If you have a use case that's adjacent but distinct, consider a separate repo.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) that covers this project.

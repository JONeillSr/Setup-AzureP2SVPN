## Highlights

This release rounds out the **complete VPN access pattern** by adding two scripts that solve the DNS half of the puzzle. The P2S VPN gateway alone gives VPN-connected clients network reachability to private VNet resources, but they still resolve hostnames via their local ISP DNS — which doesn't know about your private resources. These two scripts close that gap.

## What's new

### `scripts/Add-AzureSplitHorizonDNS.ps1` (v1.0.0)

Provisions an Azure Private DNS Zone that mirrors an existing Public DNS Zone, links it to your VNet, and optionally smart-copies records from the public zone into the private zone.

- Creates the Private DNS Zone matching your public zone name
- Links it to your existing VNet (idempotent — reuses existing link if present)
- Adds explicit private records you specify via `-PrivateRecords @{ 'erpnext' = '10.0.2.4' }`
- Optional `-CopyPublicRecords` smart-copies public records with mail-DNS exclusion:
  - A/AAAA records copied (flagged when pointing to public IPs — likely override candidates)
  - CNAME records copied
  - MX, SPF, DKIM, DMARC records **skipped** (mail flow should stay via public DNS)
  - NS/SOA never copied (managed by Azure)

### `scripts/Add-AzureDNSForwarder.ps1` (v1.0.1)

Provisions a lightweight Ubuntu 24.04 VM running dnsmasq inside the VNet, configures the VNet's `DhcpOptions.DnsServers` to advertise the forwarder, and (after VPN profile regeneration) routes VPN client DNS queries through the forwarder.

- **VM size**: `Standard_B1s` (~$8/month — DNS forwarding is near-zero load)
- **Static private IP**: critical — the IP gets pushed via the VNet DNS setting
- **Hardened NSG**: port 53 from VNet + VPN client pool only; SSH from VNet only
- **cloud-init**: installs/configures dnsmasq, disables systemd-resolved's port-53 stub listener (Ubuntu 24.04 conflict), enables unattended security upgrades
- **Optional `-HighAvailability`** provisions two VMs for active/active redundancy

## Why this matters

Without these scripts, users had two unappealing choices for resolving internal hostnames over VPN:

- Memorize private IPs (works for one or two services, doesn't scale)
- Manually edit each VPN client's `azurevpnconfig.xml` (fragile, breaks on profile regen)

With split-horizon + forwarder, the public domain "just works" from both sides: customers see the public IP, VPN-connected staff see the internal IP, and you maintain a single source of truth in DNS.

## The architecture this enables end-to-end

```
Internet     → erpnext.example.com → Public IP (or NXDOMAIN if not exposed)

VPN client   → erpnext.example.com → forwarder VM → Azure DNS → Private Zone → 10.0.2.4
```

Same FQDN, different answer based on where the resolver is.

## Documentation

- **README.md**: extended script table, new "Complete VPN access pattern" section, full parameter tables for both new scripts
- **USER-GUIDE.md**: new "DNS for VPN clients" section (~150 lines) covering why the pattern is non-trivial, step-by-step setup, the `nslookup`-vs-`Resolve-DnsName` verification gotcha, DNS-specific troubleshooting

## Backwards compatibility

`Setup-AzureP2SVPN.ps1` and `Remove-AzureP2SVPN.ps1` are unchanged. Existing deployments work without these new scripts; users who want DNS for VPN clients can opt in by running the new scripts after the gateway is up.

## Full changelog

See [CHANGELOG.md](https://github.com/JONeillSr/Setup-AzureP2SVPN/blob/main/CHANGELOG.md#110---2026-05-18) for the detailed entry.

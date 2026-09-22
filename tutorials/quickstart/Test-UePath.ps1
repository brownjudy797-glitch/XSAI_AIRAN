[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InterfaceAlias,
    [ValidateRange(1, 20)]
    [int]$Count = 10
)
$ErrorActionPreference = 'Stop'
# Read-only adapter checks, followed by small ICMP probes. No resets or routes.
$adapters = @(Get-NetAdapter | Where-Object { $_.Name -eq $InterfaceAlias })
if ($adapters.Count -ne 1) { throw 'Expected exactly one matching adapter. Recheck Get-NetAdapter.' }
$adapter = $adapters[0]
if ($adapter.Status -ne 'Up') { throw 'UE adapter is not Up. Connect cellular service first.' }
$addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -match '^12\.1\.1\.(\d{1,3})$' -and
        [int]($_.IPAddress.Split('.')[-1]) -ge 2 -and
        [int]($_.IPAddress.Split('.')[-1]) -le 254 -and
        $_.AddressState -eq 'Preferred' })
if ($addresses.Count -ne 1) { throw 'Expected one preferred UE address in 12.1.1.2-254; do not fall back to Wi-Fi.' }
$ueAddress = $addresses[0].IPAddress
Write-Host "UE source: $ueAddress; target: 12.1.1.1; probes: $Count"
& ping.exe -4 -S $ueAddress -n $Count -w 2000 12.1.1.1
if ($LASTEXITCODE -ne 0) { throw 'Ping failed. Check UPF/tun0/N3 and record the output.' }
Write-Host 'Ping returned success. Review actual loss above; this is not a stability/throughput test.'

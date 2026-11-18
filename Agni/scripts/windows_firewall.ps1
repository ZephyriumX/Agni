<# Run ONCE in an *Administrator* PowerShell, only if you want the phone to reach the PC over Wi-Fi (not needed for USB mode).
   Opens inbound TCP 8000 on the PRIVATE profile only. Your Wi-Fi network must be set to "Private" in Windows settings. #>
New-NetFirewallRule -DisplayName 'Agni-Pulse API (dev)' -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
Get-NetConnectionProfile | Select-Object Name, NetworkCategory
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object InterfaceAlias, IPAddress

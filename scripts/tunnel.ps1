<#  Expose the API running on THIS PC to the internet over HTTPS without router/firewall changes.
    Uses a Cloudflare "quick tunnel" (no account). The URL changes every time you run it, and the PC must
    stay on. For an always-on server use the cloud deployment in docs/REMOTE_ACCESS.md instead.

      .\scripts\run_dev.ps1 -DatabaseUrl "postgresql://..."     # terminal 1: the API on port 8000
      .\scripts\tunnel.ps1                                      # terminal 2: prints https://<random>.trycloudflare.com
    Put the printed https URL in the app: Profile > Server.                                         #>
param([int]$Port = 8000)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
  Write-Host 'Installing cloudflared with winget...'
  winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
}
cloudflared tunnel --url "http://127.0.0.1:$Port"

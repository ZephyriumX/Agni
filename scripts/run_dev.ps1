<#  Windows dev launcher.  Usage (PowerShell, from the repo root):
      .\scripts\run_dev.ps1 -DatabaseUrl "postgresql://..."     # real database (Supabase or local Postgres)
      .\scripts\run_dev.ps1 -Memory                             # throw-away, data lost on exit
      .\scripts\run_dev.ps1 -DatabaseUrl "..." -Lan             # also listen on Wi-Fi (needs firewall rule)
    USB mode (recommended): phone plugged in with USB debugging -> `adb reverse` makes the phone's
    127.0.0.1:8000 reach this PC, so no Wi-Fi/firewall settings are involved.            #>
param([string]$DatabaseUrl = $env:DATABASE_URL, [switch]$Memory, [switch]$Lan, [int]$Port = 8000)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\backend')
if (-not (Test-Path .venv)) { python -m venv .venv }
& .\.venv\Scripts\python -m pip install -q -r requirements.txt
$env:AGNI_ENV = 'development'
if ($Memory) { $env:AGNI_STORAGE = 'memory' }
else {
  if (-not $DatabaseUrl) { throw 'Set -DatabaseUrl (or $env:DATABASE_URL). See .env.example. Use -Memory for a throw-away run.' }
  $env:DATABASE_URL = $DatabaseUrl
  & .\.venv\Scripts\python migrate.py
}
if (Get-Command adb -ErrorAction SilentlyContinue) { adb reverse tcp:$Port tcp:$Port | Out-Host } else { Write-Warning 'adb not found on PATH - USB mode unavailable' }
$bind = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' }
Write-Host "API on http://${bind}:$Port   (phone via USB: http://127.0.0.1:$Port)"
& .\.venv\Scripts\python -m uvicorn main:app --host $bind --port $Port

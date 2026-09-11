#!/usr/bin/env pwsh
# Starts the Arcanum Sync price-history service for the Arcanum Android app.
param(
    [int]$Port = 8787,
    [string]$Db = (Join-Path $PSScriptRoot 'prices\prices.db')
)
if (-not (Test-Path $Db)) {
    Write-Error "Price database not found at $Db. Run: python tool/slice_prices.py --dir tool/prices"
    exit 1
}
Write-Host "Starting Arcanum Sync on port $Port ..." -ForegroundColor Cyan
python (Join-Path $PSScriptRoot 'sync_server.py') --port $Port --db $Db

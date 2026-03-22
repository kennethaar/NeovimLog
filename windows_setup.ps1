# windows_setup.ps1 - First-time setup for NeovimLog on Windows
# Run once from PowerShell: .\windows_setup.ps1
# Requires: Neovim, Git, Python 3, pip installed and on PATH

param(
    [string]$VaultPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== NeovimLog Windows Setup ===" -ForegroundColor Cyan

# --- 1. Vault path ---
if (-not $VaultPath) {
    $VaultPath = Read-Host "Enter the full path to your Logseq vault (e.g. C:\Users\you\Documents\Notes)"
}
$VaultPath = $VaultPath.Trim().TrimEnd('\')
if (-not (Test-Path $VaultPath)) {
    Write-Host "Creating vault directory: $VaultPath"
    New-Item -ItemType Directory -Path $VaultPath | Out-Null
}

# --- 2. Store vault path (same mechanism as Linux/Termux) ---
$nvimDataDir = "$env:LOCALAPPDATA\nvim-data"
if (-not (Test-Path $nvimDataDir)) {
    New-Item -ItemType Directory -Path $nvimDataDir | Out-Null
}
$vaultFile = "$nvimDataDir\logseq_vault"
Set-Content -Path $vaultFile -Value $VaultPath -NoNewline
Write-Host "Vault path saved to: $vaultFile" -ForegroundColor Green

# --- 3. Symlink config dir to this repo ---
$nvimConfigDir = "$env:LOCALAPPDATA\nvim"
$repoDir = $PSScriptRoot
if (Test-Path $nvimConfigDir) {
    $existing = Get-Item $nvimConfigDir -Force
    if ($existing.LinkType -eq "SymbolicLink") {
        Write-Host "nvim config dir is already a symlink, skipping."
    } else {
        Write-Host "WARNING: $nvimConfigDir exists and is not a symlink." -ForegroundColor Yellow
        Write-Host "Rename or remove it manually, then re-run this script." -ForegroundColor Yellow
    }
} else {
    # Requires running PowerShell as Administrator or with Developer Mode enabled
    New-Item -ItemType SymbolicLink -Path $nvimConfigDir -Target $repoDir | Out-Null
    Write-Host "Symlinked $nvimConfigDir -> $repoDir" -ForegroundColor Green
}

# --- 4. Python dependencies ---
Write-Host "Installing Python dependencies..."
pip install pytz icalendar recurring-ical-events
Write-Host "Python dependencies installed." -ForegroundColor Green

# --- 5. Remind about local.lua ---
$localLua = "$repoDir\local.lua"
if (-not (Test-Path $localLua)) {
    Write-Host ""
    Write-Host "OPTIONAL: Create local.lua for machine-specific overrides (it is gitignored)." -ForegroundColor Yellow
    Write-Host "Example content:"
    Write-Host '  return { vault_path = "' + $VaultPath + '" }'
    Write-Host "  -- (vault_path is already saved to the vault file, local.lua is only needed"
    Write-Host "  --  if you want to override other settings on this machine)"
}

Write-Host ""
Write-Host "=== Setup complete. Launch nvim to get started. ===" -ForegroundColor Cyan

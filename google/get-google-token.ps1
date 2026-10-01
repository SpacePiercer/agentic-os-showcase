# get-google-token.ps1 — print a fresh access token (used by /morning-digest).
# Exits 1 with a hint if auth was never done; callers degrade gracefully.

$ErrorActionPreference = 'Stop'
$dir = "$env:USERPROFILE\.agentic-os"
if (-not (Test-Path "$dir\google-tokens.json")) {
    Write-Error 'Google not connected - run google-auth.ps1 (see SETUP.md)'
    exit 1
}
$client = (Get-Content "$dir\google-client.json" -Raw | ConvertFrom-Json).installed
$saved  = Get-Content "$dir\google-tokens.json" -Raw | ConvertFrom-Json
$tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
    refresh_token = $saved.refresh_token; client_id = $client.client_id
    client_secret = $client.client_secret; grant_type = 'refresh_token'
}
$tok.access_token

# google-auth.ps1 — ONE-TIME Google consent (Gmail/Calendar/Tasks, read-only).
# Prereq: OAuth "Desktop app" client JSON saved to %USERPROFILE%\.agentic-os\google-client.json
# (see SETUP.md). Stores refresh token in %USERPROFILE%\.agentic-os\google-tokens.json.

$ErrorActionPreference = 'Stop'
$dir = "$env:USERPROFILE\.agentic-os"
$client = (Get-Content "$dir\google-client.json" -Raw | ConvertFrom-Json).installed
$scopes = 'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/tasks.readonly'
$port = 8765
$redirect = "http://127.0.0.1:$port/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($redirect)
$listener.Start()

$authUrl = 'https://accounts.google.com/o/oauth2/v2/auth?client_id=' + $client.client_id +
    '&redirect_uri=' + [uri]::EscapeDataString($redirect) +
    '&response_type=code&access_type=offline&prompt=consent' +
    '&scope=' + [uri]::EscapeDataString($scopes)
Start-Process $authUrl
Write-Host 'Waiting for Google consent in the browser...'

$ctx = $listener.GetContext()
$code = $ctx.Request.QueryString['code']
$html = [Text.Encoding]::UTF8.GetBytes('<html><body>Done - you can close this tab.</body></html>')
$ctx.Response.OutputStream.Write($html, 0, $html.Length)
$ctx.Response.Close()
$listener.Stop()

$tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
    code = $code; client_id = $client.client_id; client_secret = $client.client_secret
    redirect_uri = $redirect; grant_type = 'authorization_code'
}
$tok | ConvertTo-Json | Out-File "$dir\google-tokens.json" -Encoding utf8
Write-Host "Tokens saved to $dir\google-tokens.json"

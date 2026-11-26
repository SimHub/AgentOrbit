# Creates a Windows Start Menu shortcut for AgentOrbit (searchable via Windows Search, no admin required).
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExePath = Join-Path $ScriptDir "agentorbit-app.exe"
$IconPath = Join-Path $ScriptDir "icon.ico"

if (-not (Test-Path $ExePath)) {
    Write-Error "agentorbit-app.exe not found in $ScriptDir"
    exit 1
}

$ProgramsDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $ProgramsDir "AgentOrbit.lnk"

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $ExePath
$Shortcut.WorkingDirectory = $ScriptDir
$Shortcut.Description = "AgentOrbit v2 - Live Desktop HUD for AI Coding Agents"
if (Test-Path $IconPath) {
    $Shortcut.IconLocation = $IconPath
}
$Shortcut.Save()

Write-Host "Registered Windows Start Menu shortcut: $ShortcutPath"
Write-Host "You can now launch AgentOrbit directly from Windows Search (Win -> AgentOrbit)."

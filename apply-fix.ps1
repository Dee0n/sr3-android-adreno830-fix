# Saints Row: The Third (Feral, Android) - graphics / performance fix.
# Patches the game's "preferences" registry file over adb. No root needed.
#
#   .\apply-fix.ps1                      apply the default profile (profiles\quality.json)
#   .\apply-fix.ps1 -Profile balanced    apply another profile from .\profiles
#   .\apply-fix.ps1 -Restore             put back the original preferences
#   .\apply-fix.ps1 -Adb C:\path\adb.exe use a specific adb binary
param(
    [string]$Adb = 'adb',
    [string]$Profile = 'quality',
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'
$pkg    = 'com.feralinteractive.saintsrow3_android'
$remote = "/sdcard/Android/data/$pkg/files/feral_app_support/preferences"
$bakDir = '/sdcard/sr3fix_backup'
$setup  = 'HKEY_CURRENT_USER\Software\Feral Interactive\Saints Row The Third\Setup'

function Invoke-Adb { $out = & $Adb @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "adb $($args -join ' ') failed: $out" }; $out }

$state = (& $Adb get-state 2>&1) -join ''
if ($state -ne 'device') { throw "No authorised device over adb (state: $state). Enable USB debugging and accept the prompt on the phone." }
if (-not ((Invoke-Adb shell "ls $remote 2>/dev/null") -join '')) { throw 'Game preferences not found. Install the game and start it once first.' }

Invoke-Adb shell "am force-stop $pkg" | Out-Null
Invoke-Adb shell "mkdir -p $bakDir" | Out-Null

if ($Restore) {
    if (-not ((Invoke-Adb shell "ls $bakDir/preferences.orig 2>/dev/null") -join '')) { throw "No backup at $bakDir/preferences.orig" }
    # Go through the PC (pull + push): a shell-side cp into Android/data right after
    # force-stop knocked the storage mount over on Android 16 during testing.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "sr3_preferences_orig_$PID.xml"
    Invoke-Adb pull "$bakDir/preferences.orig" $tmp | Out-Null
    Invoke-Adb push $tmp $remote | Out-Null
    Remove-Item $tmp
    'Original preferences restored.'
    return
}

$profilePath = Join-Path $PSScriptRoot "profiles\$Profile.json"
if (-not (Test-Path $profilePath)) { throw "Profile not found: $profilePath" }
$prof = Get-Content $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json

# Keep the very first copy as .orig, plus a timestamped copy of every later state.
Invoke-Adb shell "[ -f $bakDir/preferences.orig ] || cp $remote $bakDir/preferences.orig" | Out-Null
Invoke-Adb shell "cp $remote $bakDir/preferences.`$(date +%Y%m%d-%H%M%S)" | Out-Null

$tmp = Join-Path ([IO.Path]::GetTempPath()) "sr3_preferences_$PID.xml"
Invoke-Adb pull $remote $tmp | Out-Null

$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($tmp)

function Get-Key([string]$path) {
    $node = $xml.DocumentElement
    foreach ($part in ($path -split '\\')) {
        $next = $node.SelectSingleNode("key[@name='$part']")
        if (-not $next) {
            $next = $xml.CreateElement('key'); $next.SetAttribute('name', $part)
            [void]$node.AppendChild($next)
        }
        $node = $next
    }
    $node
}

$changed = 0
foreach ($section in $prof.values.PSObject.Properties) {
    # Section names are relative to ...\Setup unless they start with HKEY_
    $path = if ($section.Name -like 'HKEY_*') { $section.Name } elseif ($section.Name -eq '.') { $setup } else { "$setup\$($section.Name)" }
    $key = Get-Key $path
    foreach ($v in $section.Value.PSObject.Properties) {
        $type, $value = $v.Value.type, [string]$v.Value.value
        $node = $key.SelectSingleNode("value[@name='$($v.Name)']")
        if (-not $node) {
            $node = $xml.CreateElement('value'); $node.SetAttribute('name', $v.Name); $node.SetAttribute('type', $type)
            [void]$key.AppendChild($node)
        }
        if ($node.InnerText -ne $value) {
            '{0,-34} {1,-28} {2} -> {3}' -f ($section.Name -replace '^HKEY_CURRENT_USER\\Software\\', ''), $v.Name, $node.InnerText, $value
            $node.InnerText = $value; $changed++
        }
    }
}

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$settings.NewLineHandling = 'None'
$w = [System.Xml.XmlWriter]::Create($tmp, $settings); $xml.Save($w); $w.Close()

Invoke-Adb push $tmp $remote | Out-Null
Remove-Item $tmp
"Profile '$Profile' applied: $changed value(s) changed. Start the game."

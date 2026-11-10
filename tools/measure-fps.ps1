# Measures real frame pacing of Saints Row: The Third (Feral) through SurfaceFlinger.
# Usage: .\measure-fps.ps1 [-Adb path\to\adb.exe] [-Seconds 10] [-Touch]
#   -Touch  holds a slow camera swipe during the measurement, so the game's
#           framerate manager leaves its 30 fps idle mode.
param(
    [string]$Adb = 'adb',
    [int]$Seconds = 10,
    [switch]$Touch
)
$pkg = 'com.feralinteractive.saintsrow3_android'

$layer = (& $Adb shell "dumpsys SurfaceFlinger --list" |
    Where-Object { $_ -match "SurfaceView\[$pkg.*\(BLAST\)#\d+" } |
    ForEach-Object { [regex]::Match($_, "\w+ SurfaceView\[[^\]]+\]\(BLAST\)#\d+").Value } |
    Select-Object -First 1)
if (-not $layer) { Write-Error 'Game surface not found. Is the game in the foreground?'; exit 1 }

$job = $null
if ($Touch) {
    $ms = ($Seconds + 2) * 1000
    $job = Start-Process -FilePath $Adb -ArgumentList "shell input swipe 1440 300 1700 300 $ms" -NoNewWindow -PassThru
    Start-Sleep -Milliseconds 1500
}

$stamps = New-Object 'System.Collections.Generic.HashSet[long]'
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $rows = & $Adb shell "dumpsys SurfaceFlinger --latency '$layer'"
    foreach ($r in ($rows | Select-Object -Skip 1)) {
        $c = $r -split '\s+'
        if ($c.Count -ge 3) {
            $t = 0L
            if ([long]::TryParse($c[1], [ref]$t) -and $t -gt 0 -and $t -lt 9000000000000000000) { [void]$stamps.Add($t) }
        }
    }
    Start-Sleep -Milliseconds 700
}
if ($job) { $job.WaitForExit() }

$s = $stamps | Sort-Object
if ($s.Count -lt 10) { Write-Error "Too few frames captured ($($s.Count))"; exit 1 }
$d = for ($i = 1; $i -lt $s.Count; $i++) { ($s[$i] - $s[$i - 1]) / 1e6 }
$d = $d | Where-Object { $_ -lt 1000 }   # drop gaps between sampling windows
$sorted = $d | Sort-Object
$avg = ($d | Measure-Object -Average).Average
$p99 = $sorted[[int][math]::Floor($sorted.Count * 0.99) - 1]
'{0} frames | avg {1:N1} fps ({2:N2} ms) | 1% low {3:N1} fps ({4:N2} ms) | worst {5:N1} ms' -f `
    $d.Count, (1000 / $avg), $avg, (1000 / $p99), $p99, $sorted[-1]

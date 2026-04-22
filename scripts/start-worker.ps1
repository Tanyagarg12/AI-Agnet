Param(
    [int]$capacity = 1,
    [string]$dashboardUrl = ""
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
$envFile = Join-Path $projectDir ".env"

if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found at $envFile. Run ./scripts/setup.sh first or create .env manually."
    exit 1
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^[\s#]' -or $_ -match '^[\s]*$') { return }
    $parts = $_ -split '=', 2
    if ($parts.Count -eq 2) {
        $name = $parts[0].Trim()
        $value = $parts[1].Trim('"').Trim()
        Set-Item -Path env:$name -Value $value
    }
}

if (-not $dashboardUrl) {
    $dashboardUrl = $env:DASHBOARD_URL
}

if (-not $dashboardUrl) {
    $dashboardUrl = 'http://localhost:3459'
}

$dashboardUrl = $dashboardUrl.TrimEnd('/')
if ($dashboardUrl -like 'http://*') {
    $dashboardUrl = $dashboardUrl -replace '^http://', 'ws://'
} elseif ($dashboardUrl -like 'https://*') {
    $dashboardUrl = $dashboardUrl -replace '^https://', 'wss://'
} elseif ($dashboardUrl -notmatch '^ws://|^wss://') {
    $dashboardUrl = "ws://$dashboardUrl"
}
if ($dashboardUrl -notmatch '/ws$') {
    $dashboardUrl = "$dashboardUrl/ws"
}

if (-not $env:WORKER_SECRET) {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    Add-Content -Path $envFile -Value ""
    Add-Content -Path $envFile -Value "# Worker Secret (auto-generated)"
    Add-Content -Path $envFile -Value "WORKER_SECRET=$secret"
    Set-Item -Path env:WORKER_SECRET -Value $secret
    Write-Host "Generated WORKER_SECRET and saved it to .env"
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "Node.js is required to run the worker. Install Node.js or add it to PATH."
    exit 1
}

$logFile = Join-Path $projectDir "worker.log"
$pidFile = Join-Path $projectDir "worker.pid"

if (Test-Path $pidFile) {
    try {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
            Write-Host "Stopping existing worker process $oldPid..."
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # ignore
    }
}

$arguments = @('scripts\worker.js', '--dashboard', $dashboardUrl, '--capacity', $capacity.ToString())
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'node'
$startInfo.Arguments = $arguments -join ' '
$startInfo.WorkingDirectory = $projectDir
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true

$process = [System.Diagnostics.Process]::Start($startInfo)
if (-not $process) {
    Write-Error "Failed to start worker process."
    exit 1
}

$process.Id | Out-File -FilePath $pidFile -Encoding ascii
Write-Host "Worker daemon started (PID $($process.Id))"
Write-Host "Dashboard WS: $dashboardUrl"
Write-Host "Capacity: $capacity"
Write-Host "Log: $logFile"
Write-Host "PID file: $pidFile"

# Redirect output asynchronously
$stdout = $process.StandardOutput
$stderr = $process.StandardError
Start-Job -ScriptBlock {
    param($s, $log)
    while (-not $s.EndOfStream) {
        $line = $s.ReadLine()
        if ($line) { Add-Content -Path $log -Value $line }
    }
} -ArgumentList $stdout, $logFile | Out-Null
Start-Job -ScriptBlock {
    param($s, $log)
    while (-not $s.EndOfStream) {
        $line = $s.ReadLine()
        if ($line) { Add-Content -Path $log -Value $line }
    }
} -ArgumentList $stderr, $logFile | Out-Null

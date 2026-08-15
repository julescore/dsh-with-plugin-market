$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$desktopDir = Join-Path $root 'apps/desktop'
$outDir = Join-Path $root '.artifacts/windows'
$version = node --import tsx/esm (Join-Path $desktopDir 'scripts/version.ts') show version
$buildNumber = node --import tsx/esm (Join-Path $desktopDir 'scripts/version.ts') show build
$installer = Join-Path $outDir "DeepSeek-Harness-$version-windows-x64-setup.exe"
$testRoot = Join-Path $env:RUNNER_TEMP 'dsh-test'
$installDir = Join-Path $testRoot 'i'
$freshHome = Join-Path $testRoot 'fresh'
$conflictHome = Join-Path $testRoot 'conflict'
$selfTest = Join-Path $testRoot 'self-test.json'
$stdout = Join-Path $testRoot 'stdout.log'
$stderr = Join-Path $testRoot 'stderr.log'
$installerLog = Join-Path $testRoot 'installer.log'
$hostProcess = $null

function Stop-Host {
    if ($null -eq $script:hostProcess) { return }
    if (-not $script:hostProcess.HasExited) {
        & taskkill.exe /PID $script:hostProcess.Id /T /F | Out-Null
        $script:hostProcess.WaitForExit(10000) | Out-Null
    }
    $script:hostProcess = $null
}

function Start-Host([string]$DshHome, [string[]]$ExtraArguments) {
    Set-Content -Encoding utf8NoBOM $stdout ''
    Set-Content -Encoding utf8NoBOM $stderr ''
    $oldDshHome = $env:DSH_HOME
    try {
        $env:DSH_HOME = $DshHome
        $arguments = @($launcher, 'web') + $ExtraArguments + @('--port', '0')
        $argumentLine = ($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
        $script:hostProcess = Start-Process -FilePath $node -ArgumentList $argumentLine -WorkingDirectory $env:USERPROFILE `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    } finally {
        $env:DSH_HOME = $oldDshHome
    }
    $url = $null
    for ($attempt = 0; $attempt -lt 600; $attempt++) {
        if ($script:hostProcess.HasExited) {
            throw "Windows verify: embedded Host exited before readiness.`n$(Get-Content -Raw $stderr)"
        }
        $line = Get-Content $stdout -ErrorAction SilentlyContinue | Where-Object { $_ -match '^dsh web: (http://127\.0\.0\.1:\d+)' } | Select-Object -Last 1
        if ($line -and $line -match '^dsh web: (http://127\.0\.0\.1:\d+)') { $url = $Matches[1]; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $url) { throw "Windows verify: embedded Host did not become ready.`n$(Get-Content -Raw $stderr)" }
    return $url
}

function Invoke-MarketJson([string]$Method, [string]$Url, [hashtable]$Body = @{}) {
    $parameters = @{
        Method = $Method
        Uri = $Url
        Headers = @{ Origin = ($Url -replace '/dsh-market/.*$', '') }
        TimeoutSec = 300
    }
    if ($Method -ne 'GET') {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ($Body | ConvertTo-Json -Compress)
    }
    return Invoke-RestMethod @parameters
}

try {
    if (-not (Test-Path $installer)) { throw "Windows verify: missing $installer" }
    New-Item -ItemType Directory -Force -Path $testRoot, $installDir, $freshHome, $conflictHome | Out-Null
    $install = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$installDir", "/LOG=$installerLog") -PassThru -Wait
    if ($install.ExitCode -ne 0) {
        $detail = if (Test-Path $installerLog) { Get-Content -Raw $installerLog } else { 'installer log was not created' }
        throw "Windows verify: installer exited with $($install.ExitCode)`n$detail"
    }

    $app = Join-Path $installDir 'DeepSeek Harness.exe'
    $node = Join-Path $installDir 'node/node.exe'
    $pnpm = Join-Path $installDir 'node/pnpm.cmd'
    $launcher = Join-Path $installDir 'runtime/lib/bin.js'
    $marketPatch = Join-Path $installDir 'desktop/market.patch.yml'
    $marketConflictPatch = Join-Path $installDir 'desktop/market-conflict.patch.yml'
    foreach ($path in @($app, $node, $pnpm, $launcher, $marketPatch, $marketConflictPatch)) {
        if (-not (Test-Path $path)) { throw "Windows verify: installed resource is missing: $path" }
    }
    $bundledBin = Split-Path -Parent $node
    $env:PATH = "$bundledBin;$env:PATH"

    $selfTestProcess = Start-Process -FilePath $app -ArgumentList @('--self-test', $selfTest) -PassThru -Wait
    if ($selfTestProcess.ExitCode -ne 0) { throw 'Windows verify: shell self-test failed' }
    $self = Get-Content -Raw $selfTest | ConvertFrom-Json
    if ($self.product -ne 'DeepSeek Harness' -or -not $self.node -or -not $self.launcher -or -not $self.marketPatch -or -not $self.marketConflictPatch -or -not $self.conflictParser) {
        throw "Windows verify: shell self-test returned unexpected data: $(Get-Content -Raw $selfTest)"
    }
    if ((& $node --version) -ne 'v24.19.0') { throw 'Windows verify: bundled Node version is unexpected' }
    if ((& $pnpm --version) -ne '11.7.0') { throw 'Windows verify: bundled pnpm version is unexpected' }

    $env:DSH_HOME = $freshHome
    $dump = & $node $launcher web --patch $marketPatch --dump-config
    if (@($dump | Select-String -SimpleMatch '- id: dsh-market').Count -ne 1) { throw 'Windows verify: packaged market patch is absent' }
    if (@($dump | Select-String -SimpleMatch 'name: dshmarket-bundled').Count -ne 1) { throw 'Windows verify: packaged market alias is absent' }
    $url = Start-Host $freshHome @('--patch', $marketPatch)
    $registry = Invoke-MarketJson GET "$url/dsh-market/registry"
    if ($null -eq $registry) { throw 'Windows verify: plugin registry returned no data' }
    $installResult = Invoke-MarketJson POST "$url/dsh-market/install" @{ url = 'https://github.com/zhu1090093659/dsh-web-ui/tree/main/packages/dsh-web-ui-all' }
    if ($installResult.ok -ne $true) { throw "Windows verify: dsh-web-ui installation failed: $($installResult | ConvertTo-Json -Depth 10 -Compress)" }
    $installedManifest = Join-Path $freshHome 'profiles/web/node_modules/@linxin666/dsh-web-ui-all/package.json'
    if (-not (Test-Path $installedManifest)) { throw 'Windows verify: dsh-web-ui aggregate was not installed' }
    $uninstallResult = Invoke-MarketJson POST "$url/dsh-market/uninstall" @{ name = '@linxin666/dsh-web-ui-all' }
    if ($uninstallResult.ok -ne $true) { throw 'Windows verify: dsh-web-ui aggregate uninstall failed' }
    Stop-Host

    $env:DSH_HOME = $conflictHome
    & $node $launcher web --dump-config | Out-Null
    & $node $launcher plugin --profile web add 'dshmarket@1.1.0'
    $marketVersion = (& $node -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" (Join-Path $conflictHome 'profiles/web/node_modules/dshmarket/package.json'))
    if ($marketVersion -ne '1.1.0') { throw 'Windows verify: previous market fixture is not dshmarket@1.1.0' }
    $localDump = & $node $launcher web --dump-config
    if (@($localDump | Select-String -SimpleMatch '- id: dsh-market').Count -ne 1) { throw 'Windows verify: local market conflict fixture is absent' }
    $packagedDump = & $node $launcher web --patch $marketConflictPatch --dump-config
    if (@($packagedDump | Select-String -SimpleMatch '- id: dsh-market-packaged').Count -ne 1) { throw 'Windows verify: packaged conflict choice is absent' }
    if (@($packagedDump | Select-String -SimpleMatch 'name: dshmarket-bundled').Count -ne 1) { throw 'Windows verify: packaged conflict alias is absent' }

    $sha256 = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    Write-Output 'Windows verification passed'
    Write-Output "VERSION=$version"
    Write-Output "BUILD=$buildNumber"
    Write-Output 'PRODUCT=DeepSeek Harness'
    Write-Output 'MARKET=dshmarket@1.2.3'
    Write-Output 'MARKET_DSH_WEB_UI=@linxin666/dsh-web-ui-all'
    Write-Output 'MARKET_CONFLICT_CHOICES=local,bundled'
    Write-Output 'PNPM=11.7.0'
    Write-Output "INSTALLER=$installer"
    Write-Output "SHA256=$sha256"
} finally {
    Stop-Host
    Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue
    if (Test-Path $testRoot) { Remove-Item -Recurse -Force $testRoot }
}

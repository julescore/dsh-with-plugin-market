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
$recoveryHome = Join-Path $testRoot 'recovery'
$diagnosisHome = Join-Path $testRoot 'diagnosis'
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
        $arguments = @($launcher, 'web', '--patch', $visionPatch) + $ExtraArguments + @('--port', '0')
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

function Invoke-RpcJson([string]$BaseUrl, [string]$Method, [hashtable]$Payload, [string]$RpcId) {
    $body = @{
        type = 'client-request'
        rpcId = $RpcId
        method = $Method
        payload = $Payload
    } | ConvertTo-Json -Depth 10 -Compress
    return Invoke-RestMethod -Method POST -Uri "$BaseUrl/api/$Method" -Headers @{ Origin = $BaseUrl } `
        -ContentType 'application/json' -Body $body -TimeoutSec 30
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
    New-Item -ItemType Directory -Force -Path $testRoot, $installDir, $freshHome, $conflictHome, $recoveryHome, $diagnosisHome | Out-Null
    $install = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$installDir", "/LOG=$installerLog") -PassThru -Wait
    if ($install.ExitCode -ne 0) {
        $detail = if (Test-Path $installerLog) { Get-Content -Raw $installerLog } else { 'installer log was not created' }
        throw "Windows verify: installer exited with $($install.ExitCode)`n$detail"
    }

    $app = Join-Path $installDir 'DeepSeek Harness.exe'
    $node = Join-Path $installDir 'node/node.exe'
    $pnpm = Join-Path $installDir 'node/pnpm.cmd'
    $launcher = Join-Path $installDir 'runtime/lib/bin.js'
    $visionPatch = Join-Path $installDir 'desktop/vision.patch.yml'
    $marketPatch = Join-Path $installDir 'desktop/market.patch.yml'
    $marketConflictPatch = Join-Path $installDir 'desktop/market-conflict.patch.yml'
    $recoveryScript = Join-Path $installDir 'desktop/reset-web-profile.mjs'
    $diagnosisScript = Join-Path $installDir 'desktop/diagnose-web-plugins.mjs'
    $visionPackage = Join-Path $installDir 'runtime/node_modules/dsh-vision-image-model-bundled/package.json'
    foreach ($path in @($app, $node, $pnpm, $launcher, $visionPatch, $visionPackage, $marketPatch, $marketConflictPatch, $recoveryScript, $diagnosisScript)) {
        if (-not (Test-Path $path)) { throw "Windows verify: installed resource is missing: $path" }
    }
    $bundledBin = Split-Path -Parent $node
    $env:PATH = "$bundledBin;$env:PATH"

    $selfTestProcess = Start-Process -FilePath $app -ArgumentList @('--self-test', $selfTest) -PassThru -Wait
    if ($selfTestProcess.ExitCode -ne 0) { throw 'Windows verify: shell self-test failed' }
    $self = Get-Content -Raw $selfTest | ConvertFrom-Json
    if ($self.product -ne 'DeepSeek Harness' -or -not $self.node -or -not $self.launcher -or -not $self.marketPatch -or -not $self.marketConflictPatch -or -not $self.recoveryScript -or -not $self.diagnosisScript -or -not $self.conflictParser) {
        throw "Windows verify: shell self-test returned unexpected data: $(Get-Content -Raw $selfTest)"
    }
    if ((& $node --version) -ne 'v24.19.0') { throw 'Windows verify: bundled Node version is unexpected' }
    if ((& $pnpm --version) -ne '11.7.0') { throw 'Windows verify: bundled pnpm version is unexpected' }
    & $node (Join-Path $desktopDir 'scripts/verify-agent-presets.mjs') (Join-Path $installDir 'runtime/config/agent-presets')

    # The installed recovery tool moves only the mutable Web profile and preserves user data.
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $recoveryHome 'profiles/web'), `
        (Join-Path $recoveryHome 'storages'), `
        (Join-Path $recoveryHome '.agent-presets/mine') | Out-Null
    Set-Content -Encoding utf8NoBOM (Join-Path $recoveryHome 'profiles/web/package.json') '{"broken":true}'
    Set-Content -Encoding utf8NoBOM (Join-Path $recoveryHome 'settings.yaml') 'kept: true'
    Set-Content -Encoding utf8NoBOM (Join-Path $recoveryHome 'storages/sessions.json') 'kept'
    Set-Content -Encoding utf8NoBOM (Join-Path $recoveryHome '.agent-presets/mine/agent.cordis.yml') 'kept'
    $env:DSH_HOME = $recoveryHome
    $recovery = (& $node $recoveryScript | ConvertFrom-Json)
    if ($recovery.changed -ne $true -or (Test-Path (Join-Path $recoveryHome 'profiles/web'))) {
        throw "Windows verify: installed recovery did not move the Web profile: $($recovery | ConvertTo-Json -Compress)"
    }
    $backup = [string]$recovery.backup
    if (-not $backup.StartsWith((Join-Path $recoveryHome 'profile-backups')) -or -not (Test-Path (Join-Path $backup 'package.json'))) {
        throw "Windows verify: installed recovery backup is invalid: $($recovery | ConvertTo-Json -Compress)"
    }
    foreach ($path in @(
        (Join-Path $recoveryHome 'settings.yaml'),
        (Join-Path $recoveryHome 'storages/sessions.json'),
        (Join-Path $recoveryHome '.agent-presets/mine/agent.cordis.yml')
    )) {
        if (-not (Test-Path $path)) { throw "Windows verify: installed recovery removed preserved data: $path" }
    }

    # The installed diagnosis names only the profile dependency implicated by a structured startup failure.
    New-Item -ItemType Directory -Force -Path (Join-Path $diagnosisHome 'profiles/web') | Out-Null
    Set-Content -Encoding utf8NoBOM (Join-Path $diagnosisHome 'profiles/web/package.json') `
        '{"name":"dsh-profile-web","dependencies":{"@scope/broken":"npm:real-broken@1.0.0","healthy":"^1.0.0"}}'
    $env:DSH_HOME = $diagnosisHome
    $diagnosisOutput = ('dsh: plugin(s) failed to load: @scope/broken; Cordis startup failed' | & $node $diagnosisScript) -join "`n"
    $diagnosis = $diagnosisOutput | ConvertFrom-Json
    if ($diagnosis.profileExists -ne $true -or $diagnosis.manifestValid -ne $true) {
        throw "Windows verify: installed diagnosis did not read the Web profile: $diagnosisOutput"
    }
    if (@($diagnosis.candidates).Count -ne 1 -or $diagnosis.candidates[0].name -ne '@scope/broken' -or $diagnosis.candidates[0].signals[0] -ne 'failed load entry') {
        throw "Windows verify: installed diagnosis did not name the failing plugin: $diagnosisOutput"
    }

    $env:DSH_HOME = $freshHome
    $dump = & $node $launcher web --patch $visionPatch --patch $marketPatch --dump-config
    if (@($dump | Select-String -SimpleMatch '- id: dsh-market').Count -ne 1) { throw 'Windows verify: packaged market patch is absent' }
    if (@($dump | Select-String -SimpleMatch 'name: dshmarket-bundled').Count -ne 1) { throw 'Windows verify: packaged market alias is absent' }
    if (@($dump | Select-String -SimpleMatch '- id: vision-image-model-packaged').Count -ne 1) { throw 'Windows verify: packaged vision row is absent' }
    if (@($dump | Select-String -SimpleMatch 'name: dsh-vision-image-model-bundled').Count -ne 1) { throw 'Windows verify: packaged vision alias is absent' }
    $url = Start-Host $freshHome @('--patch', $marketPatch)
    $visionConfig = Invoke-RestMethod -Method GET -Uri "$url/vision-image-model/config" -TimeoutSec 30
    if ($visionConfig.ok -ne $true -or $visionConfig.current.provider -ne '' -or $visionConfig.current.model -ne '' -or $null -eq $visionConfig.candidates) {
        throw "Windows verify: bundled vision config route is invalid: $($visionConfig | ConvertTo-Json -Depth 10 -Compress)"
    }
    $index = Invoke-WebRequest -UseBasicParsing -Uri "$url/" -TimeoutSec 30
    if (-not $index.Content.Contains('"id":"dsh-vision-image-model-bundled"')) { throw 'Windows verify: bundled vision settings client is absent from the Web boot graph' }
    node (Join-Path $desktopDir 'scripts/verify-vision-client.mjs') (Join-Path $installDir 'runtime/node_modules/dsh-vision-image-model-bundled/dsh/client.js') 'dsh-vision-image-model-bundled'
    if ($LASTEXITCODE -ne 0) { throw 'Windows verify: bundled vision client module registration is invalid' }
    $visionSource = Get-Content -Raw (Join-Path $installDir 'runtime/node_modules/dsh-vision-image-model-bundled/dsh/index.js')
    if (-not $visionSource.Contains("const DEFAULT_TOOL_NAME = 'vision_read_image'")) { throw 'Windows verify: bundled vision tool declaration is absent' }
    $presetList = Invoke-RpcJson $url 'agentPreset.list' @{} 'desktop-preset-list'
    if ($presetList.result.ok -ne $true) { throw "Windows verify: agent preset list failed: $($presetList | ConvertTo-Json -Depth 10 -Compress)" }
    $presetEntries = @{}
    foreach ($entry in $presetList.result.value.presets) { $presetEntries[$entry.id] = $entry }
    $expectedPresets = @{
        'anchored-standard' = 'Anchored Standard (experimental)'
        'zero-anchored-standard' = 'Zero-Anchored Standard (experimental)'
    }
    foreach ($presetId in $expectedPresets.Keys) {
        $entry = $presetEntries[$presetId]
        if ($null -eq $entry -or $entry.name -ne $expectedPresets[$presetId] -or $entry.trust -ne 'system' -or ($entry.PSObject.Properties.Name -contains 'broken')) {
            throw "Windows verify: packaged preset is not selectable: $presetId"
        }
        $created = Invoke-RpcJson $url 'session.create' @{ sessionId = "desktop-$presetId"; agentPreset = $presetId } "desktop-create-$presetId"
        if ($created.result.ok -ne $true -or $created.result.value.agentPreset -ne $presetId) {
            throw "Windows verify: packaged preset mount failed: $($created | ConvertTo-Json -Depth 10 -Compress)"
        }
    }
    if ($presetEntries['standard'].isDefault -ne $true) { throw 'Windows verify: bundled community presets changed the default preset' }
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
    & $node $launcher web --patch $visionPatch --dump-config | Out-Null
    & $node $launcher plugin --profile web add 'dshmarket@1.1.0'
    $marketVersion = (& $node -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" (Join-Path $conflictHome 'profiles/web/node_modules/dshmarket/package.json'))
    if ($marketVersion -ne '1.1.0') { throw 'Windows verify: previous market fixture is not dshmarket@1.1.0' }
    $localDump = & $node $launcher web --patch $visionPatch --dump-config
    if (@($localDump | Select-String -SimpleMatch '- id: dsh-market').Count -ne 1) { throw 'Windows verify: local market conflict fixture is absent' }
    $packagedDump = & $node $launcher web --patch $visionPatch --patch $marketConflictPatch --dump-config
    if (@($packagedDump | Select-String -SimpleMatch '- id: dsh-market-packaged').Count -ne 1) { throw 'Windows verify: packaged conflict choice is absent' }
    if (@($packagedDump | Select-String -SimpleMatch 'name: dshmarket-bundled').Count -ne 1) { throw 'Windows verify: packaged conflict alias is absent' }

    $sha256 = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    Write-Output 'Windows verification passed'
    Write-Output "VERSION=$version"
    Write-Output "BUILD=$buildNumber"
    Write-Output 'PRODUCT=DeepSeek Harness'
    Write-Output 'MARKET=dshmarket@1.2.3'
    Write-Output 'MARKET_DSH_WEB_UI=@linxin666/dsh-web-ui-all'
    Write-Output 'PRESETS=anchored-standard,zero-anchored-standard'
    Write-Output 'VISION=dsh-vision-image-model-bundled'
    Write-Output 'MARKET_CONFLICT_CHOICES=local,bundled'
    Write-Output 'STARTUP_PLUGIN_DIAGNOSIS=structured'
    Write-Output 'PNPM=11.7.0'
    Write-Output "INSTALLER=$installer"
    Write-Output "SHA256=$sha256"
} finally {
    Stop-Host
    Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue
    if (Test-Path $testRoot) { Remove-Item -Recurse -Force $testRoot }
}

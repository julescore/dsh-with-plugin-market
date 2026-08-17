$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$windowsDir = Join-Path $root 'apps/windows'
$desktopDir = Join-Path $root 'apps/desktop'
$outDir = Join-Path $root '.artifacts/windows'
$cacheDir = Join-Path $root '.artifacts/toolchains'
$workRoot = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'dsh-win' } else { Join-Path $outDir 'work' }
$buildDir = Join-Path $workRoot 'app'
$runtime = Join-Path $workRoot 'runtime'
$nodeVersion = '24.19.0'
$nodeArchive = "node-v$nodeVersion-win-x64.zip"
$nodeSha256 = '57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73'
$pnpmVersion = '11.7.0'
$pnpmArchive = "pnpm-$pnpmVersion.tgz"
$pnpmSha256 = 'deafa7ec98a1218b6a047289b92fbe2395c1e22d3495bb711653013218ee15ee'
$marketVersion = '1.2.3'
$marketArchive = "dshmarket-$marketVersion.tgz"
$marketSha256 = '4824945d4d3966aca37b7cc71717e74b4ae0609ed731dd71b346e03576ab7ece'

New-Item -ItemType Directory -Force -Path $outDir, $cacheDir, $workRoot | Out-Null
function Get-VerifiedArchive([string]$Url, [string]$Path, [string]$Sha256) {
    if (-not (Test-Path $Path)) { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path }
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) { throw "Windows build: checksum mismatch for $Path" }
}

$nodeArchivePath = Join-Path $cacheDir $nodeArchive
Get-VerifiedArchive "https://nodejs.org/dist/v$nodeVersion/$nodeArchive" $nodeArchivePath $nodeSha256
$nodeRoot = Join-Path $cacheDir "node-v$nodeVersion-win-x64"
if (-not (Test-Path (Join-Path $nodeRoot 'node.exe'))) { Expand-Archive -Path $nodeArchivePath -DestinationPath $cacheDir -Force }

$pnpmArchivePath = Join-Path $cacheDir $pnpmArchive
Get-VerifiedArchive "https://registry.npmjs.org/pnpm/-/$pnpmArchive" $pnpmArchivePath $pnpmSha256
$pnpmRoot = Join-Path $cacheDir "pnpm-$pnpmVersion"
if (-not (Test-Path (Join-Path $pnpmRoot 'bin/pnpm.cjs'))) {
    if (Test-Path $pnpmRoot) { Remove-Item -Recurse -Force $pnpmRoot }
    New-Item -ItemType Directory -Force -Path $pnpmRoot | Out-Null
    tar -xzf $pnpmArchivePath --strip-components=1 -C $pnpmRoot
}

$marketArchivePath = Join-Path $cacheDir $marketArchive
Get-VerifiedArchive "https://registry.npmjs.org/dshmarket/-/$marketArchive" $marketArchivePath $marketSha256
$marketRoot = Join-Path $cacheDir "dshmarket-$marketVersion"
if (-not (Test-Path (Join-Path $marketRoot 'package.json'))) {
    if (Test-Path $marketRoot) { Remove-Item -Recurse -Force $marketRoot }
    New-Item -ItemType Directory -Force -Path $marketRoot | Out-Null
    tar -xzf $marketArchivePath --strip-components=1 -C $marketRoot
}

$env:PATH = "$nodeRoot;$env:PATH"
if ((node --version) -ne "v$nodeVersion") { throw "Windows build: expected Node v$nodeVersion" }
$versionScript = Join-Path $desktopDir 'scripts/version.ts'
$version = node --import tsx/esm $versionScript show version
$buildNumber = node --import tsx/esm $versionScript show build
$installer = Join-Path $outDir "DeepSeek-Harness-$version-windows-x64-setup.exe"

pnpm -C $root run build
foreach ($path in @($buildDir, $runtime, $installer)) { if (Test-Path $path) { Remove-Item -Recurse -Force $path } }
try {
    $env:CI = 'true'
    pnpm -C $root --filter '@deepseek-ai/dsh' deploy --legacy --prod `
        --config.node-linker=hoisted `
        --config.auto-install-peers=false `
        --config.link-workspace-packages=true `
        $runtime
} finally {
    pnpm -C $root install --frozen-lockfile
}

$manifestPath = Join-Path $runtime 'package.json'
$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -AsHashtable
$expectedMarket = "npm:dshmarket@$marketVersion"
if ($manifest.dependencies.ContainsKey('dshmarket-bundled') -and $manifest.dependencies['dshmarket-bundled'] -ne $expectedMarket) {
    throw "Windows build: runtime declares an unexpected bundled market alias"
}
$manifest.dependencies.Remove('dshmarket')
$manifest.dependencies['dshmarket-bundled'] = $expectedMarket
$manifest | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $manifestPath
python (Join-Path $desktopDir 'scripts/assemble-runtime.py') $runtime $root Windows
python (Join-Path $desktopDir 'scripts/install-agent-presets.py') $runtime $desktopDir Windows
python (Join-Path $desktopDir 'scripts/install-vision-plugin.py') $runtime (Join-Path $root 'vision-image-model') Windows
node (Join-Path $desktopDir 'scripts/verify-agent-presets.mjs') (Join-Path $runtime 'config/agent-presets')
node --check (Join-Path $runtime 'node_modules/dsh-vision-image-model-bundled/dsh/index.js')
node --check (Join-Path $runtime 'node_modules/dsh-vision-image-model-bundled/dsh/local-image.js')
node --check (Join-Path $runtime 'node_modules/dsh-vision-image-model-bundled/dsh/prompt-admission.js')
node (Join-Path $desktopDir 'scripts/verify-vision-client.mjs') (Join-Path $runtime 'node_modules/dsh-vision-image-model-bundled/dsh/client.js') 'dsh-vision-image-model-bundled'

$publishDir = Join-Path $workRoot 'shell'
dotnet publish (Join-Path $windowsDir 'src/DeepSeekHarness.csproj') -c Release -r win-x64 --self-contained true -o $publishDir
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Copy-Item -Recurse -Force (Join-Path $publishDir '*') $buildDir
Copy-Item -Recurse -Force $runtime (Join-Path $buildDir 'runtime')
Copy-Item -Recurse -Force $nodeRoot (Join-Path $buildDir 'node')
Copy-Item -Recurse -Force $pnpmRoot (Join-Path $buildDir 'pnpm')
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir 'desktop') | Out-Null
Copy-Item -Force (Join-Path $desktopDir 'resources/vision.patch.yml') (Join-Path $buildDir 'desktop/vision.patch.yml')
Copy-Item -Force (Join-Path $desktopDir 'resources/market.patch.yml') (Join-Path $buildDir 'desktop/market.patch.yml')
Copy-Item -Force (Join-Path $desktopDir 'resources/market-conflict.patch.yml') (Join-Path $buildDir 'desktop/market-conflict.patch.yml')
Copy-Item -Force (Join-Path $desktopDir 'scripts/reset-web-profile.mjs') (Join-Path $buildDir 'desktop/reset-web-profile.mjs')
Copy-Item -Force (Join-Path $desktopDir 'scripts/diagnose-web-plugins.mjs') (Join-Path $buildDir 'desktop/diagnose-web-plugins.mjs')
Copy-Item -Force (Join-Path $windowsDir 'resources/THIRD-PARTY-NOTICES.md') (Join-Path $buildDir 'THIRD-PARTY-NOTICES.md')

$pnpmCmd = @'
@echo off
"%~dp0node.exe" "%~dp0..\pnpm\bin\pnpm.cjs" %*
'@
Set-Content -Encoding ascii (Join-Path $buildDir 'node/pnpm.cmd') $pnpmCmd
$bundledMarket = Join-Path $buildDir 'runtime/node_modules/dshmarket-bundled'
New-Item -ItemType Directory -Force -Path $bundledMarket | Out-Null
Copy-Item -Recurse -Force (Join-Path $marketRoot '*') $bundledMarket
python (Join-Path $desktopDir 'scripts/patch-market.py') $bundledMarket (Join-Path $desktopDir 'resources/market-overrides.json')
node --check (Join-Path $bundledMarket 'lib/registry.js')
node --check (Join-Path $bundledMarket 'lib/routes.js')
node --check (Join-Path $bundledMarket 'client/client.js')

$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (Test-Path $candidate) { $iscc = $candidate }
}
if (-not $iscc) { throw 'Windows build: Inno Setup 6 compiler is required' }
$env:DSH_DESKTOP_VERSION = $version
$env:DSH_WINDOWS_BUILD_DIR = $buildDir
$env:DSH_WINDOWS_OUTPUT_DIR = $outDir
& $iscc (Join-Path $windowsDir 'resources/DeepSeekHarness.iss')
if (-not (Test-Path $installer)) { throw "Windows build: installer was not created at $installer" }
$sha256 = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
Write-Output "VERSION=$version"
Write-Output "BUILD=$buildNumber"
Write-Output "APP=$buildDir"
Write-Output "INSTALLER=$installer"
Write-Output "SHA256=$sha256"

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repo '.cache/releases'
$pocDir = Join-Path $repo 'poc'
$required = @(
    (Join-Path $pocDir 'install.sh'),
    (Join-Path $pocDir 'configure.sh'),
    (Join-Path $pocDir 'start.sh'),
    (Join-Path $pocDir 'direct-gateway.sh'),
    (Join-Path $pocDir 'tproxy-gateway.sh'),
    (Join-Path $pocDir 'routecraft-poc.init'),
    (Join-Path $pocDir 'policy.yaml')
)

foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required package file is missing: $path"
    }
}

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) {
    throw 'tar.exe is required to create .tar.gz bundles.'
}

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$targets = @(
    @{ Name = 'amd64'; GOARCH = 'amd64'; GOARM = '' },
    @{ Name = 'arm64'; GOARCH = 'arm64'; GOARM = '' },
    @{ Name = 'armv7'; GOARCH = 'arm'; GOARM = '7' }
)

$saved = @{
    GOOS = $env:GOOS
    GOARCH = $env:GOARCH
    GOARM = $env:GOARM
    CGO_ENABLED = $env:CGO_ENABLED
}

try {
    $env:GOOS = 'linux'
    $env:CGO_ENABLED = '0'
    foreach ($target in $targets) {
        $stage = Join-Path $releaseDir ".stage-$($target.Name)"
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin') | Out-Null
        $env:GOARCH = $target.GOARCH
        if ($target.GOARM) {
            $env:GOARM = $target.GOARM
        } else {
            Remove-Item Env:GOARM -ErrorAction SilentlyContinue
        }

        $binary = Join-Path $stage 'bin/routecraft-poc-build'
        & go build -trimpath -ldflags '-s -w' -o $binary ./poc/build
        if ($LASTEXITCODE -ne 0) {
            throw "Go cross-build failed for linux/$($target.Name)."
        }

        foreach ($path in $required) {
            Copy-Item -LiteralPath $path -Destination $stage -Force
        }
        [System.IO.File]::WriteAllText((Join-Path $stage 'TARGET_ARCH'), $target.Name, [System.Text.Encoding]::ASCII)

        $bundle = Join-Path $releaseDir "routecraft-poc-openwrt-$($target.Name).tar.gz"
        if (Test-Path -LiteralPath $bundle) {
            Remove-Item -LiteralPath $bundle -Force
        }
        & $tar.Source -czf $bundle -C $stage .
        if ($LASTEXITCODE -ne 0) {
            throw "Archive creation failed for $($target.Name)."
        }
        $hashOutput = & certutil.exe -hashfile $bundle SHA256
        if ($LASTEXITCODE -ne 0) {
            throw "SHA256 calculation failed for $($target.Name)."
        }
        $hash = $hashOutput | Where-Object { $_ -match '^[0-9a-fA-F]{64}$' } | Select-Object -First 1
        if (-not $hash) {
            throw "Could not parse SHA256 output for $($target.Name)."
        }
        $hash = $hash.ToLowerInvariant()
        Set-Content -LiteralPath "$bundle.sha256" -Value "$hash  $(Split-Path -Leaf $bundle)"
        Write-Output "Built $bundle ($hash)"
    }
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" $saved[$name]
        }
    }
}

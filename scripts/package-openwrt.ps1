$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$pocDir = Join-Path $repo 'poc'
$bundleDir = Join-Path $pocDir 'bundles'
$stageRoot = Join-Path $repo '.cache/package-openwrt'
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
    $tar = Get-Command tar -ErrorAction SilentlyContinue
}
if (-not $tar) {
    throw 'tar.exe is required to create .tar.gz bundles.'
}

New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
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
        $stage = Join-Path $stageRoot ".stage-$($target.Name)"
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
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
            $destination = Join-Path $stage (Split-Path -Leaf $path)
            if ($path.EndsWith('.sh') -or $path.EndsWith('.init')) {
                # A Windows checkout or git archive may have CRLF even when the
                # repository stores LF. OpenWrt /bin/sh requires Unix newlines.
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $output = [System.IO.MemoryStream]::new()
                try {
                    for ($i = 0; $i -lt $bytes.Length; $i++) {
                        if ($bytes[$i] -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
                        $output.WriteByte($bytes[$i])
                    }
                    [System.IO.File]::WriteAllBytes($destination, $output.ToArray())
                } finally {
                    $output.Dispose()
                }
            } else {
                Copy-Item -LiteralPath $path -Destination $destination -Force
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $stage 'TARGET_ARCH'), $target.Name, [System.Text.Encoding]::ASCII)

        $bundle = Join-Path $bundleDir "routecraft-poc-openwrt-$($target.Name).tar.gz"
        if (Test-Path -LiteralPath $bundle) {
            Remove-Item -LiteralPath $bundle -Force
        }
        & $tar.Source -czf $bundle -C $stage .
        if ($LASTEXITCODE -ne 0) {
            throw "Archive creation failed for $($target.Name)."
        }

        # Verify the actual archive, not a text-normalized comparison or only
        # the staging files. CRLF makes OpenWrt ash reject `set -eu`.
        $rootPath = [System.IO.Path]::GetFullPath($stageRoot).TrimEnd('\') + '\'
        $verifyPath = [System.IO.Path]::GetFullPath((Join-Path $stageRoot ('.verify-' + [guid]::NewGuid().ToString('N'))))
        if (-not $verifyPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Bundle verification directory is outside the staging root.'
        }
        New-Item -ItemType Directory -Path $verifyPath | Out-Null
        try {
            & $tar.Source -xzf $bundle -C $verifyPath
            if ($LASTEXITCODE -ne 0) {
                throw "Archive verification extraction failed for $($target.Name)."
            }
            foreach ($path in $required) {
                if ($path.EndsWith('.sh') -or $path.EndsWith('.init')) {
                    $scriptPath = Join-Path $verifyPath (Split-Path -Leaf $path)
                    $scriptBytes = [System.IO.File]::ReadAllBytes($scriptPath)
                    if ([Array]::IndexOf($scriptBytes, [byte]13) -ge 0) {
                        throw "Archive contains CR in $(Split-Path -Leaf $path) for $($target.Name)."
                    }
                }
            }
        } finally {
            Remove-Item -LiteralPath $verifyPath -Recurse -Force
        }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($bundle)
        try {
            $digest = $sha256.ComputeHash($stream)
            $hash = ([System.BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
            $sha256.Dispose()
        }
        $checksumLine = [System.Text.Encoding]::ASCII.GetBytes("$hash  $(Split-Path -Leaf $bundle)`n")
        [System.IO.File]::WriteAllBytes("$bundle.sha256", $checksumLine)
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

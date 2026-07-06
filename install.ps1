# install.ps1 — install the hcc HolyC compiler.
#
# By default it downloads a tagged GitHub release asset. When run from a checkout
# of the holyc repo (e.g. `.\install.ps1` from the repo root) and Zig is available,
# it builds hcc from source for your host instead.
#
# Usage:
#   irm https://raw.githubusercontent.com/project-solomon/holyc/main/install.ps1 | iex
#   .\install.ps1            # from a repo checkout → builds from source
#   .\install.ps1 -Lsp       # install ONLY the holyc-lsp language server
#   .\install.ps1 -Upgrade   # replace an existing installation
#
# -Lsp installs the language server INSTEAD of the compiler: holyc-lsp is
# driven by the front end alone, so it needs neither hcc nor LLVM (the LLVM
# check is skipped). Run the script once per binary to get both.
#
# An existing installation is left alone unless -Upgrade (or
# $env:HCC_UPGRADE = '1', for irm|iex use) is given. The install directory is
# added to the user PATH when missing.
#
# Environment overrides:
#   $env:HCC_VERSION       release tag to install            (default: latest)
#   $env:HCC_INSTALL_DIR   directory to install the binary
#                          (default: derived — elevated: %ProgramFiles%\hcc\bin
#                          on the machine PATH; else the per-user programs
#                          convention %LOCALAPPDATA%\Programs\hcc\bin on the
#                          user PATH)
#   $env:HCC_FROM_SOURCE   1 = build from source, 0 = download a release
#                          (default: auto — source iff run from a repo checkout with Zig)
#   $env:HCC_UPGRADE       1 = replace an existing installation (same as -Upgrade)
#   $env:HCC_LSP           1 = install only holyc-lsp (same as -Lsp)
#
# Downloads auto-detect the architecture and fetch the matching release asset
# `hcc-<version>-<arch>-windows.tar.gz` (the gzip-tar names release packaging
# produces). For Linux/macOS, use install.sh.

$ErrorActionPreference = 'Stop'
$Repo = 'project-solomon/holyc'
$Upgrade = ($env:HCC_UPGRADE -eq '1') -or ($args -contains '-Upgrade') -or ($args -contains '--upgrade')
$WithLsp = ($env:HCC_LSP -eq '1') -or ($args -contains '-Lsp') -or ($args -contains '--lsp')
$Bin = 'hcc'
# hcc by default; -Lsp swaps it for the language server (holyc-lsp needs
# neither hcc nor LLVM). Both follow the same skip/upgrade rules.
$Bins = if ($WithLsp) { @('holyc-lsp') } else { @($Bin) }

# ---- locate the repo, but only when run as a local file (not piped via irm) ----
# When piped (`irm ... | iex`), $PSScriptRoot is empty, so $RepoRoot stays empty
# and we fall through to the release download.
$RepoRoot = ''
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'build.zig'))) {
    $RepoRoot = $PSScriptRoot
}

# ---- decide download vs. build-from-source ----
$haveZig = [bool](Get-Command zig -ErrorAction SilentlyContinue)

# hcc links libLLVM dynamically: LLVM 21 must exist both to build from source
# and to RUN a downloaded release binary. Override the location with
# $env:HCC_LLVM_PREFIX, or skip with $env:HCC_SKIP_LLVM_CHECK = '1'.
function Test-Llvm {
    if ($env:HCC_SKIP_LLVM_CHECK -eq '1') { return }
    $prefix = $env:HCC_LLVM_PREFIX
    if (-not $prefix) {
        $cfg = Get-Command llvm-config -ErrorAction SilentlyContinue
        if ($cfg) { $prefix = (& llvm-config --prefix).Trim() }
    }
    if (-not $prefix) {
        $default = Join-Path $env:ProgramFiles 'LLVM'
        if (Test-Path (Join-Path $default 'bin')) { $prefix = $default }
    }
    if (-not $prefix -or -not (Test-Path $prefix)) {
        throw "install: hcc links LLVM dynamically and needs LLVM 21 at runtime, but none was found. Install LLVM 21 or set `$env:HCC_LLVM_PREFIX; set `$env:HCC_SKIP_LLVM_CHECK='1' to install anyway."
    }
}
$req = if ($env:HCC_FROM_SOURCE) { $env:HCC_FROM_SOURCE.ToLower() } else { '' }
if ($req -in @('1', 'true', 'yes', 'on')) {
    if (-not $RepoRoot) { throw "install: HCC_FROM_SOURCE is set, but this isn't a holyc repo checkout (run install.ps1 from the repo root)" }
    $fromSource = $true
} elseif ($req -in @('0', 'false', 'no', 'off')) {
    $fromSource = $false
} elseif ($req -eq '') {
    $fromSource = [bool]($RepoRoot -and $haveZig)
} else {
    throw "install: invalid HCC_FROM_SOURCE '$($env:HCC_FROM_SOURCE)' (use 1 or 0)"
}

# ---- install dir: HCC_INSTALL_DIR wins; otherwise derive it per platform ----
# Elevated → %ProgramFiles%\hcc\bin, registered on the machine PATH; otherwise
# the per-user programs convention %LOCALAPPDATA%\Programs\hcc\bin on the user
# PATH. An explicit HCC_INSTALL_DIR always goes on the user PATH.
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$dir = if ($env:HCC_INSTALL_DIR) {
    $env:HCC_INSTALL_DIR
} elseif ($IsElevated) {
    Join-Path $env:ProgramFiles 'hcc\bin'
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\hcc\bin'
}
$PathScope = if ($IsElevated -and -not $env:HCC_INSTALL_DIR) { 'Machine' } else { 'User' }

# ---- skip when already installed (unless -Upgrade) ----
if (-not $Upgrade) {
    $allPresent = $true
    foreach ($b in $Bins) {
        if (-not (Test-Path (Join-Path $dir "$b.exe"))) { $allPresent = $false }
    }
    if ($allPresent) {
        Write-Host "install: $($Bins -join ', ') already installed in $dir — nothing to do (use -Upgrade to replace)"
        exit 0
    }
}
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# ---- produce the binary in a temp dir (build from source or download) ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hcc-" + [System.Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # holyc-lsp never touches LLVM; only an hcc install needs the check.
    if (-not $WithLsp) { Test-Llvm }
    if ($fromSource) {
        if (-not $haveZig) { throw "install: building from source needs Zig 0.16 (https://ziglang.org/download/); or set `$env:HCC_FROM_SOURCE=0 to download a release" }
        Write-Host "install: building $($Bins -join ', ') from source ($RepoRoot)"
        Push-Location $RepoRoot
        try {
            # Per-artifact build steps, so an LSP-only install never links
            # (or requires) LLVM.
            $buildStep = if ($WithLsp) { 'lsp' } else { 'hcc' }
            & zig build $buildStep -Doptimize=ReleaseSafe
            if ($LASTEXITCODE -ne 0) { throw "install: zig build failed" }
            foreach ($b in $Bins) {
                $built = Join-Path 'zig-out/bin' "$b.exe"
                if (-not (Test-Path $built)) { throw "install: zig build did not produce $b" }
                Copy-Item $built (Join-Path $tmp "$b.exe")
            }
        } finally { Pop-Location }
    } else {
        # ---- detect architecture ----
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' { 'amd64' }
            'ARM64' { 'arm64' }
            default { throw "install: unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)'" }
        }

        # ---- resolve version (latest release tag unless pinned) ----
        $version = if ($env:HCC_VERSION) { $env:HCC_VERSION } else {
            try {
                (Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$Repo/releases/latest").tag_name
            } catch {
                throw "install: could not determine the latest release (set `$env:HCC_VERSION to a tag)"
            }
        }
        if (-not $version) { throw "install: could not determine the latest release (set `$env:HCC_VERSION to a tag)" }

        # Everything in $Bins was explicitly requested, so a missing asset is fatal.
        foreach ($b in $Bins) {
            $asset = "$b-$version-$arch-windows.tar.gz"
            $url = "https://github.com/$Repo/releases/download/$version/$asset"
            Write-Host "install: downloading $b $version (windows/$arch)"
            $archive = Join-Path $tmp $asset
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
            } catch {
                throw "install: download failed: $url"
            }
            # The release assets are gzip-tar on every platform; Windows 10 1803+ ships tar.exe.
            tar -xzf $archive -C $tmp
            if ($LASTEXITCODE -ne 0) { throw "install: failed to extract $asset" }
        }
        foreach ($b in $Bins) {
            $found = Get-ChildItem -Path $tmp -Recurse -Include $b, "$b.exe" | Select-Object -First 1
            if ($found -and ($found.Name -notlike '*.exe')) { Rename-Item $found.FullName "$b.exe" }
            if (-not (Get-ChildItem -Path $tmp -Recurse -Include "$b.exe" | Select-Object -First 1)) {
                throw "install: the archive did not contain a '$b' binary"
            }
        }
    }

    foreach ($b in $Bins) {
        $exe = Get-ChildItem -Path $tmp -Recurse -Include "$b.exe" | Select-Object -First 1
        if (-not $exe) { continue }
        $dest = Join-Path $dir "$b.exe"
        if ((Test-Path $dest) -and -not $Upgrade) {
            Write-Host "install: $b already exists in $dir — skipping (use -Upgrade to replace)"
            continue
        }
        Copy-Item -Path $exe.FullName -Destination $dest -Force
        Write-Host "install: installed $b to $dest"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ---- add to the PATH ($PathScope: machine when elevated, user otherwise) ----
$scopePath = [Environment]::GetEnvironmentVariable('Path', $PathScope)
if (($scopePath -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', "$scopePath;$dir", $PathScope)
    Write-Host "install: added $dir to the $($PathScope.ToLower()) PATH (restart your shell to pick it up)"
}
if ($WithLsp) {
    Write-Host "`nholyc-lsp speaks LSP over stdio — point your editor at it"
} else {
    Write-Host "`nRun: $Bin --help"
}

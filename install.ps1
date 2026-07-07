# install.ps1 — install the hcc HolyC compiler (or the holyc-lsp language server).
#
# From a repo checkout it builds from source with Zig; otherwise it downloads a
# tagged GitHub release. It verifies LLVM 21 is present (hcc links libLLVM
# dynamically) and adds the install directory to your PATH when missing.
#
# Usage:
#   .\install.ps1 [options]                # from a repo checkout → builds from source
#   irm <url>/install.ps1 | iex            # piped → downloads a release (no options)
#
# For options over a pipe, save and run the file, or:
#   & ([scriptblock]::Create((irm <url>/install.ps1))) -Lsp
#
# Options (run `.\install.ps1 -Help` for the full list):
#   -Lsp                install holyc-lsp instead of hcc (needs neither hcc nor LLVM)
#   -Upgrade            replace an existing installation
#   -FromSource         build from source; -Download fetches a release instead
#   -Version <tag>      release tag to download (default: latest)
#   -InstallDir <dir>   where to install
#   -LlvmPrefix <dir>   LLVM 21 install prefix (default: auto-detected)
#   -SkipLlvmCheck      install even if LLVM 21 is not found
#   -NoModifyPath       do not modify PATH; print a hint instead
#
# Downloads auto-detect the architecture and fetch the matching release asset
# `<bin>-<version>-<arch>-windows.tar.gz`. For Linux/macOS, use install.sh.

param(
    [switch]$Lsp,
    [switch]$Upgrade,
    [switch]$FromSource,
    [switch]$Download,
    [switch]$SkipLlvmCheck,
    [switch]$NoModifyPath,
    [string]$Version = 'latest',
    [string]$InstallDir,
    [string]$LlvmPrefix,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Repo = 'project-solomon/holyc'

function Show-Usage {
    @'
install.ps1 — install the hcc HolyC compiler (or the holyc-lsp language server).

From a repo checkout it builds from source with Zig; otherwise it downloads a
tagged GitHub release. The binary goes to a bin directory and is added to your
PATH; for hcc it also checks that LLVM 21 is present. An existing install is
left alone unless -Upgrade is given.

Usage:
  .\install.ps1 [options]
  irm https://raw.githubusercontent.com/project-solomon/holyc/main/install.ps1 | iex

Options:
  -Lsp               install holyc-lsp (the language server) instead of hcc
  -Upgrade           replace an existing installation
  -FromSource        build from source (needs a repo checkout and Zig)
  -Download          download a release instead of building from source
  -Version <tag>     release tag to download          (default: latest)
  -InstallDir <dir>  where to install                 (default: a per-user bin dir)
  -LlvmPrefix <dir>  LLVM 21 install prefix           (default: auto-detected)
  -SkipLlvmCheck     install even if LLVM 21 is not found
  -NoModifyPath      do not modify PATH; print a hint instead
  -Help              show this help

With neither -FromSource nor -Download, source is used iff run from a repo
checkout with Zig, else a release is downloaded.
'@ | Write-Host
}

if ($Help) {
    Show-Usage
    exit 0
}
if ($FromSource -and $Download) {
    throw "install: pass only one of -FromSource / -Download"
}

$Bin = 'hcc'
# hcc by default; -Lsp swaps it for the language server (holyc-lsp needs
# neither hcc nor LLVM). Both follow the same skip/upgrade rules.
$Bins = if ($Lsp) { @('holyc-lsp') } else { @($Bin) }

# ---- locate the repo, but only when run as a local file (not piped via irm) ----
# When piped (`irm ... | iex`), $PSScriptRoot is empty, so $RepoRoot stays empty
# and we fall through to the release download.
$RepoRoot = ''
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'build.zig'))) {
    $RepoRoot = $PSScriptRoot
}

$haveZig = [bool](Get-Command zig -ErrorAction SilentlyContinue)

# hcc links libLLVM dynamically: LLVM 21 must exist both to build from source
# and to RUN a downloaded release binary. Override the location with
# -LlvmPrefix, or skip with -SkipLlvmCheck.
function Test-Llvm {
    if ($SkipLlvmCheck) { return }
    $prefix = $LlvmPrefix
    if (-not $prefix) {
        $cfg = Get-Command llvm-config -ErrorAction SilentlyContinue
        if ($cfg) { $prefix = (& llvm-config --prefix).Trim() }
    }
    if (-not $prefix) {
        $default = Join-Path $env:ProgramFiles 'LLVM'
        if (Test-Path (Join-Path $default 'bin')) { $prefix = $default }
    }
    if (-not $prefix -or -not (Test-Path $prefix)) {
        throw "install: hcc links LLVM dynamically and needs LLVM 21 at runtime, but none was found. Install LLVM 21, point at it with -LlvmPrefix <dir>, or pass -SkipLlvmCheck to install anyway."
    }
}

# ---- decide download vs. build-from-source ----
if ($FromSource) {
    if (-not $RepoRoot) { throw "install: -FromSource needs a holyc repo checkout (run install.ps1 from the repo root)" }
    $fromSource = $true
} elseif ($Download) {
    $fromSource = $false
} else {
    $fromSource = [bool]($RepoRoot -and $haveZig)
}

# ---- install dir: -InstallDir wins; otherwise derive it per platform ----
# Elevated → %ProgramFiles%\hcc\bin, registered on the machine PATH; otherwise
# the per-user programs convention %LOCALAPPDATA%\Programs\hcc\bin on the user
# PATH. An explicit -InstallDir always goes on the user PATH.
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$dir = if ($InstallDir) {
    $InstallDir
} elseif ($IsElevated) {
    Join-Path $env:ProgramFiles 'hcc\bin'
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\hcc\bin'
}
$PathScope = if ($IsElevated -and -not $InstallDir) { 'Machine' } else { 'User' }

# ---- skip when already installed (unless -Upgrade) ----
if (-not $Upgrade) {
    $allPresent = $true
    foreach ($b in $Bins) {
        if (-not (Test-Path (Join-Path $dir "$b.exe"))) { $allPresent = $false }
    }
    # An hcc install also owns the stdlib at <root>\std; if the binary
    # is present but the stdlib isn't, there is still work to do.
    if ((-not $Lsp) -and -not (Test-Path (Join-Path (Split-Path $dir -Parent) 'std'))) { $allPresent = $false }
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
    if (-not $Lsp) { Test-Llvm }
    if ($fromSource) {
        if (-not $haveZig) { throw "install: building from source needs Zig 0.16 (https://ziglang.org/download/); or pass -Download to fetch a release" }
        Write-Host "install: building $($Bins -join ', ') from source ($RepoRoot)"
        Push-Location $RepoRoot
        try {
            # Per-artifact build steps, so an LSP-only install never links
            # (or requires) LLVM.
            $buildStep = if ($Lsp) { 'lsp' } else { 'hcc' }
            if ($LlvmPrefix) {
                & zig build $buildStep -Doptimize=ReleaseSafe "-Dllvm-prefix=$LlvmPrefix"
            } else {
                & zig build $buildStep -Doptimize=ReleaseSafe
            }
            if ($LASTEXITCODE -ne 0) { throw "install: zig build failed" }
            foreach ($b in $Bins) {
                $built = Join-Path 'zig-out/bin' "$b.exe"
                if (-not (Test-Path $built)) { throw "install: zig build did not produce $b" }
                Copy-Item $built (Join-Path $tmp "$b.exe")
            }
            # Stage the standard-library source tree beside the staged binary,
            # so the install step below places it at <root>\std.
            if (-not $Lsp) { Copy-Item -Recurse -Force (Join-Path $RepoRoot 'std') (Join-Path $tmp 'std') }
        } finally { Pop-Location }
    } else {
        # ---- detect architecture ----
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' { 'amd64' }
            'ARM64' { 'arm64' }
            default { throw "install: unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)'" }
        }

        # ---- resolve version (latest release tag unless pinned with -Version) ----
        $version = $Version
        if ($version -eq 'latest') {
            try {
                $version = (Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$Repo/releases/latest").tag_name
            } catch {
                throw "install: could not determine the latest release (pass -Version <tag>)"
            }
        }
        if (-not $version) { throw "install: could not determine the latest release (pass -Version <tag>)" }

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

    # ---- install the standard library beside the hcc binary (not for -Lsp) ----
    # hcc discovers it as HCC_ROOT\std relative to its own path — <root>\std,
    # where <prefix> is the parent of the bin dir. In download mode this expects
    # the release tarball to carry a top-level std\ dir (a new asset convention);
    # older tarballs without it simply skip the stdlib.
    $stdSrc = Join-Path $tmp 'std'
    if ((-not $Lsp) -and (Test-Path $stdSrc)) {
        $stdDir = Join-Path (Split-Path $dir -Parent) 'std'
        New-Item -ItemType Directory -Force -Path $stdDir | Out-Null
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stdDir '*.HC')
        Copy-Item -Path (Join-Path $stdSrc '*.HC') -Destination $stdDir -Force
        Write-Host "install: installed the standard library to $stdDir"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ---- add to the PATH ($PathScope: machine when elevated, user otherwise) ----
$scopePath = [Environment]::GetEnvironmentVariable('Path', $PathScope)
if (($scopePath -split ';') -notcontains $dir) {
    if ($NoModifyPath) {
        Write-Host "install: add $dir to your PATH (not modified: -NoModifyPath)"
    } else {
        [Environment]::SetEnvironmentVariable('Path', "$scopePath;$dir", $PathScope)
        Write-Host "install: added $dir to the $($PathScope.ToLower()) PATH (restart your shell to pick it up)"
    }
}
if ($Lsp) {
    Write-Host "`nholyc-lsp speaks LSP over stdio — point your editor at it"
} else {
    Write-Host "`nRun: $Bin --help"
}

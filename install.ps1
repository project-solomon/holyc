# install.ps1 — install the hcc HolyC compiler and/or the holyc-lsp language server.
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
#   -Lsp                also install holyc-lsp (the language server)
#   -LspOnly            install only holyc-lsp (needs neither hcc nor LLVM)
#   -Uninstall          remove the selected component(s)
#   -Upgrade            replace an existing installation
#   -Build              build from source; -Download fetches a release instead
#   -Version <tag>      release tag to download (default: latest)
#   -InstallDir <dir>   where to install
#   -LlvmPrefix <dir>   LLVM 21 install prefix (default: auto-detected)
#   -SkipLlvmCheck      install even if LLVM 21 is not found
#   -NoModifyPath       do not modify PATH; print a hint instead
#   -DryRun             show what would happen, make no changes
#
# Downloads auto-detect the architecture and fetch the matching release asset
# `<bin>-<version>-<arch>-windows.tar.gz`. For Linux/macOS, use install.sh.

param(
    [switch]$Lsp,
    [switch]$LspOnly,
    [switch]$Uninstall,
    [switch]$Upgrade,
    [switch]$Build,
    [switch]$FromSource, # back-compat alias for -Build
    [switch]$Download,
    [switch]$SkipLlvmCheck,
    [switch]$NoModifyPath,
    [switch]$DryRun,
    [string]$Version = 'latest',
    [string]$InstallDir,
    [string]$LlvmPrefix,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Repo = 'project-solomon/holyc'
$doBuild = $Build -or $FromSource

function Show-Usage {
    @'
install.ps1 — install the hcc HolyC compiler and/or the holyc-lsp language server.

From a repo checkout it builds from source with Zig; otherwise it downloads a
tagged GitHub release. Binaries go to a bin directory added to your PATH; for hcc
it also checks that LLVM 21 is present. An existing install is left alone unless
-Upgrade is given.

Usage:
  .\install.ps1 [options]
  irm https://raw.githubusercontent.com/project-solomon/holyc/main/install.ps1 | iex

Components (default: hcc):
  -Lsp               also install holyc-lsp (the language server)
  -LspOnly           install only holyc-lsp (needs neither hcc nor LLVM)

Options:
  -Uninstall         remove the selected component(s)
  -Upgrade           replace an existing installation
  -Build             build from source (needs a repo checkout and Zig)
  -Download          download a release instead of building from source
  -Version <tag>     release tag to download          (default: latest)
  -InstallDir <dir>  where to install                 (default: a per-user bin dir)
  -LlvmPrefix <dir>  LLVM 21 install prefix           (default: auto-detected)
  -SkipLlvmCheck     install even if LLVM 21 is not found
  -NoModifyPath      do not modify PATH; print a hint instead
  -DryRun            show what would happen, make no changes
  -Help              show this help

With neither -Build nor -Download, source is used iff run from a repo checkout
with Zig, else a release is downloaded.
'@ | Write-Host
}

if ($Help) {
    Show-Usage
    exit 0
}
if ($doBuild -and $Download) {
    throw "install: pass only one of -Build / -Download"
}

# ---- component set: hcc by default; -Lsp adds holyc-lsp; -LspOnly swaps to just
# the server (holyc-lsp needs neither hcc nor LLVM). ----
$Bins = if ($LspOnly) { @('holyc-lsp') } elseif ($Lsp) { @('hcc', 'holyc-lsp') } else { @('hcc') }
$WantsHcc = $Bins -contains 'hcc'

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
if ($doBuild) {
    if (-not $RepoRoot) { throw "install: -Build needs a holyc repo checkout (run install.ps1 from the repo root)" }
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
$root = Split-Path $dir -Parent
$PathScope = if ($IsElevated -and -not $InstallDir) { 'Machine' } else { 'User' }

# ---- uninstall: remove the selected component(s), the stdlib and bundled DLLs
# (for hcc), and our PATH entry. Honors -DryRun. ----
if ($Uninstall) {
    $did = $false
    foreach ($b in $Bins) {
        $exe = Join-Path $dir "$b.exe"
        if (Test-Path $exe) {
            if ($DryRun) { Write-Host "install: would remove $exe" }
            else { Remove-Item -Force $exe; Write-Host "install: removed $exe" }
            $did = $true
        }
    }
    if ($WantsHcc) {
        Get-ChildItem -Path $dir -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($DryRun) { Write-Host "install: would remove $($_.FullName)" }
            else { Remove-Item -Force $_.FullName; Write-Host "install: removed $($_.FullName)" }
            $did = $true
        }
        $stdDir = Join-Path $root 'std'
        if (Test-Path $stdDir) {
            if ($DryRun) { Write-Host "install: would remove $stdDir" }
            else { Remove-Item -Recurse -Force $stdDir; Write-Host "install: removed $stdDir" }
            $did = $true
        }
    }
    if (-not $NoModifyPath) {
        $scopePath = [Environment]::GetEnvironmentVariable('Path', $PathScope)
        if (($scopePath -split ';') -contains $dir) {
            if ($DryRun) { Write-Host "install: would remove $dir from the $($PathScope.ToLower()) PATH" }
            else {
                $new = (($scopePath -split ';') | Where-Object { $_ -ne $dir }) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $new, $PathScope)
                Write-Host "install: removed $dir from the $($PathScope.ToLower()) PATH"
            }
        }
    }
    if (-not $did) { Write-Host "install: nothing to uninstall for $($Bins -join ', ') in $dir" }
    exit 0
}

# ---- dry run: report the plan and stop before touching anything ----
if ($DryRun) {
    Write-Host "install: dry run — no changes will be made"
    Write-Host "  components:  $($Bins -join ', ')"
    if ($fromSource) { Write-Host "  mode:        build from source ($RepoRoot)" }
    else { Write-Host "  mode:        download release $Version" }
    Write-Host "  install dir: $dir"
    if ($WantsHcc) { Write-Host "  stdlib:      $(Join-Path $root 'std')" }
    $scopePath = [Environment]::GetEnvironmentVariable('Path', $PathScope)
    if (($scopePath -split ';') -contains $dir) { Write-Host "  PATH:        already contains $dir" }
    elseif ($NoModifyPath) { Write-Host "  PATH:        would print a hint for $dir" }
    else { Write-Host "  PATH:        would add $dir to the $($PathScope.ToLower()) PATH" }
    exit 0
}

# ---- skip when already installed (unless -Upgrade) ----
if (-not $Upgrade) {
    $allPresent = $true
    foreach ($b in $Bins) {
        if (-not (Test-Path (Join-Path $dir "$b.exe"))) { $allPresent = $false }
    }
    # An hcc install also owns the stdlib at <root>\std; if the binary
    # is present but the stdlib isn't, there is still work to do.
    if ($WantsHcc -and -not (Test-Path (Join-Path $root 'std'))) { $allPresent = $false }
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
    # Only an hcc install needs LLVM; holyc-lsp never touches it.
    if ($WantsHcc) { Test-Llvm }
    if ($fromSource) {
        if (-not $haveZig) { throw "install: building from source needs Zig 0.16 (https://ziglang.org/download/); or pass -Download to fetch a release" }
        Write-Host "install: building $($Bins -join ', ') from source ($RepoRoot)"
        Push-Location $RepoRoot
        try {
            # Per-artifact build steps (hcc→hcc, holyc-lsp→lsp), so an LSP-only
            # install never links (or requires) LLVM.
            $steps = @()
            foreach ($b in $Bins) { if ($b -eq 'hcc') { $steps += 'hcc' } elseif ($b -eq 'holyc-lsp') { $steps += 'lsp' } }
            if ($LlvmPrefix) {
                & zig build @steps -Doptimize=ReleaseSafe "-Dllvm-prefix=$LlvmPrefix"
            } else {
                & zig build @steps -Doptimize=ReleaseSafe
            }
            if ($LASTEXITCODE -ne 0) { throw "install: zig build failed" }
            foreach ($b in $Bins) {
                $built = Join-Path 'zig-out/bin' "$b.exe"
                if (-not (Test-Path $built)) { throw "install: zig build did not produce $b" }
                Copy-Item $built (Join-Path $tmp "$b.exe")
            }
            # Stage the standard-library source tree beside the staged binary,
            # so the install step below places it at <root>\std.
            if ($WantsHcc) { Copy-Item -Recurse -Force (Join-Path $RepoRoot 'std') (Join-Path $tmp 'std') }
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

    # ---- install bundled runtime DLLs beside the binaries (Windows hcc) ----
    # The Windows hcc.exe links libLLVM.dll dynamically; the release asset carries
    # it plus its mingw runtime deps at the archive root, and they must sit next
    # to hcc.exe to be found. The lsp asset carries none, so this is a no-op there.
    Get-ChildItem -Path $tmp -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $dir $_.Name) -Force
        Write-Host "install: installed $($_.Name) to $dir"
    }

    # ---- install the standard library beside the hcc binary (hcc only) ----
    # hcc discovers it as HCC_ROOT\std relative to its own path — <root>\std,
    # where <root> is the parent of the bin dir. In download mode this expects
    # the release tarball to carry a top-level std\ dir; older tarballs without it
    # simply skip the stdlib.
    $stdSrc = Join-Path $tmp 'std'
    if ($WantsHcc -and (Test-Path $stdSrc)) {
        $stdDir = Join-Path $root 'std'
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
if ($WantsHcc) {
    Write-Host "`nRun: hcc --help"
}
if ((-not $WantsHcc) -or $Lsp) {
    Write-Host "`nholyc-lsp speaks LSP over stdio — point your editor at it"
}

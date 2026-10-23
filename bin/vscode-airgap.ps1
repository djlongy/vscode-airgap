<#
.SYNOPSIS
  Online side of vscode-airgap.sh for Windows: build the bundle that
  vscode-airgap.sh --mode offline installs on the air-gapped Linux host.

.DESCRIPTION
  -Mode bundle and -ListVersions run here. -Mode install copies a bundle
  over ssh and runs vscode-airgap.sh --mode offline on each host, so the
  files never need copying by hand. Linking options and the sshd/fapolicyd
  templates stay in vscode-airgap.sh. The bundle layout and versions.json
  match what vscode-airgap.sh --mode bundle writes, field for field.

.PARAMETER Mode
  bundle: download the server, CLI, clients and extensions into one tar.gz.
  install: copy -BundlePath to each -RemoteHost over ssh and install it there.

.PARAMETER RemoteHost
  user@host list to install on over ssh. With -Mode bundle, installs the new
  bundle once it is built. Needs the OpenSSH client (Windows 10 1809 and later).

.PARAMETER RemoteArgs
  Arguments for vscode-airgap.sh --mode offline on the host. Default: --all-users.

.PARAMETER RemoteTemp
  Folder on the host for the upload, removed afterwards. Default: /tmp.

.PARAMETER Version
  Release to stage, X.Y.Z or X.Y (newest matching patch). Default: latest stable.

.PARAMETER Commit
  40-character commit. Wins over -Version.

.PARAMETER Arch
  Remote host platform: linux-x64 (default), linux-arm64, linux-armhf, alpine-x64.

.PARAMETER BundlePath
  Bundle to write. Default: vscode-bundle-v<version>.tar.gz in the current folder.
  With -Mode install: a bundle tar.gz, or a folder from the browser page.

.PARAMETER Extensions
  Comma list of publisher.name IDs, or files with one ID per line.

.PARAMETER ExtensionsFile
  File with one publisher.name ID per line.

.PARAMETER ListVersions
  Print stable releases with their commits, newest first.

.PARAMETER Limit
  Rows for -ListVersions. Default: 10.

.PARAMETER All
  Every row for -ListVersions.

.PARAMETER Format
  Output for -ListVersions: text (default) or json.

.EXAMPLE
  .\vscode-airgap.ps1 -Mode bundle
.EXAMPLE
  .\vscode-airgap.ps1 -Mode bundle -Version 1.143.0 -BundlePath C:\bundles\vscode-bundle-v1.143.0.tar.gz
.EXAMPLE
  .\vscode-airgap.ps1 -Mode bundle -Version 1.143.0 -Extensions extensions.txt,ms-python.python
.EXAMPLE
  .\vscode-airgap.ps1 -ListVersions -Limit 5
.EXAMPLE
  .\vscode-airgap.ps1 -Mode install -BundlePath C:\Downloads\vscode -RemoteHost admin@host1,admin@host2
  Installs a folder from the browser page on two hosts.
.EXAMPLE
  .\vscode-airgap.ps1 -Mode bundle -Version 1.143.1 -RemoteHost admin@host1
  Builds the bundle, then installs it on host1.
.EXAMPLE
  vscode-airgap.bat -Mode bundle -Version 1.143.0
  Same arguments, run with -ExecutionPolicy Bypass for a host that blocks scripts.
#>
[CmdletBinding()]
param(
  [ValidateSet('bundle', 'install')] [string]$Mode,
  [string]$Version = $env:VERSION,
  [string]$Commit = $env:COMMIT,
  [ValidateSet('linux-x64', 'linux-arm64', 'linux-armhf', 'alpine-x64')] [string]$Arch = 'linux-x64',
  [string]$BundlePath,
  [string[]]$Extensions,
  [string]$ExtensionsFile,
  [switch]$ListVersions,
  [int]$Limit = 10,
  [switch]$All,
  [ValidateSet('text', 'json')] [string]$Format = 'text',
  [string[]]$RemoteHost,
  [string]$RemoteArgs = '--all-users',
  [string]$RemoteTemp = '/tmp'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is many times slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UpdateHost = 'https://update.code.visualstudio.com'
$MarketplaceHost = 'https://marketplace.visualstudio.com'
$Channel = 'stable'

function Log([string]$msg) { [Console]::Error.WriteLine("[$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))] $msg") }
function Die([string]$msg) { Log "ERROR: $msg"; exit 1 }

# HTTPS_PROXY wins over the system proxy, like curl does in the bash script.
$Web = @{ UseBasicParsing = $true }
$proxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:https_proxy) { $env:https_proxy } else { $null }
if ($proxy) { $Web.Proxy = $proxy }

function Get-Json([string]$url) { Invoke-RestMethod @Web -Uri $url -TimeoutSec 30 }

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }

# Semver -> commit from microsoft/vscode's git tags (bare X.Y.Z), plus the
# CDN's latest stable build, which ships before its tag. An annotated tag
# points at a tag object, kept as "tag:<sha>" until Get-TagCommit reads it.
function Get-StableVersions {
  $refs = Get-Json 'https://api.github.com/repos/microsoft/vscode/git/matching-refs/tags/'
  $map = @{}
  foreach ($r in $refs) {
    if ($r.ref -notmatch '^refs/tags/(\d+\.\d+\.\d+)$') { continue }
    if ($r.object.type -eq 'commit') { $map[$Matches[1]] = $r.object.sha }
    elseif ($r.object.type -eq 'tag') { $map[$Matches[1]] = "tag:$($r.object.sha)" }
  }
  try {
    $latest = Get-Json "$UpdateHost/api/update/server-linux-x64/$Channel/latest"
    if ($latest.productVersion -match '^\d+\.\d+\.\d+$' -and -not $map.ContainsKey($latest.productVersion)) {
      $map[$latest.productVersion] = $latest.version
    }
  } catch { Log "WARN:  CDN latest lookup failed, using git tags only: $_" }
  $map.GetEnumerator() | Sort-Object { [version]$_.Key } -Descending
}

function Get-TagCommit([string]$sha) {
  if ($sha.StartsWith('tag:')) { (Get-Json "https://api.github.com/repos/microsoft/vscode/git/tags/$($sha.Substring(4))").object.sha } else { $sha }
}

function Resolve-VersionToCommit([string]$wanted) {
  $norm = $wanted.TrimStart('v', 'V')
  $rows = @(Get-StableVersions)
  $hit = $rows | Where-Object { $_.Key -eq $norm } | Select-Object -First 1
  if (-not $hit -and ($norm.Split('.').Count -eq 2)) {
    $hit = $rows | Where-Object { $_.Key.StartsWith("$norm.") } | Select-Object -First 1
    if ($hit) { Log "-Version $wanted -> newest matching tag $($hit.Key)" }
  }
  if (-not $hit) { Die "-Version '$wanted' not found in microsoft/vscode's stable tags. Run with -ListVersions to see what is available." }
  $hit = @{ Key = $hit.Key; Value = (Get-TagCommit $hit.Value) }
  Log "checking CDN availability for $($hit.Key) (commit $($hit.Value.Substring(0,12))...)"
  try { Invoke-WebRequest @Web -Method Head -Uri "$UpdateHost/commit:$($hit.Value)/server-linux-x64/$Channel" -TimeoutSec 20 | Out-Null }
  catch { Die "version $($hit.Key)'s server-linux-x64 artifact is not on Microsoft's CDN: $_" }
  $script:Version = $hit.Key
  $hit.Value
}

# Returns @{ Commit; Sha256; Source } after downloading <segment> to <dest>.
function Get-Artifact([string]$segment, [string]$dest) {
  if ($Commit) {
    $url = "$UpdateHost/commit:$Commit/$segment/$Channel"; $c = $Commit; $msSha = ''
  } else {
    $meta = Get-Json "$UpdateHost/api/update/$segment/$Channel/latest"
    $url = $meta.url; $c = $meta.version; $msSha = "$($meta.sha256hash)"
  }
  Log "downloading $segment (commit $($c.Substring(0,12))...) -> $dest"
  Invoke-WebRequest @Web -Uri $url -OutFile $dest -TimeoutSec 600
  if ((Get-Item -LiteralPath $dest).Length -eq 0) { Die "downloaded file is empty: $dest" }
  $got = Get-Sha256 $dest
  if ($msSha) {
    if ($got -ne $msSha) { Die "sha256 mismatch for ${segment}: Microsoft published $msSha, got $got" }
    @{ Commit = $c; Sha256 = $got; Source = 'microsoft' }
  } else {
    @{ Commit = $c; Sha256 = $got; Source = 'self' }
  }
}

function Get-ServerSegment {
  switch ($Arch) { 'linux-x64' { 'server-linux-x64' } 'linux-arm64' { 'server-linux-arm64' } 'linux-armhf' { 'server-linux-armhf' } 'alpine-x64' { 'server-linux-alpine' } }
}
function Get-RemoteCliSegment {
  switch ($Arch) { { $_ -in 'linux-x64', 'alpine-x64' } { 'cli-alpine-x64' } 'linux-arm64' { 'cli-alpine-arm64' } default { '' } }
}

# ── Extensions: same selection rules as pick_and_download_extension ──
function ConvertTo-Semver([string]$v) {
  if ($v -match '^(\d+)\.(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" } else { [version]'0.0.0' }
}
function Test-Engine([string]$range, [string]$ver) {
  $range = "$range".Trim(); $v = ConvertTo-Semver $ver
  if ($range -in '*', '') { return $true }
  if ($range -match '^\^(\d+)\.(\d+)\.(\d+)') { $lo = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"; return ($v -ge $lo -and $v -lt [version]"$($lo.Major + 1).0.0") }
  if ($range -match '^>=\s*(\d+)\.(\d+)\.(\d+)') { return ($v -ge [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])") }
  if ($range -match '^(\d+)\.(\d+)\.(\d+)$') { return ($v -eq [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])") }
  $true
}
# Python json.dumps layout, so versions.json matches the bash bundle byte for byte.
function Format-ExtResult($r) {
  '{"id": "' + $r.id + '", "version": "' + $r.version + '", "target_platform": "' + $r.target_platform + '", "engine": "' + ($r.engine -replace '\\', '\\' -replace '"', '\"') + '", "method": "' + $r.method + '"}'
}
function Get-Extension([string]$id, [string]$target, [string]$dir) {
  $pub, $name = $id.Split('.', 2)
  if (-not $pub -or -not $name) { Die "invalid extension id '$id' (expected publisher.name)" }
  $dest = Join-Path $dir "$id.vsix"
  try {
    $body = @{ filters = @(@{ criteria = @(@{ filterType = 7; value = $id }) }); flags = 19 } | ConvertTo-Json -Depth 6
    $d = Invoke-RestMethod @Web -Method Post -Uri "$MarketplaceHost/_apis/public/gallery/extensionquery" -Body $body -TimeoutSec 30 `
      -ContentType 'application/json' -Headers @{ Accept = 'application/json;api-version=3.0-preview.1' }
    $ext = $d.results[0].extensions
    if (-not $ext) { throw "extension not found: $id" }
    $byVersion = [ordered]@{}
    foreach ($v in $ext[0].versions) {
      $tp = $v.targetPlatform
      if ($tp -and $tp -ne 'linux-x64') { continue }
      if (-not $byVersion.Contains($v.version) -or $tp -eq 'linux-x64') { $byVersion[$v.version] = $v }
    }
    $chosen = $null; $engine = $null
    foreach ($v in ($byVersion.Values | Sort-Object { ConvertTo-Semver $_.version } -Descending)) {
      $e = ($v.properties | Where-Object { $_.key -eq 'Microsoft.VisualStudio.Code.Engine' } | Select-Object -First 1).value
      if (-not $e) { $e = '*' }
      if (Test-Engine $e $target) { $chosen = $v; $engine = $e; break }
    }
    if (-not $chosen) { throw "no version of $id declares engine compatibility with $target" }
    $vsix = ($chosen.files | Where-Object { $_.assetType -like '*VSIXPackage' } | Select-Object -First 1).source
    if (-not $vsix) { throw 'no VSIXPackage asset in chosen version' }
    Invoke-WebRequest @Web -Uri $vsix -OutFile $dest -TimeoutSec 60
    $tpOut = if ($chosen.targetPlatform) { $chosen.targetPlatform } else { 'universal' }
    @{ id = $id; version = $chosen.version; target_platform = $tpOut; engine = $engine; method = 'engine-matched' }
  } catch {
    Log "[extensionquery fallback for ${id}: $_]"
    Invoke-WebRequest @Web -Uri "$MarketplaceHost/_apis/public/gallery/publishers/$pub/vsextensions/$name/latest/vspackage" -OutFile $dest -TimeoutSec 60
    @{ id = $id; version = 'latest'; target_platform = 'unknown'; engine = 'unverified'; method = 'latest-fallback' }
  }
}

function Read-ExtensionIds {
  $ids = @()
  $lines = @()
  foreach ($item in ($Extensions | ForEach-Object { $_ -split ',' })) {
    if ($item -and (Test-Path -LiteralPath $item -PathType Leaf)) { $lines += Get-Content -LiteralPath $item } else { $lines += $item }
  }
  if ($ExtensionsFile) {
    if (-not (Test-Path -LiteralPath $ExtensionsFile -PathType Leaf)) { Die "-ExtensionsFile not found: $ExtensionsFile" }
    $lines += Get-Content -LiteralPath $ExtensionsFile
  }
  foreach ($l in $lines) { $t = "$l".Trim(); if ($t -and -not $t.StartsWith('#')) { $ids += $t } }
  $u = [string[]]@($ids | Select-Object -Unique)
  [Array]::Sort($u, [StringComparer]::Ordinal)
  $u
}

function Invoke-Bundle {
  if ($Version -and $Commit) { Log "WARN:  both -Version ($Version) and -Commit are set; -Commit wins"; $script:Version = '' }
  elseif ($Version) { $script:Commit = Resolve-VersionToCommit $Version; Log "resolved -Version $Version -> commit $($Commit.Substring(0,12))..." }

  $stage = Join-Path ([IO.Path]::GetTempPath()) ("vscode-airgap-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $stage | Out-Null
  try {
    $srv = Get-Artifact (Get-ServerSegment) (Join-Path $stage 'server-linux-x64.tar.gz')
    $commitId = $srv.Commit
    $ver = $Version
    if (-not $ver) {
      try { $ver = (Get-Json "$UpdateHost/api/update/server-linux-x64/$Channel/latest").productVersion } catch { $ver = '' }
      if (-not $ver) { Log "WARN:  could not resolve a semver for commit $($commitId.Substring(0,12))..."; $ver = $commitId }
    }
    $lin = Get-Artifact 'linux-x64' (Join-Path $stage 'vscode-linux-x64.tar.gz')
    $winName = "VSCodeUserSetup-x64-$ver.exe"
    $win = Get-Artifact 'win32-x64-user' (Join-Path $stage $winName)
    $cliSeg = Get-RemoteCliSegment
    $rssh = $null
    if ($cliSeg) { $rsshName = "$cliSeg.tar.gz"; $rssh = Get-Artifact $cliSeg (Join-Path $stage $rsshName) }
    else { Log "WARN:  no Remote-SSH CLI segment for -Arch $Arch; handshake archive will not be bundled" }

    $results = @()
    $ids = @(Read-ExtensionIds)
    if ($ids.Count) {
      $extDir = Join-Path $stage 'extensions'; New-Item -ItemType Directory -Path $extDir | Out-Null
      foreach ($id in $ids) {
        Log "resolving extension $id (engine target: vscode $ver)"
        $r = Get-Extension $id $ver $extDir
        Log "  -> $($r.id) $($r.version) ($($r.method))"
        $results += Format-ExtResult $r
      }
    }

    # Same keys, order and layout as write_manifest in vscode-airgap.sh.
    $requested = if ($Version) { $Version } else { 'latest' }
    $m = New-Object Text.StringBuilder
    $add = { param($s) [void]$m.Append($s).Append("`n") }
    & $add '{'
    & $add "  `"channel`": `"$Channel`","
    & $add "  `"commit`": `"$commitId`","
    & $add "  `"vscode_version`": `"$ver`","
    & $add "  `"requested_version`": `"$requested`","
    & $add "  `"remote_arch`": `"$Arch`","
    & $add "  `"built_at_utc`": `"$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))`","
    & $add '  "server_artifact": "server-linux-x64.tar.gz",'
    & $add "  `"server_sha256`": `"$($srv.Sha256)`","
    & $add "  `"server_sha256_source`": `"$($srv.Source)`","
    & $add '  "client_linux_artifact": "vscode-linux-x64.tar.gz",'
    & $add "  `"client_linux_sha256`": `"$($lin.Sha256)`","
    & $add "  `"client_linux_sha256_source`": `"$($lin.Source)`","
    & $add "  `"client_windows_artifact`": `"$winName`","
    & $add "  `"client_windows_sha256`": `"$($win.Sha256)`","
    & $add "  `"client_windows_sha256_source`": `"$($win.Source)`","
    & $add '  "cli_artifact": null,'
    if ($rssh) {
      & $add "  `"remote_ssh_cli_artifact`": `"$rsshName`","
      & $add "  `"remote_ssh_cli_sha256`": `"$($rssh.Sha256)`","
      & $add "  `"remote_ssh_cli_sha256_source`": `"$($rssh.Source)`","
    } else { & $add '  "remote_ssh_cli_artifact": null,' }
    & $add '  "server_web_artifact": null,'
    if ($results.Count) { & $add ('  "extensions": [' + "`n    " + ($results -join ",`n    ") + "`n  ]") }
    else { & $add '  "extensions": []' }
    & $add '}'
    [IO.File]::WriteAllText((Join-Path $stage 'versions.json'), $m.ToString(), (New-Object Text.UTF8Encoding $false))
    Log "manifest written: $(Join-Path $stage 'versions.json')"

    if (-not $BundlePath) { $BundlePath = "vscode-bundle-v$ver.tar.gz" }
    $out = [IO.Path]::GetFullPath((Join-Path (Get-Location) $BundlePath))
    $parent = Split-Path -Parent $out
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    # tar.exe (bsdtar) ships with Windows 10 1803 and later.
    & tar -C $stage -czf $out .
    if ($LASTEXITCODE -ne 0) { Die "tar failed ($LASTEXITCODE) writing $out" }
    $script:BuiltBundle = $out
    Log "bundle written: $out ($([math]::Round((Get-Item $out).Length / 1MB)) MB)"
    Log 'carry this file across the air gap, then run:'
    Log "  sudo /usr/local/bin/vscode-airgap.sh --mode offline --bundle-path $(Split-Path -Leaf $out) --link-home"
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
  }
}

# Two connections per host: scp for the upload, then ssh -t so sudo can prompt.
# The host's /usr/local/bin/vscode-airgap.sh is replaced with the copy next to
# this script, so it always understands the bundle being installed.
function Invoke-RemoteInstall([string]$bundle) {
  foreach ($tool in 'ssh', 'scp') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool not found. Add the OpenSSH Client in Settings > Apps > Optional features." }
  }
  if (-not $RemoteHost) { Die '-RemoteHost is required for -Mode install' }
  if (-not $bundle -or -not (Test-Path -LiteralPath $bundle)) { Die "-BundlePath not found: $bundle" }
  $sh = Join-Path $PSScriptRoot 'vscode-airgap.sh'
  if (-not (Test-Path -LiteralPath $sh)) { Die "vscode-airgap.sh must sit next to this script: $sh" }

  $item = Get-Item -LiteralPath $bundle
  $id = "vscode-airgap-$([guid]::NewGuid())"
  $remote = "$($RemoteTemp.TrimEnd('/'))/$id"
  $stage = Join-Path ([IO.Path]::GetTempPath()) $id
  New-Item -ItemType Directory -Path $stage | Out-Null
  try {
    # Hard links keep an 800 MB upload from being copied locally first.
    $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $bundle -File) } else { @($item) }
    foreach ($f in $files) {
      $dst = Join-Path $stage $f.Name
      try { New-Item -ItemType HardLink -Path $dst -Target $f.FullName -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $f.FullName $dst }
    }
    Copy-Item -LiteralPath $sh (Join-Path $stage 'vscode-airgap.sh') -Force
    $bundleArg = if ($item.PSIsContainer) { $remote } else { "$remote/$($item.Name)" }
    $failed = @()
    foreach ($h in ($RemoteHost | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
      Log "copying $($files.Count + 1) files to ${h}:$remote"
      & scp -r $stage "${h}:$remote"
      if ($LASTEXITCODE -ne 0) { Log "ERROR: upload to $h failed ($LASTEXITCODE). If ssh said "scp: command not found", install openssh-clients on the host."; $failed += $h; continue }
      Log "installing on $h (sudo may ask for your password)"
      & ssh -t $h "sudo install -m 0755 '$remote/vscode-airgap.sh' /usr/local/bin/vscode-airgap.sh && sudo /usr/local/bin/vscode-airgap.sh --mode offline --bundle-path '$bundleArg' $RemoteArgs; rc=`$?; rm -rf '$remote'; exit `$rc"
      if ($LASTEXITCODE -ne 0) { Log "ERROR: install on $h failed ($LASTEXITCODE)"; $failed += $h } else { Log "installed on $h" }
    }
    if ($failed) { Die "install failed on: $($failed -join ', ')" }
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
  }
}

function Invoke-ListVersions {
  $rows = @(Get-StableVersions)
  $shown = if ($All -or $Limit -le 0) { $rows } else { $rows | Select-Object -First $Limit }
  $shown = @($shown | ForEach-Object { @{ Key = $_.Key; Value = (Get-TagCommit $_.Value) } })
  if ($Format -eq 'json') {
    ConvertTo-Json -InputObject @($shown | ForEach-Object { [ordered]@{ version = $_.Key; commit = $_.Value } })
  } else {
    '{0,-11} {1}' -f 'VERSION', 'COMMIT'
    foreach ($r in $shown) { '{0,-11} {1}' -f $r.Key, $r.Value }
    Log "showing $(@($shown).Count) of $($rows.Count) (newest first). -Limit N or -All for more."
  }
}

if ($ListVersions) { Invoke-ListVersions }
elseif ($Mode -eq 'bundle') { Invoke-Bundle; if ($RemoteHost) { Invoke-RemoteInstall $BuiltBundle } }
elseif ($Mode -eq 'install') { Invoke-RemoteInstall $BundlePath }
else { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 2 }

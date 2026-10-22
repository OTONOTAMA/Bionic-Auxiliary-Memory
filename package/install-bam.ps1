# install-bam.ps1 - BAM v0.7 portable installer
#
# Subcommands: verify-artifact / check-target / install-mock / install / status-report
#              / uninstall (disabled: deletes nothing, exit 2)
# Contract: exactly one JSON line on stdout. Exit: 0 = PASS/OK, 1 = FAIL, 2 = STOP.
# Requirements: Windows PowerShell 5.1, no admin rights. Never overwrites existing data.

param(
  [Parameter(Position = 0)][string]$Command,
  [string]$Zip,
  [string]$ExpectedSha256,
  [string]$WorkspaceRoot,
  [string]$ToolDir
)

$ErrorActionPreference = 'Stop'

if (-not $ToolDir) { $ToolDir = Join-Path $env:LOCALAPPDATA 'bam' }

$ZIP_ROOT = 'bam-portable'
$SUITE_TIMEOUT_MS = 2400000
$ADAPTER_TIMEOUT_MS = 60000
$TOOL_FILES = @('bam-adapter.ps1', 'test-bam-adapter.ps1', '01_SPEC.md')
$STAGING_FILES = @('bam-adapter.ps1', 'test-bam-adapter.ps1', 'migrate-legacy.ps1', '01_SPEC.md')

function Write-JsonOut {
  param($Obj)
  [System.Console]::Out.WriteLine(($Obj | ConvertTo-Json -Compress -Depth 10))
}

function Stop-Fail {
  param([string]$Code, [string]$Message)
  $o = [ordered]@{ status = 'FAIL'; command = $Command; code = $Code; message = $Message }
  Write-JsonOut $o
  exit 1
}

function Stop-Stop2 {
  param([string]$Code, [string]$Message, [hashtable]$Detail)
  if (-not $Detail) { $Detail = @{} }
  $o = [ordered]@{ status = 'STOP'; command = $Command; code = $Code; message = $Message }
  foreach ($k in $Detail.Keys) { $o[$k] = $Detail[$k] }
  Write-JsonOut $o
  exit 2
}

function Get-Sha256Hex {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function New-TempDir {
  $base = [System.IO.Path]::GetTempPath()
  $name = 'bamp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $p = Join-Path $base $name
  New-Item -ItemType Directory -Path $p | Out-Null
  return $p
}

function Remove-TempDir {
  param([string]$Path)
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { }
  }
}

function Test-ZipHash {
  param([string]$ZipPath, [string]$Expected)
  if (-not $Expected) { Stop-Fail 'EXPECTED_SHA256_MISSING' 'pass -ExpectedSha256 (the sidecar value)' }
  if (-not (Test-Path -LiteralPath $ZipPath)) { Stop-Fail 'ZIP_MISSING' $ZipPath }
  $actual = Get-Sha256Hex $ZipPath
  if ($actual -ne $Expected.ToLower()) {
    Stop-Fail 'ZIP_HASH_MISMATCH' ('expected ' + $Expected.ToLower() + ' actual ' + $actual)
  }
}

function Expand-Zip {
  param([string]$ZipPath, [string]$DestDir)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
  } catch {
    Stop-Fail 'ADDTYPE_FAILED' $_.Exception.Message
  }
  [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir, [System.Text.Encoding]::UTF8)
  $pkg = Join-Path $DestDir $ZIP_ROOT
  if (-not (Test-Path -LiteralPath $pkg)) { Stop-Fail 'ZIP_ROOT_MISSING' ('folder ' + $ZIP_ROOT + ' not found in ZIP') }
  return $pkg
}

function Test-Manifest {
  param([string]$PkgDir)
  $m = Join-Path $PkgDir 'MANIFEST.sha256'
  if (-not (Test-Path -LiteralPath $m)) { Stop-Fail 'MANIFEST_MISSING' $m }
  $text = [System.IO.File]::ReadAllText($m, [System.Text.Encoding]::UTF8)
  $expected = @{}
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    $mm = [regex]::Match($line, '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$')
    if (-not $mm.Success) { Stop-Fail 'MANIFEST_LINE_INVALID' $line }
    $rel = $mm.Groups[2].Value.Replace('\', '/')
    $expected[$rel] = $mm.Groups[1].Value.ToLower()
  }
  $missing = @()
  $mismatch = @()
  foreach ($rel in $expected.Keys) {
    $p = Join-Path $PkgDir ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { $missing += $rel; continue }
    if ((Get-Sha256Hex $p) -ne $expected[$rel]) { $mismatch += $rel }
  }
  $extra = @()
  Get-ChildItem -LiteralPath $PkgDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($PkgDir.Length + 1).Replace('\', '/')
    if ($rel -ne 'MANIFEST.sha256' -and -not $expected.ContainsKey($rel)) { $extra += $rel }
  }
  if ($missing.Count -gt 0 -or $mismatch.Count -gt 0 -or $extra.Count -gt 0) {
    $detail = 'missing=[' + ($missing -join ',') + '] mismatch=[' + ($mismatch -join ',') + '] extra=[' + ($extra -join ',') + ']'
    Stop-Fail 'MANIFEST_MISMATCH' $detail
  }
  return $expected.Count
}

function Test-WorkspaceClean {
  param([string]$Ws)
  $bad = @()
  $skillDir = Join-Path $Ws '.agents\skills\bam-memory'
  if (Test-Path -LiteralPath $skillDir) { $bad += $skillDir }
  $mem = Join-Path $Ws 'memory'
  if (Test-Path -LiteralPath $mem) { $bad += $mem }
  if ($bad.Count -gt 0) {
    Stop-Stop2 'EXISTING_DATA' 'workspace already contains BAM data; nothing is overwritten' @{ existing = $bad }
  }
}

function Get-PkgToolHashes {
  param([string]$PkgDir)
  $h = @{}
  foreach ($f in $TOOL_FILES) { $h[$f] = Get-Sha256Hex (Join-Path $PkgDir $f) }
  return $h
}

# Shared tool dir: CLEAN = no tool files present; MATCHING = all tool files present
# and byte-identical to this package (reused, not re-copied); anything else = STOP.
function Test-ToolDir {
  param([string]$TD, [hashtable]$PkgHashes)
  $present = @()
  foreach ($f in $TOOL_FILES) {
    if (Test-Path -LiteralPath (Join-Path $TD $f)) { $present += $f }
  }
  if ($present.Count -eq 0) { return 'CLEAN' }
  if ($present.Count -lt $TOOL_FILES.Count) {
    Stop-Stop2 'TOOL_DIR_CONFLICT' 'partial tool dir found; not overwriting' @{ present = $present }
  }
  $mismatch = @()
  foreach ($f in $TOOL_FILES) {
    if ((Get-Sha256Hex (Join-Path $TD $f)) -ne $PkgHashes[$f]) { $mismatch += $f }
  }
  if ($mismatch.Count -gt 0) {
    Stop-Stop2 'TOOL_DIR_CONFLICT' 'existing tools differ from this package; not overwriting' @{ mismatch = $mismatch }
  }
  return 'MATCHING'
}

function Get-PathSnapshot {
  param([string[]]$Roots)
  $snap = @{}
  foreach ($r in $Roots) {
    if ($r -and (Test-Path -LiteralPath $r)) {
      Get-ChildItem -LiteralPath $r -Recurse -File | ForEach-Object {
        $snap[$_.FullName.ToLower()] = ($_.Length + '|' + (Get-Sha256Hex $_.FullName))
      }
    }
  }
  return $snap
}

function Stage-SuiteFiles {
  param([string]$PkgDir, [string]$StageDir)
  New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
  foreach ($f in $STAGING_FILES) {
    Copy-Item -LiteralPath (Join-Path $PkgDir $f) -Destination (Join-Path $StageDir $f) -Force
  }
  return $StageDir
}

function Run-Suite {
  param([string]$StagingDir)
  $ps1 = (Get-Process -Id $PID).Path
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ps1
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $StagingDir 'test-bam-adapter.ps1') + '" -Staging "' + $StagingDir + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $proc = [System.Diagnostics.Process]::Start($psi)
  $exited = $proc.WaitForExit($SUITE_TIMEOUT_MS)
  if (-not $exited) {
    $proc.Kill()
    Stop-Fail 'SUITE_TIMEOUT' ('suite did not exit within ' + $SUITE_TIMEOUT_MS + ' ms')
  }
  $so = $proc.StandardOutput.ReadToEnd()
  $se = $proc.StandardError.ReadToEnd()
  $code = $proc.ExitCode
  $maxMs = $null
  $mm = [regex]::Match($so, 'max_ms=(\d+)')
  if ($mm.Success) { $maxMs = [int]$mm.Groups[1].Value }
  $ok = ($code -eq 0) -and ($so -match 'cases=33 \(failed cases=0\)')
  if ($so.Length -gt 400) { $tail = $so.Substring($so.Length - 400) } else { $tail = $so }
  return [pscustomobject]@{ ok = $ok; exit = $code; max_ms = $maxMs; tail = $tail }
}

function Invoke-Adapter {
  param([string]$Adapter, [string[]]$ArgList)
  $ps1 = (Get-Process -Id $PID).Path
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ps1
  $argStr = ''
  foreach ($a in $ArgList) { $argStr = $argStr + ' "' + $a + '"' }
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Adapter + '"' + $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $proc = [System.Diagnostics.Process]::Start($psi)
  $exited = $proc.WaitForExit($ADAPTER_TIMEOUT_MS)
  if (-not $exited) {
    $proc.Kill()
    Stop-Fail 'ADAPTER_TIMEOUT' ('adapter did not exit within ' + $ADAPTER_TIMEOUT_MS + ' ms')
  }
  $so = $proc.StandardOutput.ReadToEnd()
  $se = $proc.StandardError.ReadToEnd()
  $json = $null
  foreach ($line in ($so -split "`r?`n")) {
    if ($line.TrimStart().StartsWith('{')) { $json = $line.Trim(); break }
  }
  $parsed = $null
  if ($json) {
    try { $parsed = $json | ConvertFrom-Json } catch { $parsed = $null }
  }
  $stderrTail = ''
  if ($se.Length -gt 300) { $stderrTail = $se.Substring($se.Length - 300) } else { $stderrTail = $se }
  return [pscustomobject]@{ exit = $proc.ExitCode; json = $json; parsed = $parsed; stderr_tail = $stderrTail }
}

try {
  switch ($Command) {
    'verify-artifact' {
      if (-not $Zip) { Stop-Fail 'ZIP_MISSING' 'pass -Zip' }
      Test-ZipHash $Zip $ExpectedSha256
      $actual = Get-Sha256Hex $Zip
      $tmp = New-TempDir
      try {
        $pkg = Expand-Zip $Zip $tmp
        $n = Test-Manifest $pkg
      } finally {
        Remove-TempDir $tmp
      }
      $out = [ordered]@{ status = 'PASS'; command = 'verify-artifact'; zip = $Zip; sha256 = $actual; manifest_entries = $n }
      Write-JsonOut $out
    }
    'check-target' {
      if (-not $WorkspaceRoot) { Stop-Fail 'WORKSPACE_MISSING' 'pass -WorkspaceRoot' }
      if (-not $Zip) { Stop-Fail 'ZIP_MISSING' 'pass -Zip (and -ExpectedSha256) to compare the shared tool dir' }
      Test-ZipHash $Zip $ExpectedSha256
      $tmp = New-TempDir
      try {
        $pkg = Expand-Zip $Zip $tmp
        $ph = Get-PkgToolHashes $pkg
        Test-WorkspaceClean $WorkspaceRoot
        $tdState = Test-ToolDir $ToolDir $ph
        $mem = Join-Path $WorkspaceRoot 'memory'
        $out = [ordered]@{ status = 'PASS'; command = 'check-target'; target_clean = $true; tool_dir = $ToolDir; tool_dir_state = $tdState; workspace_root = $WorkspaceRoot; memory_root = $mem }
        Write-JsonOut $out
      } finally {
        Remove-TempDir $tmp
      }
    }
    'install-mock' {
      if (-not $Zip) { Stop-Fail 'ZIP_MISSING' 'pass -Zip' }
      if (-not $WorkspaceRoot) { Stop-Fail 'WORKSPACE_MISSING' 'pass -WorkspaceRoot' }
      Test-ZipHash $Zip $ExpectedSha256
      $tmp = New-TempDir
      try {
        $pkg = Expand-Zip $Zip $tmp
        $n = Test-Manifest $pkg
        $skillDir = Join-Path $WorkspaceRoot '.agents\skills\bam-memory'
        $mem = Join-Path $WorkspaceRoot 'memory'
        $before = Get-PathSnapshot @($ToolDir, $skillDir, $mem)
        $stage = Stage-SuiteFiles $pkg (Join-Path $tmp 'staging')
        $res = Run-Suite $stage
        $after = Get-PathSnapshot @($ToolDir, $skillDir, $mem)
        $unchanged = ($before.Count -eq $after.Count)
        if ($unchanged) {
          foreach ($k in $before.Keys) {
            if (-not $after.ContainsKey($k) -or ($after[$k] -ne $before[$k])) { $unchanged = $false; break }
          }
        }
        if (-not $res.ok) { Stop-Fail 'SUITE_FAIL' ('suite exit=' + $res.exit + ' tail=' + $res.tail) }
        if (-not $unchanged) { Stop-Fail 'TARGET_MODIFIED' 'install-mock modified the target' }
        $out = [ordered]@{ status = 'PASS'; command = 'install-mock'; suite = [ordered]@{ cases = 33; failed = 0; max_ms = $res.max_ms }; target_unchanged = $true; manifest_entries = $n }
        Write-JsonOut $out
      } finally {
        Remove-TempDir $tmp
      }
    }
    'install' {
      if (-not $Zip) { Stop-Fail 'ZIP_MISSING' 'pass -Zip' }
      if (-not $WorkspaceRoot) { Stop-Fail 'WORKSPACE_MISSING' 'pass -WorkspaceRoot' }
      Test-ZipHash $Zip $ExpectedSha256
      $tmp = New-TempDir
      try {
        $pkg = Expand-Zip $Zip $tmp
        $n = Test-Manifest $pkg
        $stage = Stage-SuiteFiles $pkg (Join-Path $tmp 'staging')
        $res = Run-Suite $stage
        if (-not $res.ok) { Stop-Fail 'SUITE_FAIL' ('suite exit=' + $res.exit + ' tail=' + $res.tail) }
        Test-WorkspaceClean $WorkspaceRoot
        $ph = Get-PkgToolHashes $pkg
        $tdState = Test-ToolDir $ToolDir $ph
        if (-not (Test-Path -LiteralPath $ToolDir)) { New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null }
        $installed = @{}
        foreach ($f in $TOOL_FILES) {
          $dst = Join-Path $ToolDir $f
          if ($tdState -eq 'MATCHING') {
            # byte-identical to this package: reuse in place (no copy)
            $item = Get-Item -LiteralPath $dst
            $installed[$f] = [ordered]@{ sha256 = (Get-Sha256Hex $dst); bytes = $item.Length; reused = $true }
          }
          else {
            Copy-Item -LiteralPath (Join-Path $pkg $f) -Destination $dst -Force
            if ((Get-Sha256Hex $dst) -ne (Get-Sha256Hex (Join-Path $pkg $f))) { Stop-Fail 'INSTALL_HASH_MISMATCH' $f }
            $item = Get-Item -LiteralPath $dst
            $installed[$f] = [ordered]@{ sha256 = (Get-Sha256Hex $dst); bytes = $item.Length; reused = $false }
          }
        }
        $skillDir = Join-Path $WorkspaceRoot '.agents\skills\bam-memory'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        $srcSkill = Join-Path $pkg 'skill\bam-memory\SKILL.md'
        $dstSkill = Join-Path $skillDir 'SKILL.md'
        Copy-Item -LiteralPath $srcSkill -Destination $dstSkill -Force
        if ((Get-Sha256Hex $dstSkill) -ne (Get-Sha256Hex $srcSkill)) { Stop-Fail 'INSTALL_HASH_MISMATCH' 'SKILL.md' }
        $skillItem = Get-Item -LiteralPath $dstSkill
        $installed['skill/bam-memory/SKILL.md'] = [ordered]@{ sha256 = (Get-Sha256Hex $dstSkill); bytes = $skillItem.Length }
        $adapterPath = Join-Path $ToolDir 'bam-adapter.ps1'
        $mem = Join-Path $WorkspaceRoot 'memory'
        $b = Invoke-Adapter $adapterPath @('-Mode', 'Bootstrap', '-Root', $mem)
        if (($b.exit -ne 0) -or (-not $b.parsed) -or ($b.parsed.status -ne 'INITIALIZED')) {
          Stop-Fail 'BOOTSTRAP_FAILED' ('adapter exit=' + $b.exit + ' json=' + $b.json)
        }
        $zipHash = Get-Sha256Hex $Zip
        $receipt = [ordered]@{
          schema = 'bam-install-receipt'
          version = '0.7-portable'
          installed_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
          tool_dir = $ToolDir
          workspace_root = $WorkspaceRoot
          memory_root = $mem
          files = $installed
          zip = [ordered]@{ path = $Zip; sha256 = $zipHash }
          suite = [ordered]@{ cases = 33; failed = 0; max_ms = $res.max_ms }
          tool_dir_state = $tdState
        }
        $receiptPath = Join-Path $skillDir 'INSTALL_RECEIPT.json'
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 10), $enc)
        $out = [ordered]@{ status = 'PASS'; command = 'install'; receipt = $receiptPath; tool_dir_state = $tdState; note = 'MACHINE_CHECK_PASS only. User acceptance is a separate decision.' }
        Write-JsonOut $out
      } finally {
        Remove-TempDir $tmp
      }
    }
    'status-report' {
      if (-not $WorkspaceRoot) { Stop-Fail 'WORKSPACE_MISSING' 'pass -WorkspaceRoot' }
      $skillDir = Join-Path $WorkspaceRoot '.agents\skills\bam-memory'
      $mem = Join-Path $WorkspaceRoot 'memory'
      $tool = @{}
      foreach ($f in $TOOL_FILES) {
        $p = Join-Path $ToolDir $f
        if (Test-Path -LiteralPath $p) {
          $item = Get-Item -LiteralPath $p
          $tool[$f] = [ordered]@{ sha256 = (Get-Sha256Hex $p); bytes = $item.Length }
        } else {
          $tool[$f] = $null
        }
      }
      $skill = $null
      if (Test-Path -LiteralPath $skillDir) {
        $skill = [ordered]@{ skill_md = (Test-Path -LiteralPath (Join-Path $skillDir 'SKILL.md')) }
        $rp = Join-Path $skillDir 'INSTALL_RECEIPT.json'
        if (Test-Path -LiteralPath $rp) {
          try {
            $skill['receipt'] = ([System.IO.File]::ReadAllText($rp, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
          } catch {
            $skill['receipt'] = $null
            $skill['receipt_error'] = $_.Exception.Message
          }
        } else {
          $skill['receipt'] = $null
        }
      }
      $memStatus = $null
      if (Test-Path -LiteralPath $mem) {
        $b = Invoke-Adapter (Join-Path $ToolDir 'bam-adapter.ps1') @('-Mode', 'Status', '-Root', $mem)
        if ($b.parsed) { $memStatus = $b.parsed } else { $memStatus = [ordered]@{ status = 'ERROR'; detail = $b.stderr_tail } }
      }
      # PASS = placement complete AND memory healthy. HOT_STATE that is not FRESH
      # (STALE / UNVERIFIED / MISSING) is recoverable by normal operation: warning.
      # This is a quick health check; the full integrity check is the adapter's
      # -Mode Validate.
      $issues = New-Object System.Collections.Generic.List[string]
      $srWarns = New-Object System.Collections.Generic.List[string]
      foreach ($f in $TOOL_FILES) { if ($tool[$f] -eq $null) { $issues.Add('TOOL_FILE_MISSING:' + $f) } }
      if ($null -eq $skill) { $issues.Add('SKILL_DIR_MISSING') }
      elseif (-not $skill.skill_md) { $issues.Add('SKILL_MD_MISSING') }
      if ($null -eq $skill -or $null -eq $skill.receipt) { $issues.Add('RECEIPT_MISSING') }
      if (-not (Test-Path -LiteralPath $mem)) { $issues.Add('MEMORY_ROOT_MISSING') }
      elseif ($null -eq $memStatus -or $memStatus.status -eq 'ERROR') { $issues.Add('MEMORY_STATUS_ERROR') }
      elseif ($memStatus.status -ne 'OK') { $issues.Add('MEMORY_STATUS_NOT_OK:' + $memStatus.status) }
      elseif ($memStatus.manifest -ne 'OK') { $issues.Add('MEMORY_MANIFEST_NOT_OK:' + $memStatus.manifest) }
      if ($null -ne $memStatus -and $memStatus.status -eq 'OK' -and $memStatus.hot_state -ne 'FRESH') {
        $srWarns.Add('HOT_STATE_' + $memStatus.hot_state)
      }
      if ($issues.Count -gt 0) {
        $out = [ordered]@{ status = 'FAIL'; command = 'status-report'; issues = @($issues); warnings = @($srWarns); tool_dir = $ToolDir; tool_files = $tool; skill = $skill; memory = $memStatus }
        Write-JsonOut $out
        exit 1
      }
      $out = [ordered]@{ status = 'PASS'; command = 'status-report'; issues = @(); warnings = @($srWarns); tool_dir = $ToolDir; tool_files = $tool; skill = $skill; memory = $memStatus }
      Write-JsonOut $out
    }
    'uninstall' {
      Stop-Stop2 'UNINSTALL_DISABLED' 'uninstall is disabled in this build; manual removal only (see PROCEDURE.md)'
    }
    default {
      Stop-Fail 'UNKNOWN_COMMAND' ('valid: verify-artifact / check-target / install-mock / install / status-report / uninstall; got: ' + $Command)
    }
  }
} catch {
  Stop-Fail 'INTERNAL_ERROR' $_.Exception.Message
}

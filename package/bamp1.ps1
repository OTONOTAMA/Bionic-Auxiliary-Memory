# bamp1.ps1 - BAM-P1 portable Core: artifact verification & install helper
# =============================================================================
# Design authority : draft_bam_portable_package_design_20261012_v4.md
#                    (source environment; NOT included in this ZIP)
# Companion docs   : README.md (human), PROCEDURE.md (target LLM),
#                    MANIFEST.sha256 (all files, self excluded)
# Entry (single; human-direct and LLM-assisted paths share it):
#   powershell -NoProfile -ExecutionPolicy Bypass -File bamp1.ps1 <command> <args>
# Commands:
#   verify-artifact  -Zip <path> -ExpectedSha256 <64hex>   XOR   -Tree <path>
#   check-target     -WorkspaceRoot <ws>
#   install-mock     -WorkspaceRoot <ws> [-IncludePortability]
#   install          -WorkspaceRoot <ws> -SkillMode project|global|none
#   status-report
#   uninstall        -WorkspaceRoot <ws> -SkillMode project|global|none
#                     (DISABLED in this build: deletes nothing, prints stop reason, exit 2)
# Exit codes: 0 = PASS / 1 = FAIL (verification failed) / 2 = STOP (conflict /
#   precondition not met / user judgment required). No defaults, no guessing;
#   invalid input => STOP.
# Work data: %TEMP%\bamp1-work\<run-id>\
#   receipts\*.json  UTF-8 no BOM (machine evidence; paths are shown, not logs)
#   REPORT.txt       UTF-8 with BOM (human readable)
# Encoding: this file is UTF-8 WITH BOM (documented verification-gate exception;
#   every other distributed file is UTF-8 without BOM).
# G4 note: the PC-leak patterns below are constructed at runtime from fragments
#   so that this file itself contains none of the forbidden literals.
# This script does NOT: edit distributed docs / build hash tables (verify only)
#   / guess install targets / resolve conflicts by itself / judge test failures
#   / relax expectations / fall back to GLOBAL silently / assert "install
#   success" beyond the machine-verified scope.
# =============================================================================

param(
    [Parameter(Position = 0)] [string]$Command = '',
    [string]$Zip = '',
    [string]$ExpectedSha256 = '',
    [string]$Tree = '',
    [string]$WorkspaceRoot = '',
    [ValidateSet('project', 'global', 'none')] [AllowEmptyString()] [string]$SkillMode = '',
    [switch]$IncludePortability
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $false)
    $script:Utf8Bom   = New-Object System.Text.UTF8Encoding($true,  $false)
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch { }

$script:PsExe = 'powershell.exe'
$script:WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath().TrimEnd('\')) 'bamp1-work')
$script:RunnerTimeoutMs = 2400000   # outer timeout for a full runner suite
$script:ToolTimeoutMs   = 60000     # single memory-tool invocation

# ---- distribution allowlist (12 files; forward slashes; MANIFEST excluded) --
$script:Allowlist = @(
    'payload/draft_bionic_aux_mem/BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md',
    'payload/draft_bionic_aux_mem/01_CANONICAL_NORMATIVE_SPECIFICATION.md',
    'payload/draft_bionic_aux_mem/02_HUMAN_GUIDANCE.md',
    'payload/draft_bionic_aux_mem/03_SCOPE_FREEZE_RECORD.md',
    'payload/draft_bionic_aux_mem/04_TEST_FIRST_SPECIFICATION.md',
    'payload/draft_bionic_aux_mem/05_TEST_SPEC_FREEZE_RECORD.md',
    'payload/tools/memory-tool/memory-tool.ps1',
    'payload/tools/memory-tool/test-memory-tool.ps1',
    'skill/bam-memory/SKILL.md',
    'README.md',
    'PROCEDURE.md',
    'bamp1.ps1'
)

# payload files copied into a workspace root (8 = 6 docs + 2 tools)
$script:PayloadFiles = @(
    'payload/draft_bionic_aux_mem/BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md',
    'payload/draft_bionic_aux_mem/01_CANONICAL_NORMATIVE_SPECIFICATION.md',
    'payload/draft_bionic_aux_mem/02_HUMAN_GUIDANCE.md',
    'payload/draft_bionic_aux_mem/03_SCOPE_FREEZE_RECORD.md',
    'payload/draft_bionic_aux_mem/04_TEST_FIRST_SPECIFICATION.md',
    'payload/draft_bionic_aux_mem/05_TEST_SPEC_FREEZE_RECORD.md',
    'payload/tools/memory-tool/memory-tool.ps1',
    'payload/tools/memory-tool/test-memory-tool.ps1'
)

# PC-leak gate patterns (constructed; see G4 note in header)
$bs = [string][char]92
$script:PcPatterns = @(
    ('h' + 'iroy'),
    ('d49037d8-47f4' + '-5808-9028-c707de117f8f'),
    ('One' + 'Drive'),
    ('scratch' + 'pads'),
    ('C:' + $bs + 'Users' + $bs),
    ('C:/Us' + 'ers/')
)

# AM-T-003.g markers that must exist in the distributed 01 (frozen addendum)
$script:Markers003g = @(
    'Path-safety guarantee scope and accepted residual risk',
    'NO guarantee of complete prevention of check-then-use replacement races',
    'trusted single-user local environment',
    'permits no omission, weakening, or bypass',
    'NOT a safety proof'
)

$script:LastCommand = $Command

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-FileSha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-HasBom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 3) { return $false }
    return ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Test-IsAsciiFile {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    foreach ($x in $b) { if ($x -gt 127) { return $false } }
    return $true
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-Utf8Bom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8Bom)
}

function Get-NormalizedWs {
    param([string]$Path)
    $f = [System.IO.Path]::GetFullPath($Path)
    if ($f.EndsWith('\')) { $f = $f.Substring(0, $f.Length - 1) }
    return $f
}

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-CaseStatus {
    param($SummaryObj, [string]$CaseId)
    $pcs = Get-Prop $SummaryObj 'per_case_status'
    if ($null -eq $pcs) { return 'ABSENT' }
    $p = $pcs.PSObject.Properties[$CaseId]
    if ($null -eq $p) { return 'ABSENT' }
    return [string]$p.Value
}

function Parse-JsonLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return $null }
    try { return ($lines[$lines.Count - 1] | ConvertFrom-Json) } catch { return $null }
}

function New-RunId {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $rnd = ('{0:x4}' -f (Get-Random -Maximum 65536))
    return ('r-' + $ts + '-' + $rnd)
}

function Get-RunRoot {
    param([string]$RunId)
    return (Join-Path $script:WorkRoot $RunId)
}

function New-Run {
    $rid = New-RunId
    $root = Get-RunRoot -RunId $rid
    if (Test-Path -LiteralPath $root) { throw 'run root already exists: ' + $root }
    New-Item -ItemType Directory -Path $root | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'receipts') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'scratch') | Out-Null
    return $root
}

function Get-LatestRunRoot {
    if (-not (Test-Path -LiteralPath $script:WorkRoot)) { return $null }
    $d = Get-ChildItem -LiteralPath $script:WorkRoot -Directory -Force |
        Where-Object { $_.Name -like 'r-*' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $d) { return $null }
    return $d.FullName
}

function Get-LatestReceipt {
    param([string]$RunRoot, [string]$CommandName)
    $dir = Join-Path $RunRoot 'receipts'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $pat = '^' + [regex]::Escape($CommandName) + '-\d{8}T\d{9}Z(-\d+)?\.json$'
    $f = Get-ChildItem -LiteralPath $dir -File -Force |
        Where-Object { $_.Name -match $pat } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $f) { return $null }
    try { return @($f.FullName, ([System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json)) } catch { return $null }
}

function Write-Receipt {
    param([string]$RunRoot, [string]$CommandName, $Data)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $dir = Join-Path $RunRoot 'receipts'
    $path = Join-Path $dir ($CommandName + '-' + $ts + '.json')
    $i = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $dir ($CommandName + '-' + $ts + '-' + $i + '.json')
        $i++
    }
    $json = ($Data | ConvertTo-Json -Depth 12 -Compress)
    Write-Utf8NoBom -Path $path -Text $json
    return $path
}

# Child process invocation. Uses -File with C-style double-quote tokens
# (see ConvertTo-FileArgToken) so values with spaces/Japanese survive the
# PS 5.1 -File legacy tokenizer and non-zero exit codes are NOT clamped
# (the clamp-to-1 behavior was a -Command & artifact, now avoided). Async
# drain + bounded wait + kill.
function ConvertTo-FileArgToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    $n = $Value.Length
    while ($i -lt $n) {
        $c = $Value[$i]
        if ($c -eq '\') {
            $run = 0
            while ($i -lt $n -and $Value[$i] -eq '\') { $run++; $i++ }
            $atEnd = ($i -ge $n)
            $beforeQuote = (-not $atEnd -and $Value[$i] -eq '"')
            if ($atEnd -or $beforeQuote) { [void]$sb.Append(('\' * ($run * 2))) }
            else { [void]$sb.Append(('\' * $run)) }
        }
        elseif ($c -eq '"') { [void]$sb.Append('\"'); $i++ }
        else { [void]$sb.Append($c); $i++ }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Child {
    param([string]$ScriptPath, [string[]]$ArgsTokens, [int]$TimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $tok = foreach ($t in $ArgsTokens) { $s = [string]$t; if ($s.StartsWith('-')) { $s } else { ConvertTo-FileArgToken $s } }
    $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, ($tok -join ' '))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()
    $exited = $p.WaitForExit($TimeoutMs)
    $timedOut = (-not $exited)
    if ($timedOut) {
        try { $p.Kill() } catch { }
        $null = $p.WaitForExit()
    }
    $so = ''; $se = ''
    if (-not $timedOut) {
        if (-not $soTask.Wait(15000)) { $timedOut = $true }
        if (-not $seTask.Wait(15000)) { $timedOut = $true }
    }
    if (-not $timedOut) {
        try { $so = $soTask.Result } catch { }
        try { $se = $seTask.Result } catch { }
    }
    $exitCode = -1
    if (-not $timedOut) { try { $exitCode = $p.ExitCode } catch { $exitCode = -1 } }
    $sw.Stop()
    return @{ exit = $exitCode; stdout = $so; stderr = $se; timed_out = $timedOut; ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 2) }
}

# Copy the 8 payload files from the verified tree into a ws-layout root.
# Records every directory it creates and the post-copy SHA256 of each file.
function Copy-PayloadToWs {
    param([string]$TreeRoot, [string]$WsRoot)
    $created = New-Object System.Collections.Generic.List[string]
    $hashes = [ordered]@{}
    foreach ($rel in $script:PayloadFiles) {
        $src = Join-Path $TreeRoot ($rel -replace '/', '\')
        $dstRel = $rel.Substring('payload/'.Length)
        $dst = Join-Path $WsRoot ($dstRel -replace '/', '\')
        $d = Split-Path $dst -Parent
        while ($d.Length -gt $WsRoot.Length -and -not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d | Out-Null
            $created.Add($d)
            $d = Split-Path $d -Parent
        }
        if (Test-Path -LiteralPath $dst) {
            return @{ ok = $false; error = ('destination exists: ' + $dst); created = @($created); hashes = $hashes }
        }
        Copy-Item -LiteralPath $src -Destination $dst
        $hashes[$dstRel.Replace('\', '/')] = (Get-FileSha256Hex -Path $dst)
    }
    return @{ ok = $true; error = $null; created = @($created); hashes = $hashes }
}

function Stop-Bamp1 {
    param([string]$Reason, [string]$RunRoot = '')
    Write-Host ('STOP: ' + $Reason)
    Write-Host 'exit 2'
    if ($RunRoot -ne '' -and (Test-Path -LiteralPath (Join-Path $RunRoot 'receipts'))) {
        try {
            $null = Write-Receipt -RunRoot $RunRoot -CommandName $script:LastCommand -Data ([ordered]@{
                command = $script:LastCommand
                run_id = (Split-Path $RunRoot -Leaf)
                utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
                result = 'STOP'
                reason = $Reason
            })
        } catch { }
    }
    exit 2
}

function Fail-Bamp1 {
    param([string]$Reason, [string]$RunRoot = '')
    Write-Host ('FAIL: ' + $Reason)
    Write-Host 'exit 1'
    if ($RunRoot -ne '' -and (Test-Path -LiteralPath (Join-Path $RunRoot 'receipts'))) {
        try {
            $null = Write-Receipt -RunRoot $RunRoot -CommandName $script:LastCommand -Data ([ordered]@{
                command = $script:LastCommand
                run_id = (Split-Path $RunRoot -Leaf)
                utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
                result = 'FAIL'
                reason = $Reason
            })
        } catch { }
    }
    exit 1
}

# ---------------------------------------------------------------------------
# verify-artifact
# ---------------------------------------------------------------------------
function Invoke-VerifyArtifact {
    if (($Zip -ne '' -or $ExpectedSha256 -ne '') -and $Tree -ne '') {
        Stop-Bamp1 -Reason 'invalid input: -Zip/-ExpectedSha256 and -Tree are mutually exclusive'
    }
    if ($Zip -ne '' -and $ExpectedSha256 -ne '') {
        $mode = 'zip'
    } elseif ($Tree -ne '') {
        $mode = 'tree'
    } else {
        Stop-Bamp1 -Reason 'invalid input: use (-Zip <p> -ExpectedSha256 <64hex>) or -Tree <p>'
    }
    if ($mode -eq 'zip') {
        if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { Stop-Bamp1 -Reason 'invalid input: -ExpectedSha256 must be 64 hex characters' }
        if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Stop-Bamp1 -Reason ('invalid input: zip not found: ' + $Zip) }
    } else {
        if (-not (Test-Path -LiteralPath $Tree -PathType Container)) { Stop-Bamp1 -Reason ('invalid input: tree directory not found: ' + $Tree) }
    }

    $runRoot = New-Run
    $runId = Split-Path $runRoot -Leaf
    $data = [ordered]@{
        command = 'verify-artifact'
        run_id = $runId
        utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
        mode = $mode
    }

    $treeRoot = $null
    if ($mode -eq 'zip') {
        $zipHash = Get-FileSha256Hex -Path $Zip
        $data['zip_path'] = $Zip
        $data['zip_sha256'] = $zipHash
        $data['expected_sha256'] = $ExpectedSha256.ToUpperInvariant()
        if (-not [string]::Equals($zipHash, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $data['gates'] = [ordered]@{}
            $data['result'] = 'FAIL'
            $null = Write-Receipt -RunRoot $runRoot -CommandName 'verify-artifact' -Data $data
            Fail-Bamp1 -Reason ('zip SHA256 mismatch (zip=' + $zipHash + ' expected=' + $ExpectedSha256.ToUpperInvariant() + ')') -RunRoot $runRoot
        }
        # Path sanity BEFORE extraction (design SS6 / SS3.2)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipAbs = (Resolve-Path -LiteralPath $Zip).Path
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipAbs)
        $badEntry = ''
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName -replace '\\', '/'
                if ($name -eq '') { $badEntry = 'EMPTY_NAME'; break }
                if ($name.StartsWith('/')) { $badEntry = 'ABSOLUTE:' + $name; break }
                if ($name -match '^[A-Za-z]:') { $badEntry = 'DRIVE:' + $name; break }
                if ($name.StartsWith('//')) { $badEntry = 'UNC:' + $name; break }
                $segs = $name -split '/'
                foreach ($sg in $segs) {
                    if ($sg -eq '..') { $badEntry = 'PARENT_REF:' + $name; break }
                    if ($sg -eq '') { $badEntry = 'EMPTY_SEGMENT:' + $name; break }
                }
                if ($badEntry -ne '') { break }
                $norm = [System.IO.Path]::GetFullPath((Join-Path $runRoot ('extracted' + '\' + ($name -replace '/', '\'))))
                $prefix = ((Join-Path $runRoot 'extracted') + '\')
                if (-not $norm.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $badEntry = 'ESCAPES_EXTRACT:' + $name; break }
            }
        } finally { $zip.Dispose() }
        if ($badEntry -ne '') {
            $data['gates'] = [ordered]@{}
            $data['bad_zip_entry'] = $badEntry
            $data['result'] = 'FAIL'
            $null = Write-Receipt -RunRoot $runRoot -CommandName 'verify-artifact' -Data $data
            Fail-Bamp1 -Reason ('unsafe zip entry (checked before extraction): ' + $badEntry) -RunRoot $runRoot
        }
        $extractDir = Join-Path $runRoot 'extracted'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipAbs, $extractDir)
        $data['extracted_to'] = $extractDir
        # Locate the tree root inside the extraction
        $candidates = New-Object System.Collections.Generic.List[string]
        $t1 = Join-Path $extractDir 'bamp1-portable'
        if ((Test-Path -LiteralPath (Join-Path $t1 'bamp1.ps1')) -and (Test-Path -LiteralPath (Join-Path $t1 'MANIFEST.sha256'))) { $candidates.Add($t1) }
        if ((Test-Path -LiteralPath (Join-Path $extractDir 'bamp1.ps1')) -and (Test-Path -LiteralPath (Join-Path $extractDir 'MANIFEST.sha256'))) { $candidates.Add($extractDir) }
        foreach ($d in (Get-ChildItem -LiteralPath $extractDir -Directory)) {
            if ((Test-Path -LiteralPath (Join-Path $d.FullName 'bamp1.ps1')) -and (Test-Path -LiteralPath (Join-Path $d.FullName 'MANIFEST.sha256'))) {
                # fix #6: do not double-count the same physical directory already added via the $t1 check
                if ([System.IO.Path]::GetFullPath($d.FullName) -cne [System.IO.Path]::GetFullPath($t1)) { $candidates.Add($d.FullName) }
            }
        }
        if ($candidates.Count -ne 1) {
            $data['gates'] = [ordered]@{}
            $data['result'] = 'FAIL'
            $null = Write-Receipt -RunRoot $runRoot -CommandName 'verify-artifact' -Data $data
            Fail-Bamp1 -Reason ('zip tree root not uniquely found (candidates=' + $candidates.Count + ')') -RunRoot $runRoot
        }
        $treeRoot = $candidates[0]
    } else {
        $treeRoot = (Resolve-Path -LiteralPath $Tree).Path
    }
    $data['tree_root'] = $treeRoot

    # ---- tree gates G0..G5 ----
    $gates = [ordered]@{}
    $gnotes = [ordered]@{}
    $filesHashes = [ordered]@{}

    # G0: 13 entry files present (12 allowlist + MANIFEST)
    $missing = @()
    foreach ($rel in $script:Allowlist) {
        if (-not (Test-Path -LiteralPath (Join-Path $treeRoot ($rel -replace '/', '\')) -PathType Leaf)) { $missing += $rel }
    }
    $manPath = Join-Path $treeRoot 'MANIFEST.sha256'
    if (-not (Test-Path -LiteralPath $manPath -PathType Leaf)) { $missing += 'MANIFEST.sha256' }
    $g0ok = ($missing.Count -eq 0)
    $gates['G0_entries_present'] = $(if ($g0ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G0_missing'] = $missing

    # G1: MANIFEST 12 lines, self excluded, per-line hash, set equality
    $g1ok = $false
    $g1notes = @()
    if ($g0ok) {
        $manLines = @([System.IO.File]::ReadAllText($manPath) -split "`r?`n" | Where-Object { $_ -ne '' })
        if ($manLines.Count -ne 12) { $g1notes += ('line_count=' + $manLines.Count + ' != 12') }
        $manSet = @{}
        foreach ($ln in $manLines) {
            $m = [regex]::Match($ln, '^([0-9A-Fa-f]{64})  (\S+)$')
            if (-not $m.Success) { $g1notes += ('bad_line:' + $ln); continue }
            $rp = $m.Groups[2].Value
            if ($rp -eq 'MANIFEST.sha256') { $g1notes += 'self_entry_present'; continue }
            $manSet[$rp] = $m.Groups[1].Value.ToUpperInvariant()
        }
        foreach ($rel in $script:Allowlist) { if (-not $manSet.ContainsKey($rel)) { $g1notes += ('not_in_manifest:' + $rel) } }
        foreach ($k in $manSet.Keys) { if (-not ($script:Allowlist -contains $k)) { $g1notes += ('not_in_allowlist:' + $k) } }
        $diskSet = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $treeRoot -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($treeRoot.Length).TrimStart('\').Replace('\', '/')
            if ($rel -eq 'MANIFEST.sha256') { continue }
            $diskSet[$rel] = $true
        }
        foreach ($k in $diskSet.Keys) { if (-not ($script:Allowlist -contains $k)) { $g1notes += ('extra_file_on_disk:' + $k) } }
        foreach ($rel in $script:Allowlist) {
            if (-not $diskSet.ContainsKey($rel)) { $g1notes += ('absent_on_disk:' + $rel) }
            if (-not $manSet.ContainsKey($rel)) { continue }
            $h = Get-FileSha256Hex -Path (Join-Path $treeRoot ($rel -replace '/', '\'))
            $filesHashes[$rel] = $h
            if ($h -cne $manSet[$rel]) { $g1notes += ('hash_mismatch:' + $rel) }
        }
        $g1ok = ($g1notes.Count -eq 0)
    }
    $gates['G1_manifest'] = $(if ($g1ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G1_notes'] = $g1notes

    # G2: BOM rules (bamp1.ps1 has BOM; the other 12 have none)
    $g2ok = $g0ok
    $g2notes = @()
    if ($g0ok) {
        if (-not (Test-HasBom -Path (Join-Path $treeRoot 'bamp1.ps1'))) { $g2ok = $false; $g2notes += 'bamp1.ps1_missing_BOM' }
        foreach ($rel in $script:Allowlist) {
            if ($rel -eq 'bamp1.ps1') { continue }
            if (Test-HasBom -Path (Join-Path $treeRoot ($rel -replace '/', '\'))) { $g2ok = $false; $g2notes += ('unexpected_BOM:' + $rel) }
        }
    }
    $gates['G2_bom'] = $(if ($g2ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G2_notes'] = $g2notes

    # G3: payload tool + runner are ASCII-only
    $g3ok = $g0ok
    $g3notes = @()
    if ($g0ok) {
        foreach ($rel in @('payload/tools/memory-tool/memory-tool.ps1', 'payload/tools/memory-tool/test-memory-tool.ps1')) {
            if (-not (Test-IsAsciiFile -Path (Join-Path $treeRoot ($rel -replace '/', '\')))) { $g3ok = $false; $g3notes += ('non_ascii_payload:' + $rel) }
        }
    }
    $gates['G3_payload_ascii'] = $(if ($g3ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G3_notes'] = $g3notes

    # G4: PC-leak strings: 0 hits across all 13 files
    $g4ok = $g0ok
    $g4notes = @()
    if ($g0ok) {
        foreach ($rel in (@('MANIFEST.sha256') + $script:Allowlist)) {
            $txt = [System.IO.File]::ReadAllText((Join-Path $treeRoot ($rel -replace '/', '\')))
            foreach ($pat in $script:PcPatterns) {
                if ($txt.IndexOf($pat, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $g4ok = $false; $g4notes += ('pc_pattern_found_in:' + $rel) }
            }
        }
    }
    $gates['G4_pc_strings'] = $(if ($g4ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G4_hits'] = $g4notes

    # G5: AM-T-003.g 5 markers present in distributed 01
    $g5ok = $g0ok
    $g5notes = @()
    if ($g0ok) {
        $t01 = [System.IO.File]::ReadAllText((Join-Path $treeRoot 'payload\draft_bionic_aux_mem\01_CANONICAL_NORMATIVE_SPECIFICATION.md'))
        foreach ($mk in $script:Markers003g) {
            if ($t01.IndexOf($mk, [System.StringComparison]::Ordinal) -lt 0) { $g5ok = $false; $g5notes += ('marker_missing:' + $mk) }
        }
    }
    $gates['G5_003g_markers'] = $(if ($g5ok) { 'PASS' } else { 'FAIL' })
    $gnotes['G5_missing'] = $g5notes

    $allPass = ($g0ok -and $g1ok -and $g2ok -and $g3ok -and $g4ok -and $g5ok)
    $data['gates'] = $gates
    $data['gate_notes'] = $gnotes
    $data['file_hashes'] = $filesHashes
    $data['result'] = $(if ($allPass) { 'PASS' } else { 'FAIL' })
    $receiptPath = Write-Receipt -RunRoot $runRoot -CommandName 'verify-artifact' -Data $data

    Write-Host ('verify-artifact: ' + $data['result'] + ' (mode=' + $mode + ', run=' + $runId + ')')
    foreach ($g in $gates.Keys) { Write-Host ('  ' + $g + ': ' + $gates[$g]) }
    if (-not $allPass) { foreach ($k in $gnotes.Keys) { if (@($gnotes[$k]).Count -gt 0) { Write-Host ('  detail ' + $k + ': ' + (($gnotes[$k] -join ' | '))) } } }
    Write-Host ('receipt: ' + $receiptPath)
    if ($allPass) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------------------
# check-target
# ---------------------------------------------------------------------------
function Invoke-CheckTarget {
    if ($WorkspaceRoot -eq '') { Stop-Bamp1 -Reason 'invalid input: -WorkspaceRoot required' }
    $ws = Get-NormalizedWs -Path $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $ws -PathType Container)) { Stop-Bamp1 -Reason ('workspace does not exist: ' + $ws) }

    $runRoot = Get-LatestRunRoot
    if ($null -eq $runRoot) { Stop-Bamp1 -Reason 'no verify-artifact run found; run verify-artifact first' }
    $vr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'verify-artifact'
    if (($null -eq $vr) -or ((Get-Prop $vr[1] 'result') -cne 'PASS')) { Stop-Bamp1 -Reason 'no PASS verify-artifact receipt in latest run; run verify-artifact first' -RunRoot $runRoot }

    $psMajor = [int]$PSVersionTable.PSVersion.Major
    if ($psMajor -ne 5) { Stop-Bamp1 -Reason ('unsupported PowerShell major version: ' + $psMajor + ' (expected 5)') -RunRoot $runRoot }

    $probe = Join-Path $ws ('.bamp1_probe_' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $writable = $false
    try {
        [System.IO.File]::WriteAllText($probe, 'probe', $script:Utf8NoBom)
        $writable = (Test-Path -LiteralPath $probe)
    } catch { $writable = $false }
    if (Test-Path -LiteralPath $probe) { try { [System.IO.File]::Delete($probe) } catch { } }
    if (-not $writable) { Stop-Bamp1 -Reason ('workspace not writable: ' + $ws) -RunRoot $runRoot }

    $absent = [ordered]@{}
    foreach ($rel in @('memory', 'tools/memory-tool', 'draft_bionic_aux_mem')) {
        $p = Join-Path $ws ($rel -replace '/', '\')
        $e = Test-Path -LiteralPath $p
        $absent[$rel] = (-not $e)
        if ($e) { Stop-Bamp1 -Reason ('existing path blocks install (no overwrite/move/mix): ' + $p) -RunRoot $runRoot }
    }

    $wsParent = Split-Path $ws -Parent
    $projDir = Join-Path (Join-Path (Join-Path $wsParent '.agents') 'skills') 'bam-memory'
    $globDir = Join-Path (Join-Path $env:USERPROFILE '.lmstudio') 'skills\bam-memory'
    $skillInfo = [ordered]@{
        project_dir = $projDir
        project_exists = (Test-Path -LiteralPath $projDir)
        project_json_present = (Test-Path -LiteralPath (Join-Path $wsParent 'project.json'))
        global_dir = $globDir
        global_exists = (Test-Path -LiteralPath $globDir)
    }

    $data = [ordered]@{
        command = 'check-target'
        run_id = (Split-Path $runRoot -Leaf)
        utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
        workspace_root = $ws
        ps_version = [string]$PSVersionTable.PSVersion
        ps_major = $psMajor
        writable_probe = 'PASS'
        absent = $absent
        skill_detection = $skillInfo
        note = 'skill file-level detection only; behavior is NOT verified here (PROCEDURE live section)'
        result = 'PASS'
    }
    $receiptPath = Write-Receipt -RunRoot $runRoot -CommandName 'check-target' -Data $data
    Write-Host ('check-target: PASS (ws=' + $ws + ', PS ' + $PSVersionTable.PSVersion.ToString() + ')')
    Write-Host ('skill detection: project=' + $skillInfo.project_exists + ' global=' + $skillInfo.global_exists + ' (file-level only)')
    Write-Host ('receipt: ' + $receiptPath)
    exit 0
}

# ---------------------------------------------------------------------------
# install-mock
# ---------------------------------------------------------------------------
function Test-Portability {
    param([string]$RunRoot, [string]$TreeRoot, $MockSummaryJson)
    $port = [ordered]@{}
    $allPass = $true
    $scratch = Join-Path $RunRoot 'scratch'
    $toolSrc = Join-Path $TreeRoot 'payload\tools\memory-tool\memory-tool.ps1'
    $runnerSrc = Join-Path $TreeRoot 'payload\tools\memory-tool\test-memory-tool.ps1'

    # P2a: layout mismatch (runner without the tool at the standard location)
    $misTree = Join-Path $RunRoot 'p2_mis_tree'
    $misRunDir = Join-Path (Join-Path $misTree 'tools') 'memory-tool'
    if (-not (Test-Path -LiteralPath $misRunDir)) { New-Item -ItemType Directory -Path $misRunDir -Force | Out-Null }
    Copy-Item -LiteralPath $runnerSrc -Destination (Join-Path $misRunDir 'test-memory-tool.ps1') -Force
    $rMis = Invoke-Child -ScriptPath (Join-Path $misRunDir 'test-memory-tool.ps1') -ArgsTokens @('-All') -TimeoutMs 120000
    $jMis = Parse-JsonLine -Text $rMis.stdout
    $p2a = ($rMis.exit -eq 2 -and ((Get-Prop $jMis 'error') -eq 'LAYOUT_MISMATCH'))
    $port['P2a_layout_mismatch'] = [ordered]@{
        pass = $p2a; exit = $rMis.exit; error = (Get-Prop $jMis 'error')
        stdout = $(if ([string]::IsNullOrWhiteSpace($rMis.stdout)) { '' } else { $rMis.stdout.Trim().Substring(0, [Math]::Min(500, $rMis.stdout.Trim().Length)) })
    }
    if (-not $p2a) { $allPass = $false }

    # P2b: misplaced standalone tool + explicit roots (normal operation, layout-independent)
    $looseDir = Join-Path $RunRoot 'p2_loose'
    $fixWs = Join-Path $RunRoot 'p2_fixture_ws'
    if (-not (Test-Path -LiteralPath $looseDir)) { New-Item -ItemType Directory -Path $looseDir | Out-Null }
    if (-not (Test-Path -LiteralPath $fixWs)) { New-Item -ItemType Directory -Path $fixWs | Out-Null }
    Copy-Item -LiteralPath $toolSrc -Destination (Join-Path $looseDir 'memory-tool.ps1') -Force
    $looseTool = Join-Path $looseDir 'memory-tool.ps1'
    $fixMem = Join-Path $fixWs 'memory'
    $opId = [Guid]::NewGuid().ToString()
    $initSpec = [pscustomobject]@{
        operation_id = $opId
        expected = [pscustomobject]@{ generation = 0; core = 'ABSENT'; index = 'ABSENT'; archive = 'ABSENT' }
        operations = @([pscustomobject]@{ op = 'initialize' })
    }
    $specPath = Join-Path $scratch 'p2b_init_spec.json'
    Write-Utf8NoBom -Path $specPath -Text (($initSpec | ConvertTo-Json -Depth 12 -Compress))
    $rInit = Invoke-Child -ScriptPath $looseTool -ArgsTokens @('-Mode', 'Commit', '-MemoryRoot', $fixMem, '-WorkspaceRoot', $fixWs, '-ScratchpadRoot', $scratch, '-Spec', $specPath) -TimeoutMs $script:ToolTimeoutMs
    $jInit = Parse-JsonLine -Text $rInit.stdout
    $rVal = Invoke-Child -ScriptPath $looseTool -ArgsTokens @('-Mode', 'Validate', '-MemoryRoot', $fixMem, '-WorkspaceRoot', $fixWs) -TimeoutMs $script:ToolTimeoutMs
    $jVal = Parse-JsonLine -Text $rVal.stdout
    $p2b = ($rInit.exit -eq 0 -and ((Get-Prop $jInit 'status') -eq 'PASS') -and $rVal.exit -eq 0 -and ((Get-Prop $jVal 'status') -eq 'PASS'))
    $port['P2b_misplaced_tool_explicit_roots'] = [ordered]@{
        pass = $p2b
        init = [ordered]@{ exit = $rInit.exit; status = (Get-Prop $jInit 'status') }
        validate = [ordered]@{ exit = $rVal.exit; status = (Get-Prop $jVal 'status') }
    }
    if (-not $p2b) { $allPass = $false }

    # P2c: fault seam WITHOUT -TestMode => denied (pair rule)
    $rF1 = Invoke-Child -ScriptPath $looseTool -ArgsTokens @('-Mode', 'Validate', '-MemoryRoot', $fixMem, '-WorkspaceRoot', $fixWs, '-FaultAt', 'FAULT_BEFORE_CURRENT_SWITCH') -TimeoutMs $script:ToolTimeoutMs
    $jF1 = Parse-JsonLine -Text $rF1.stdout
    $p2c = ($rF1.exit -eq 1 -and ((Get-Prop $jF1 'status') -eq 'INVALID') -and (@((Get-Prop $jF1 'diagnostics')) -contains 'FAULT_SEAM_DENIED'))
    $port['P2c_fault_without_testmode_denied'] = [ordered]@{
        pass = $p2c; exit = $rF1.exit; status = (Get-Prop $jF1 'status'); diagnostics = @((Get-Prop $jF1 'diagnostics'))
    }
    if (-not $p2c) { $allPass = $false }

    # P2d: -TestMode -FaultAt against a NON-fixture root => denied (root gate)
    $rF2 = Invoke-Child -ScriptPath $looseTool -ArgsTokens @('-Mode', 'Validate', '-MemoryRoot', $fixMem, '-WorkspaceRoot', $fixWs, '-TestMode', '-FaultAt', 'FAULT_BEFORE_CURRENT_SWITCH') -TimeoutMs $script:ToolTimeoutMs
    $jF2 = Parse-JsonLine -Text $rF2.stdout
    $p2d = ($rF2.exit -eq 1 -and ((Get-Prop $jF2 'status') -eq 'INVALID') -and (@((Get-Prop $jF2 'diagnostics')) -contains 'FAULT_SEAM_DENIED'))
    $port['P2d_fault_nonfixture_root_denied'] = [ordered]@{
        pass = $p2d; exit = $rF2.exit; status = (Get-Prop $jF2 'status'); diagnostics = @((Get-Prop $jF2 'diagnostics'))
        note = 'actual behavior recorded; "safe" is NOT asserted (design SS9.3 P2)'
    }
    if (-not $p2d) { $allPass = $false }

    # P4: second mock ws with spaces + Japanese in the path, full suite
    # (the Japanese directory name is built from code points so this source file stays ASCII-only;
    #  runtime directory name byte-identical to the former literal: w s SP U+7A7A U+767D SP U+65E5 U+672C U+8A9E)
    $jpWsName = ('ws ' + [string][char]0x7A7A + [string][char]0x767D + ' ' + [string][char]0x65E5 + [string][char]0x672C + [string][char]0x8A9E)
    $ws2 = Join-Path $RunRoot $jpWsName
    if ($jpWsName.Length -ne 9) { $port['P4_spaces_japanese_ws'] = [ordered]@{ pass = $false; note = 'JP ws name codepoint self-check failed (length=' + $jpWsName.Length + '); P4 not run' }; $allPass = $false }
    elseif (Test-Path -LiteralPath $ws2) { $port['P4_spaces_japanese_ws'] = [ordered]@{ pass = $false; note = 'ws2 already exists (no mixing)' }; $allPass = $false }
    else {
        New-Item -ItemType Directory -Path $ws2 | Out-Null
        $cp2 = Copy-PayloadToWs -TreeRoot $TreeRoot -WsRoot $ws2
        if ($cp2.ok) {
            $r2 = Invoke-Child -ScriptPath (Join-Path $ws2 'tools\memory-tool\test-memory-tool.ps1') -ArgsTokens @('-All') -TimeoutMs $script:RunnerTimeoutMs
            $j2 = Parse-JsonLine -Text $r2.stdout
            $p4 = ($r2.exit -eq 0 -and $null -ne $j2 -and (Get-Prop $j2 'total_cases') -eq 95 -and (Get-Prop $j2 'fail_cases') -eq 0)
            $port['P4_spaces_japanese_ws'] = [ordered]@{
                pass = $p4; exit = $r2.exit; ms = $r2.ms
                total_cases = (Get-Prop $j2 'total_cases'); pass_cases = (Get-Prop $j2 'pass_cases'); fail_cases = (Get-Prop $j2 'fail_cases')
                note = 'proves quoting fix + self-location with spaces/Japanese in ws-derived paths'
            }
            if (-not $p4) { $allPass = $false }
        } else {
            $port['P4_spaces_japanese_ws'] = [ordered]@{ pass = $false; note = $cp2.error }
            $allPass = $false
        }
    }

    # P5: init + add + recall on the P4 ws (spaces + Japanese paths)
    if ((Get-Prop (Get-Prop $port 'P4_spaces_japanese_ws') 'pass') -eq $true) {
        $mem2 = Join-Path $ws2 'memory'
        $opId2 = [Guid]::NewGuid().ToString()
        $initSpec2 = [pscustomobject]@{
            operation_id = $opId2
            expected = [pscustomobject]@{ generation = 0; core = 'ABSENT'; index = 'ABSENT'; archive = 'ABSENT' }
            operations = @([pscustomobject]@{ op = 'initialize' })
        }
        $spec2 = Join-Path $scratch 'p5_init_spec.json'
        Write-Utf8NoBom -Path $spec2 -Text (($initSpec2 | ConvertTo-Json -Depth 12 -Compress))
        $tool2 = Join-Path $ws2 'tools\memory-tool\memory-tool.ps1'
        $rI2 = Invoke-Child -ScriptPath $tool2 -ArgsTokens @('-Mode', 'Commit', '-MemoryRoot', $mem2, '-WorkspaceRoot', $ws2, '-ScratchpadRoot', $scratch, '-Spec', $spec2) -TimeoutMs $script:ToolTimeoutMs
        $jI2 = Parse-JsonLine -Text $rI2.stdout
        $rS2 = Invoke-Child -ScriptPath $tool2 -ArgsTokens @('-Mode', 'Status', '-MemoryRoot', $mem2, '-WorkspaceRoot', $ws2) -TimeoutMs $script:ToolTimeoutMs
        $jS2 = Parse-JsonLine -Text $rS2.stdout
        $stId = Get-Prop $jS2 'state_id'
        $addSpec = [pscustomobject]@{
            operation_id = [Guid]::NewGuid().ToString()
            expected = [pscustomobject]@{
                generation = [int](Get-Prop $stId 'generation')
                core = [string](Get-Prop $stId 'core_sha256')
                index = [string](Get-Prop $stId 'index_sha256')
                archive = [string](Get-Prop $stId 'archive_sha256')
            }
            operations = @([pscustomobject]@{
                op = 'add'
                subject = 'BAM-P1-TEST: portable probe'
                summary = 'portability recall probe P5'
                provenance = 'USER_STATED'
                tags = @('bamp1-test')
                note = 'P5 probe note (portability check)'
            })
        }
        $specA = Join-Path $scratch 'p5_add_spec.json'
        Write-Utf8NoBom -Path $specA -Text (($addSpec | ConvertTo-Json -Depth 12 -Compress))
        $rA2 = Invoke-Child -ScriptPath $tool2 -ArgsTokens @('-Mode', 'Commit', '-MemoryRoot', $mem2, '-WorkspaceRoot', $ws2, '-ScratchpadRoot', $scratch, '-Spec', $specA) -TimeoutMs $script:ToolTimeoutMs
        $jA2 = Parse-JsonLine -Text $rA2.stdout
        $rR2 = Invoke-Child -ScriptPath $tool2 -ArgsTokens @('-Mode', 'Recall', '-MemoryRoot', $mem2, '-WorkspaceRoot', $ws2, '-Query', 'portability recall probe P5') -TimeoutMs $script:ToolTimeoutMs
        $jR2 = Parse-JsonLine -Text $rR2.stdout
        $p5 = ($rI2.exit -eq 0 -and ((Get-Prop $jI2 'status') -eq 'PASS') -and $rA2.exit -eq 0 -and ((Get-Prop $jA2 'status') -eq 'PASS') -and $rR2.exit -eq 0 -and ((Get-Prop $jR2 'status') -eq 'HIT'))
        $port['P5_recall_spaces_japanese'] = [ordered]@{
            pass = $p5
            init = [ordered]@{ exit = $rI2.exit; status = (Get-Prop $jI2 'status') }
            add = [ordered]@{ exit = $rA2.exit; status = (Get-Prop $jA2 'status') }
            recall = [ordered]@{ exit = $rR2.exit; status = (Get-Prop $jR2 'status') }
        }
        if (-not $p5) { $allPass = $false }
    } else {
        $port['P5_recall_spaces_japanese'] = [ordered]@{ pass = $false; note = 'skipped: P4 not PASS (no silent pass)' }
        $allPass = $false
    }

    # P6: timeout pattern (5s sleep child, 1s timeout) via the same Invoke-Child
    $sleepScript = Join-Path $RunRoot 'bamp1_p6_sleep.ps1'
    Write-Utf8NoBom -Path $sleepScript -Text "Start-Sleep -Seconds 5`nWrite-Output 'BAMP1P6DONE'`n"
    $r6 = Invoke-Child -ScriptPath $sleepScript -ArgsTokens @() -TimeoutMs 1000
    $residual = @()
    try {
        $residual = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*bamp1_p6_sleep.ps1*' })
    } catch { }
    $p6 = ($r6.timed_out -eq $true -and [double]$r6.ms -lt 4000 -and $r6.exit -eq -1 -and $residual.Count -eq 0)
    $port['P6_timeout_pattern'] = [ordered]@{
        pass = $p6; timed_out = $r6.timed_out; ms = $r6.ms; exit = $r6.exit
        residual_child_processes = $residual.Count
        note = 'bounded wait + async drain + kill; child killed, no 180s wait'
    }
    if (-not $p6) { $allPass = $false }

    # P3: production fault denial + all fault cases from the standard mock suite
    $pcs = Get-Prop $MockSummaryJson 'per_case_status'
    $faultIds = @()
    if ($null -ne $pcs) { $faultIds = @($pcs.PSObject.Properties | Where-Object { $_.Name -like 'AM-T-006*' } | ForEach-Object { $_.Name }) }
    $faultAllPass = $true
    foreach ($fid in $faultIds) { if ((Get-CaseStatus -SummaryObj $MockSummaryJson -CaseId $fid) -cne 'PASS') { $faultAllPass = $false } }
    $p3 = ($faultAllPass -and (Get-CaseStatus -SummaryObj $MockSummaryJson -CaseId 'AM-T-006.u') -eq 'PASS')
    $port['P3_prod_fault_rejection_from_mock'] = [ordered]@{
        pass = $p3; fault_case_count = $faultIds.Count
        note = 'evidence extracted from the standard mock suite (no new run)'
    }
    if (-not $p3) { $allPass = $false }

    return @{ ok = $allPass; port = $port }
}

function Invoke-InstallMock {
    if ($WorkspaceRoot -eq '') { Stop-Bamp1 -Reason 'invalid input: -WorkspaceRoot required' }
    $ws = Get-NormalizedWs -Path $WorkspaceRoot

    $runRoot = Get-LatestRunRoot
    if ($null -eq $runRoot) { Stop-Bamp1 -Reason 'no verify-artifact run found; run verify-artifact first' }
    $vr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'verify-artifact'
    if (($null -eq $vr) -or ((Get-Prop $vr[1] 'result') -cne 'PASS')) { Stop-Bamp1 -Reason 'no PASS verify-artifact receipt in latest run' -RunRoot $runRoot }
    $cr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'check-target'
    if (($null -eq $cr) -or ((Get-Prop $cr[1] 'result') -cne 'PASS') -or ((Get-Prop $cr[1] 'workspace_root') -cne $ws)) {
        Stop-Bamp1 -Reason 'no PASS check-target receipt for this workspace in latest run' -RunRoot $runRoot
    }
    $treeRoot = [string](Get-Prop $vr[1] 'tree_root')
    if (-not (Test-Path -LiteralPath $treeRoot)) { Stop-Bamp1 -Reason ('verify tree no longer exists: ' + $treeRoot) -RunRoot $runRoot }

    $mockWs = Join-Path $runRoot 'mock_ws'
    if (Test-Path -LiteralPath $mockWs) { Stop-Bamp1 -Reason 'mock_ws already exists in this run (no mixing); run verify-artifact again for a fresh run' -RunRoot $runRoot }
    New-Item -ItemType Directory -Path $mockWs | Out-Null

    $cp = Copy-PayloadToWs -TreeRoot $treeRoot -WsRoot $mockWs
    if (-not $cp.ok) { Fail-Bamp1 -Reason $cp.error -RunRoot $runRoot }
    $vh = Get-Prop $vr[1] 'file_hashes'
    $hashFail = @()
    foreach ($k in @($cp.hashes.Keys)) {
        $expect = Get-Prop $vh ('payload/' + $k)
        if ($null -eq $expect) { $hashFail += ('no_expected_hash:' + $k) }
        elseif ([string]$expect -cne [string]$cp.hashes[$k]) { $hashFail += ('hash_mismatch_after_copy:' + $k) }
    }
    if ($hashFail.Count -gt 0) { Fail-Bamp1 -Reason ('post-copy hash check failed: ' + ($hashFail -join ' | ')) -RunRoot $runRoot }

    $r = Invoke-Child -ScriptPath (Join-Path $mockWs 'tools\memory-tool\test-memory-tool.ps1') -ArgsTokens @('-All') -TimeoutMs $script:RunnerTimeoutMs
    $j = Parse-JsonLine -Text $r.stdout
    $runnerPass = ($r.exit -eq 0 -and $null -ne $j -and (Get-Prop $j 'total_cases') -eq 95 -and (Get-Prop $j 'fail_cases') -eq 0)
    $stderrTail = [string]$r.stderr
    if ($stderrTail.Length -gt 2000) { $stderrTail = $stderrTail.Substring($stderrTail.Length - 2000) }

    $data = [ordered]@{
        command = 'install-mock'
        run_id = (Split-Path $runRoot -Leaf)
        utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
        workspace_root = $ws
        mock_ws = $mockWs
        include_portability = [bool]$IncludePortability
        copy_hash_check = 'PASS'
        runner = [ordered]@{
            exit = $r.exit; timed_out = $r.timed_out; ms = $r.ms
            total_cases = (Get-Prop $j 'total_cases'); pass_cases = (Get-Prop $j 'pass_cases'); fail_cases = (Get-Prop $j 'fail_cases')
            failing_case_ids = @((Get-Prop $j 'failing_case_ids'))
            failing_reasons = (Get-Prop $j 'failing_reasons')
            stderr_tail = $stderrTail
        }
    }

    $result = 'PASS'
    if ($IncludePortability) {
        $pt = Test-Portability -RunRoot $runRoot -TreeRoot $treeRoot -MockSummaryJson $j
        $data['portability'] = $pt.port
        if (-not $pt.ok) { $result = 'FAIL' }
    }
    if (-not $runnerPass) { $result = 'FAIL' }
    $data['result'] = $result
    $data['note'] = 'mock verification only - awaiting user approval before install (no automatic advance)'
    $receiptPath = Write-Receipt -RunRoot $runRoot -CommandName 'install-mock' -Data $data

    Write-Host ('install-mock: ' + $result + ' (mock selftest exit=' + $r.exit + ' total=' + (Get-Prop $j 'total_cases') + ' fail=' + (Get-Prop $j 'fail_cases') + ', ' + [string]$r.ms + ' ms)')
    if ($IncludePortability) {
        foreach ($pk in $pt.port.Keys) { Write-Host ('  ' + $pk + ': ' + $(if ((Get-Prop $pt.port[$pk] 'pass') -eq $true) { 'PASS' } else { 'FAIL' })) }
    }
    Write-Host ('AWAITING USER APPROVAL: mock verification only; user approval is required before install.')
    Write-Host ('receipt: ' + $receiptPath)
    if ($result -eq 'PASS') { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
function Invoke-Install {
    if ($WorkspaceRoot -eq '') { Stop-Bamp1 -Reason 'invalid input: -WorkspaceRoot required' }
    if ($SkillMode -eq '') { Stop-Bamp1 -Reason 'invalid input: -SkillMode required (project|global|none)' }
    $ws = Get-NormalizedWs -Path $WorkspaceRoot

    $runRoot = Get-LatestRunRoot
    if ($null -eq $runRoot) { Stop-Bamp1 -Reason 'no run found; run verify-artifact first' }
    $vr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'verify-artifact'
    $cr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'check-target'
    $mr = Get-LatestReceipt -RunRoot $runRoot -CommandName 'install-mock'
    if (($null -eq $vr) -or ((Get-Prop $vr[1] 'result') -cne 'PASS')) { Stop-Bamp1 -Reason 'missing PASS verify-artifact receipt' -RunRoot $runRoot }
    if (($null -eq $cr) -or ((Get-Prop $cr[1] 'result') -cne 'PASS') -or ((Get-Prop $cr[1] 'workspace_root') -cne $ws)) { Stop-Bamp1 -Reason 'missing PASS check-target receipt for this workspace' -RunRoot $runRoot }
    if (($null -eq $mr) -or ((Get-Prop $mr[1] 'result') -cne 'PASS') -or ((Get-Prop $mr[1] 'workspace_root') -cne $ws)) { Stop-Bamp1 -Reason 'missing PASS install-mock receipt for this workspace (user approval step)' -RunRoot $runRoot }
    $treeRoot = [string](Get-Prop $vr[1] 'tree_root')
    if (-not (Test-Path -LiteralPath $treeRoot)) { Stop-Bamp1 -Reason ('verify tree no longer exists: ' + $treeRoot) -RunRoot $runRoot }

    # skill-conflict gate (BEFORE any deployment, all SkillModes): a same-name
    # skill at either placement target is a conflict. No overwrite, no
    # self-resolution: STOP and let the user decide.
    $wsParentGate = Split-Path $ws -Parent
    $gateProject = Join-Path (Join-Path (Join-Path $wsParentGate '.agents') 'skills') 'bam-memory'
    $gateGlobal = Join-Path (Join-Path $env:USERPROFILE '.lmstudio') 'skills\bam-memory'
    $gateHits = @()
    foreach ($g in @($gateProject, $gateGlobal)) { if (Test-Path -LiteralPath $g) { $gateHits += $g } }
    if ($gateHits.Count -gt 0) { Stop-Bamp1 -Reason ('same-name skill path(s) already exist (conflict; no overwrite, no self-resolution): ' + ($gateHits -join ' | ')) -RunRoot $runRoot }

    # immediate re-ABSENT
    foreach ($rel in @('memory', 'tools/memory-tool', 'draft_bionic_aux_mem')) {
        $p = Join-Path $ws ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $p) { Stop-Bamp1 -Reason ('path appeared since check-target (no overwrite/move/mix): ' + $p) -RunRoot $runRoot }
    }

    $cp = Copy-PayloadToWs -TreeRoot $treeRoot -WsRoot $ws
    if (-not $cp.ok) { Fail-Bamp1 -Reason $cp.error -RunRoot $runRoot }
    $vh = Get-Prop $vr[1] 'file_hashes'
    $hashFail = @()
    foreach ($k in @($cp.hashes.Keys)) {
        $expect = Get-Prop $vh ('payload/' + $k)
        if (($null -eq $expect) -or ([string]$expect -cne [string]$cp.hashes[$k])) { $hashFail += $k }
    }
    if ($hashFail.Count -gt 0) { Fail-Bamp1 -Reason ('post-copy hash check failed: ' + ($hashFail -join ' | ')) -RunRoot $runRoot }

    $scratch = Join-Path $runRoot 'scratch'
    $tool = Join-Path $ws 'tools\memory-tool\memory-tool.ps1'
    $mem = Join-Path $ws 'memory'

    # empty initialization (immediate ABSENT re-check above)
    $initSpec = [pscustomobject]@{
        operation_id = [Guid]::NewGuid().ToString()
        expected = [pscustomobject]@{ generation = 0; core = 'ABSENT'; index = 'ABSENT'; archive = 'ABSENT' }
        operations = @([pscustomobject]@{ op = 'initialize' })
    }
    $specPath = Join-Path $scratch 'bamp1_init_spec.json'
    Write-Utf8NoBom -Path $specPath -Text (($initSpec | ConvertTo-Json -Depth 12 -Compress))
    $rInit = Invoke-Child -ScriptPath $tool -ArgsTokens @('-Mode', 'Commit', '-MemoryRoot', $mem, '-WorkspaceRoot', $ws, '-ScratchpadRoot', $scratch, '-Spec', $specPath) -TimeoutMs $script:ToolTimeoutMs
    $jInit = Parse-JsonLine -Text $rInit.stdout
    if (($rInit.exit -ne 0) -or ((Get-Prop $jInit 'status') -cne 'PASS')) { Fail-Bamp1 -Reason ('initialize failed (exit=' + $rInit.exit + ' status=' + (Get-Prop $jInit 'status') + ')') -RunRoot $runRoot }

    $rVal = Invoke-Child -ScriptPath $tool -ArgsTokens @('-Mode', 'Validate', '-MemoryRoot', $mem, '-WorkspaceRoot', $ws) -TimeoutMs $script:ToolTimeoutMs
    $jVal = Parse-JsonLine -Text $rVal.stdout
    if (($rVal.exit -ne 0) -or ((Get-Prop $jVal 'status') -cne 'PASS')) { Fail-Bamp1 -Reason ('validate failed (exit=' + $rVal.exit + ' status=' + (Get-Prop $jVal 'status') + ')') -RunRoot $runRoot }

    $rSt = Invoke-Child -ScriptPath $tool -ArgsTokens @('-Mode', 'Status', '-MemoryRoot', $mem, '-WorkspaceRoot', $ws) -TimeoutMs $script:ToolTimeoutMs
    $jSt = Parse-JsonLine -Text $rSt.stdout
    if (($rSt.exit -ne 0) -or ((Get-Prop $jSt 'status') -cne 'PASS')) { Fail-Bamp1 -Reason ('status failed after init (exit=' + $rSt.exit + ')') -RunRoot $runRoot }
    $stId = Get-Prop $jSt 'state_id'
    $baseline = [ordered]@{
        generation = [int](Get-Prop $stId 'generation')
        core = [string](Get-Prop $stId 'core_sha256')
        index = [string](Get-Prop $stId 'index_sha256')
        archive = [string](Get-Prop $stId 'archive_sha256')
        generation_count = (Get-Prop $jSt 'generation_count')
        completed_bytes_total = (Get-Prop $jSt 'completed_bytes_total')
        active_generation_bytes = (Get-Prop $jSt 'active_generation_bytes')
        largest_generation_bytes = (Get-Prop $jSt 'largest_generation_bytes')
        noncanonical_bytes = (Get-Prop $jSt 'noncanonical_bytes')
        receipt_count = (Get-Prop $jSt 'receipt_count')
        receipt_bytes_total = (Get-Prop $jSt 'receipt_bytes_total')
    }

    # production selftest (006.u protects the real prod root inside <ws>)
    $rSelf = Invoke-Child -ScriptPath (Join-Path $ws 'tools\memory-tool\test-memory-tool.ps1') -ArgsTokens @('-All') -TimeoutMs $script:RunnerTimeoutMs
    $jSelf = Parse-JsonLine -Text $rSelf.stdout
    $selftestPass = ($rSelf.exit -eq 0 -and $null -ne $jSelf -and (Get-Prop $jSelf 'total_cases') -eq 95 -and (Get-Prop $jSelf 'fail_cases') -eq 0)
    if (-not $selftestPass) { Fail-Bamp1 -Reason ('production selftest failed (exit=' + $rSelf.exit + ' fail=' + (Get-Prop $jSelf 'fail_cases') + ')') -RunRoot $runRoot }

    $rSt2 = Invoke-Child -ScriptPath $tool -ArgsTokens @('-Mode', 'Status', '-MemoryRoot', $mem, '-WorkspaceRoot', $ws) -TimeoutMs $script:ToolTimeoutMs
    $jSt2 = Parse-JsonLine -Text $rSt2.stdout
    # post-selftest Status HARD gate: any failure or state mismatch => NOT PASS.
    # (The previous silent recording of a degraded status was a defect.)
    $postGen = [int](Get-Prop $stId 'generation')
    $postFail = @()
    if ($rSt2.exit -ne 0) { $postFail += ('exit=' + $rSt2.exit) }
    elseif ($null -eq $jSt2) { $postFail += 'status_output_unparseable' }
    else {
        if ((Get-Prop $jSt2 'status') -cne 'PASS') { $postFail += ('status=' + (Get-Prop $jSt2 'status')) }
        $postState = Get-Prop $jSt2 'state_id'
        if ($null -eq $postState) { $postFail += 'state_id_missing' }
        else {
            $postGen = [int](Get-Prop $postState 'generation')
            if ($postGen -ne [int](Get-Prop $stId 'generation')) { $postFail += ('generation=' + $postGen) }
            if ([string](Get-Prop $postState 'core_sha256') -cne [string](Get-Prop $stId 'core_sha256')) { $postFail += 'core_sha256_changed' }
            if ([string](Get-Prop $postState 'index_sha256') -cne [string](Get-Prop $stId 'index_sha256')) { $postFail += 'index_sha256_changed' }
            if ([string](Get-Prop $postState 'archive_sha256') -cne [string](Get-Prop $stId 'archive_sha256')) { $postFail += 'archive_sha256_changed' }
        }
    }
    $genUnchanged = ($postFail.Count -eq 0)
    if (-not $genUnchanged) { Fail-Bamp1 -Reason ('post-selftest Status hard gate: mismatch after selftest (install is NOT PASS): ' + ($postFail -join ', ')) -RunRoot $runRoot }

    # skill placement
    $createdDirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($cp.created)) { $createdDirs.Add($d) }
    $createdDirs.Add($mem)
    $skillInfo = [ordered]@{}
    if ($SkillMode -eq 'project') {
        $wsParent = Split-Path $ws -Parent
        $skillDir = Join-Path (Join-Path (Join-Path $wsParent '.agents') 'skills') 'bam-memory'
        if (Test-Path -LiteralPath $skillDir) { Stop-Bamp1 -Reason ('skill dir already exists (no overwrite): ' + $skillDir) -RunRoot $runRoot }
        foreach ($d in @((Join-Path $wsParent '.agents'), (Join-Path (Join-Path $wsParent '.agents') 'skills'), $skillDir)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null; $createdDirs.Add($d) }
        }
        $srcSkill = Join-Path $treeRoot 'skill\bam-memory\SKILL.md'
        $dstSkill = Join-Path $skillDir 'SKILL.md'
        Copy-Item -LiteralPath $srcSkill -Destination $dstSkill
        $skillHash = Get-FileSha256Hex -Path $dstSkill
        $expectSkill = Get-Prop $vh 'skill/bam-memory/SKILL.md'
        if ([string]$expectSkill -cne $skillHash) { Stop-Bamp1 -Reason 'SKILL.md hash mismatch after copy' -RunRoot $runRoot }
        $skillInfo = [ordered]@{
            mode = 'project'
            installed = $true
            skill_dir = $skillDir
            skill_file = $dstSkill
            skill_sha256 = $skillHash
        }
    } elseif ($SkillMode -eq 'global') {
        $skillInfo = [ordered]@{
            mode = 'global'
            installed = $false
            note = 'global skill is NOT installed by this script (Bionic rule: global skills only via skill.install with user approval). AI action: run skill.install with SKILL.md at ' + (Join-Path $treeRoot 'skill\bam-memory\SKILL.md')
        }
    } else {
        $skillInfo = [ordered]@{ mode = 'none'; installed = $false }
    }

    $data = [ordered]@{
        command = 'install'
        run_id = (Split-Path $runRoot -Leaf)
        utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
        workspace_root = $ws
        skill_mode = $SkillMode
        created_dirs = @($createdDirs)
        file_hashes = $cp.hashes
        skill = $skillInfo
        initialize = [ordered]@{ exit = $rInit.exit; status = (Get-Prop $jInit 'status') }
        validate = [ordered]@{ exit = $rVal.exit; status = (Get-Prop $jVal 'status') }
        baseline_status = $baseline
        selftest = [ordered]@{
            exit = $rSelf.exit; timed_out = $rSelf.timed_out; ms = $rSelf.ms
            total_cases = (Get-Prop $jSelf 'total_cases'); pass_cases = (Get-Prop $jSelf 'pass_cases'); fail_cases = (Get-Prop $jSelf 'fail_cases')
        }
        post_status_generation = $postGen
        generation_unchanged = $genUnchanged
        result = 'PASS'
    }
    $receiptPath = Write-Receipt -RunRoot $runRoot -CommandName 'install' -Data $data

    $reportPath = Join-Path $runRoot 'REPORT.txt'
    Write-Bamp1Report -RunRoot $runRoot | ForEach-Object { }
    $reportText = [System.IO.File]::ReadAllText($reportPath)
    Write-Host $reportText
    Write-Host ('receipt: ' + $receiptPath)
    Write-Host ('report: ' + $reportPath)
    exit 0
}

# ---------------------------------------------------------------------------
# status-report / uninstall
# ---------------------------------------------------------------------------
function Invoke-StatusReport {
    $runRoot = Get-LatestRunRoot
    if ($null -eq $runRoot) { Stop-Bamp1 -Reason 'no run found; run verify-artifact first' }
    $reportPath = Join-Path $runRoot 'REPORT.txt'
    $text = Write-Bamp1Report -RunRoot $runRoot
    Write-Host $text
    Write-Host ('report: ' + $reportPath)
    exit 0
}

function Invoke-Uninstall {
    if ($WorkspaceRoot -eq '') { Stop-Bamp1 -Reason 'invalid input: -WorkspaceRoot required' }
    if ($SkillMode -eq '') { Stop-Bamp1 -Reason 'invalid input: -SkillMode required (project|global|none)' }

    # UNINSTALL IS DISABLED IN THIS DISTRIBUTION BUILD.
    # No code path in this function can delete anything: no receipt matching,
    # no hash re-verification, no deviation analysis, no Directory.Delete.
    # Removal requires manual action under explicit user judgment (README "rollback").
    $runRoot = Get-LatestRunRoot
    if ($null -ne $runRoot) {
        try {
            $null = Write-Receipt -RunRoot $runRoot -CommandName 'uninstall' -Data ([ordered]@{
                command = 'uninstall'
                run_id = (Split-Path $runRoot -Leaf)
                utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
                workspace_root = $WorkspaceRoot
                skill_mode = $SkillMode
                result = 'DISABLED'
                note = 'uninstall is disabled in this build; nothing was deleted and no file was touched. Manual removal requires explicit user judgment.'
            })
        } catch { }
    }
    Write-Host 'STOP: uninstall is DISABLED in this distribution build.'
    Write-Host 'Nothing has been deleted and no file was touched (including memory, tools, docs, skills).'
    Write-Host 'Manual removal requires explicit user judgment (see README "rollback" note).'
    Write-Host 'exit 2'
    exit 2
}

# ---------------------------------------------------------------------------
# Report (6 sections; design SS4 template; machine text only)
# ---------------------------------------------------------------------------
function Write-Bamp1Report {
    param([string]$RunRoot)
    $runId = Split-Path $RunRoot -Leaf
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('=== BAM-P1 Core installation report (machine-generated; no LLM summary) ===')
    $L.Add(('Run: {0} / {1} UTC / PowerShell {2}' -f $runId, (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $PSVersionTable.PSVersion.ToString()))
    $L.Add('')

    $vr = Get-LatestReceipt -RunRoot $RunRoot -CommandName 'verify-artifact'
    $cr = Get-LatestReceipt -RunRoot $RunRoot -CommandName 'check-target'
    $mr = Get-LatestReceipt -RunRoot $RunRoot -CommandName 'install-mock'
    $ir = Get-LatestReceipt -RunRoot $RunRoot -CommandName 'install'
    $ur = Get-LatestReceipt -RunRoot $RunRoot -CommandName 'uninstall'

    $L.Add('[1. What was actually executed and changed]')
    if ($null -ne $vr) {
        $L.Add(('  - Artifact verification: {0} (zip hash / MANIFEST / file set / path sanity / allowlist / content gates G0-G5)  mode={1}' -f (Get-Prop $vr[1] 'result'), (Get-Prop $vr[1] 'mode')))
        if ($null -ne (Get-Prop $vr[1] 'zip_sha256')) { $L.Add(('    zip: {0}  ({1})' -f (Get-Prop $vr[1] 'zip_sha256'), (Get-Prop $vr[1] 'zip_path'))) }
        $L.Add(('    tree: {0}' -f (Get-Prop $vr[1] 'tree_root')))
    } else { $L.Add('  - Artifact verification: NOT_RUN') }
    if ($null -ne $cr) {
        $L.Add(('  - Target check: {0}  ws={1}  (3 ABSENT / writable / PS {2} / skill file detection only)' -f (Get-Prop $cr[1] 'result'), (Get-Prop $cr[1] 'workspace_root'), (Get-Prop $cr[1] 'ps_version')))
    } else { $L.Add('  - Target check: NOT_RUN') }
    if ($null -ne $mr) {
        $m = Get-Prop $mr[1] 'runner'
        $L.Add(('  - Isolated mock: {0}  (selftest total={1} fail={2}, exit={3}, {4} ms)' -f (Get-Prop $mr[1] 'mock_ws'), (Get-Prop $m 'total_cases'), (Get-Prop $m 'fail_cases'), (Get-Prop $m 'exit'), (Get-Prop $m 'ms')))
        $pt = Get-Prop $mr[1] 'portability'
        if ($null -ne $pt) {
            foreach ($pk in @($pt.PSObject.Properties | ForEach-Object { $_.Name })) {
                $L.Add(('    portability {0}: {1}' -f $pk, $(if ((Get-Prop $pt.PSObject.Properties[$pk].Value 'pass') -eq $true) { 'PASS' } else { 'FAIL' })))
            }
        }
    } else { $L.Add('  - Isolated mock: NOT_RUN') }
    if ($null -ne $ir) {
        $L.Add(('  - Placement: {0}  (fresh creation; post-copy verification PASS; created_dirs={1})' -f (Get-Prop $ir[1] 'workspace_root'), (@((Get-Prop $ir[1] 'created_dirs')).Count)))
        $L.Add(('  - Initialization: initialize {0} / Validate {1} / Status PASS (baseline gen={2}, empty)' -f (Get-Prop (Get-Prop $ir[1] 'initialize') 'status'), (Get-Prop (Get-Prop $ir[1] 'validate') 'status'), (Get-Prop (Get-Prop $ir[1] 'baseline_status') 'generation')))
        $sk = Get-Prop $ir[1] 'skill'
        $smode = [string](Get-Prop $sk 'mode')
        if ($smode -eq 'project') { $L.Add(('  - Skill: project mode (file placed: {0})' -f (Get-Prop $sk 'skill_file'))) }
        elseif ($smode -eq 'global') { $L.Add('  - Skill: global NOT set (one AI action needed: skill.install + user approval; SKILL.md is at skill\bam-memory\SKILL.md in the tree)') }
        else { $L.Add('  - Skill: none (operating without a skill; see SKILL.md for the invocation contract only)') }
    } else { $L.Add('  - Placement/initialization: NOT_RUN') }
    if ($null -ne $ur) {
        if ([string](Get-Prop $ur[1] 'result') -eq 'DISABLED') {
            $L.Add('  - uninstall: DISABLED (this build: deletion not executed; manual removal = explicit user judgment)')
        } else {
            $L.Add(('  - uninstall: {0}  (deleted_dirs={1})' -f (Get-Prop $ur[1] 'result'), (@((Get-Prop $ur[1] 'deleted_dirs')).Count)))
        }
    }
    $L.Add('')

    $L.Add('[2. Machine verification]')
    if ($null -ne $mr) {
        $m = Get-Prop $mr[1] 'runner'
        $L.Add(('  - mock selftest: total={0} fail={1} exit={2} -> {3}' -f (Get-Prop $m 'total_cases'), (Get-Prop $m 'fail_cases'), (Get-Prop $m 'exit'), $(if ((Get-Prop $mr[1] 'result') -eq 'PASS') { 'PASS' } else { 'FAIL' })))
        $L.Add(('  - Production fault injection denied (AM-T-006.u, inside mock): {0}' -f (Get-CaseStatus -SummaryObj (Get-Prop $mr[1] 'runner_summary') -CaseId 'AM-T-006.u')))
    }
    if ($null -ne $ir) {
        $s = Get-Prop $ir[1] 'selftest'
        $L.Add(('  - Production selftest: total={0} fail={1} exit={2} -> PASS' -f (Get-Prop $s 'total_cases'), (Get-Prop $s 'fail_cases'), (Get-Prop $s 'exit')))
        $L.Add(('  - Status after selftest: generation unchanged = {0}' -f (Get-Prop $ir[1] 'generation_unchanged')))
    }
    $L.Add('  - AM-T-027 P95: frozen criterion <=2.0s (judged inside selftest; FAIL = report as environment difference, never relaxed)')
    $L.Add('')

    $L.Add('[3. Not machine-verified (needs separate confirmation; file existence is separate)]')
    $L.Add('  - Skill recognition / explicit activation by the target Bionic (@bam-memory)')
    $L.Add('  - Use across a session boundary (fresh chat)')
    $L.Add('  - Appropriate memory usage by the target LLM')
    $L.Add('  -> Run the PROCEDURE "live" one-message fresh-chat probe (1 user action)')
    $L.Add('')

    $L.Add('[4. Unverified items and constraints]')
    $L.Add('  - Real behavior of .agents / global skill on the target machine: file-level detection only')
    if ($null -ne $ir) {
        $L.Add('  - This root is a test environment during the acceptance period; distinct from production start')
        if ((Get-Prop $ir[1] 'skill_mode') -eq 'global') { $L.Add('  - Global skill NOT set (skill.install + user approval required)') }
    }
    $L.Add('  - Disposal of test data (tag bamp1-test / BAM-P1-TEST:) is NOT part of the install procedure (evidence preservation + explicit user approval only)')
    $L.Add('')

    $L.Add('[5. Next minimal user action]')
    $L.Add('  1. Paste this one message in a fresh chat: "Remember: BAM-P1-TEST: test-marker-alpha"')
    $L.Add('  2. Ask "What is the BAM-P1 test marker?" -> expect a 4-element citation HIT / for unsaved items -> expect "no record in auxiliary memory"')
    $L.Add('  3. Review the result and decide acceptance (keep) or rollback (uninstall is disabled in this distribution; manual removal = explicit user judgment only)')
    $L.Add('')

    $L.Add('[6. rollback]')
    $L.Add('  uninstall is DISABLED in this distribution build (running it deletes nothing; it prints the reason and exits 2).')
    $L.Add('  Manual rollback (after evidence preservation; explicit user judgment only):')
    $L.Add('    delete <ws>\memory, <ws>\tools\memory-tool, <ws>\draft_bionic_aux_mem, and (project mode) <ws-parent>\.agents\skills\bam-memory')
    $L.Add('  Note: memory containing data is never deleted automatically (design SS7.3)')
    $L.Add('MACHINE_CHECK_PASS != USER_ACCEPTANCE')

    $reportPath = Join-Path $RunRoot 'REPORT.txt'
    Write-Utf8Bom -Path $reportPath -Text (($L -join "`r`n"))
    return ($L -join "`r`n")
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
try {
    switch ($Command) {
        'verify-artifact' { Invoke-VerifyArtifact }
        'check-target'    { Invoke-CheckTarget }
        'install-mock'    { Invoke-InstallMock }
        'install'         { Invoke-Install }
        'status-report'   { Invoke-StatusReport }
        'uninstall'       { Invoke-Uninstall }
        default {
            Write-Host 'STOP: unknown or missing command (expected: verify-artifact | check-target | install-mock | install | status-report | uninstall)'
            Write-Host 'exit 2'
            exit 2
        }
    }
} catch {
    Write-Host ('UNEXPECTED_ERROR (STOP): ' + $_.Exception.Message)
    Write-Host 'exit 2'
    exit 2
}

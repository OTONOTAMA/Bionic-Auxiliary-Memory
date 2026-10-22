# test-bam-adapter.ps1 — BAM core v0.7 mechanical test suite (33 cases)
#
# Runs bam-adapter.ps1 / migrate-legacy.ps1 as child processes (realistic cold start).
# Fixtures are created under <staging>\.test-tmp-<timestamp>\ and left on disk
# (this script does not delete anything). The AI may clean them after the run.
# Asserts NFR-03 (<5 s per mode) as a max-ms measurement in the summary.
# Exit: 0 = all cases pass / 1 = any case failed.
# Encoding: this file MUST stay UTF-8 with BOM (contains Japanese; PS 5.1).
#
param(
    [string]$Staging = ''
)

$ErrorActionPreference = 'Stop'
if ($Staging -eq '') { $Staging = $PSScriptRoot }
$adapter = Join-Path $Staging 'bam-adapter.ps1'
$migrate = Join-Path $Staging 'migrate-legacy.ps1'
$work = Join-Path $Staging ('.test-tmp-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$script:PsExe = (Get-Process -Id $PID).Path
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Pass = 0
$script:Fail = 0
$script:MaxMs = 0
$script:CaseSeen = New-Object System.Collections.Generic.List[string]
$script:CaseFail = @{}

function Quote-Arg {
    param([string]$V)
    if ($V -match '[\s"]') { return ('"' + ($V -replace '"', '\\"') + '"') }
    return $V
}

function Invoke-Child {
    param([string]$Script, [string[]]$Params)
    $argParts = New-Object System.Collections.Generic.List[string]
    $argParts.Add('-NoLogo')
    $argParts.Add('-NoProfile')
    $argParts.Add('-NonInteractive')
    $argParts.Add('-ExecutionPolicy')
    $argParts.Add('Bypass')
    $argParts.Add('-File')
    $argParts.Add((Quote-Arg $Script))
    foreach ($a in $Params) { $argParts.Add((Quote-Arg $a)) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.Arguments = ($argParts -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { $p.Start() | Out-Null } catch {
        $sw.Stop()
        if ($sw.ElapsedMilliseconds -gt $script:MaxMs) { $script:MaxMs = $sw.ElapsedMilliseconds }
        return @{ exit = -1; out = ''; err = $_.Exception.Message; line = ''; json = $null; ms = $sw.ElapsedMilliseconds }
    }
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result
    $sw.Stop()
    if ($sw.ElapsedMilliseconds -gt $script:MaxMs) { $script:MaxMs = $sw.ElapsedMilliseconds }
    $ls = @($out -split "`n" | Where-Object { $_.Trim() -ne '' })
    $line = ''
    if ($ls.Count -gt 0) { $line = $ls[0] }
    $json = $null
    try { $json = ($line | ConvertFrom-Json) } catch { $json = $null }
    return @{ exit = $p.ExitCode; out = $out; err = $err; line = $line; json = $json; ms = $sw.ElapsedMilliseconds }
}

function Invoke-Bam {
    param([string[]]$P)
    return (Invoke-Child $adapter $P)
}

function Invoke-Mig {
    param([string[]]$P)
    return (Invoke-Child $migrate $P)
}

function Check {
    param([string]$Id, [string]$Name, [bool]$Ok, [string]$Detail = '')
    if (-not $script:CaseSeen.Contains($Id)) { $script:CaseSeen.Add($Id) }
    if ($Ok) {
        $script:Pass++
        Write-Host ("PASS [{0}] {1}" -f $Id, $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        $script:CaseFail[$Id] = $true
        Write-Host ("FAIL [{0}] {1} :: {2}" -f $Id, $Name, $Detail) -ForegroundColor Red
    }
}

function Get-Body {
    param($R)
    if ([string]::IsNullOrWhiteSpace($R.out)) { return '' }
    $nl = $R.out.IndexOf("`n")
    if ($nl -lt 0) { return '' }
    return $R.out.Substring($nl + 1)
}

function ByteLen {
    param([string]$Text)
    return $script:Utf8NoBom.GetByteCount($Text)
}

function Write-File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -ne '' -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $t, $script:Utf8NoBom)
}

function Read-File {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Hash-File {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { $dig = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($dig) -replace '-', '').ToLower()
}

function Get-TreeHash {
    param([string]$Root)
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        $parts.Add(('{0}:{1}' -f $rel, (Hash-File $f.FullName)))
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $dig = $sha.ComputeHash($script:Utf8NoBom.GetBytes(($parts -join "`n"))) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($dig) -replace '-', '').ToLower()
}

function New-Root {
    param([string]$Name)
    $root = Join-Path $work $Name
    $r = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $root)
    if ($null -eq $r.json -or $r.json.status -ne 'INITIALIZED') {
        Check $Name 'bootstrap INITIALIZED (setup)' $false $r.out
    }
    return @{ root = $root; init = $r }
}

function New-LegacyFixture {
    param([string]$Name, [int]$Records)
    $r = Join-Path $work $Name
    $genDir = Join-Path $r '.gen\000001'
    New-Item -ItemType Directory -Path $genDir -Force | Out-Null
    Write-File (Join-Path $r 'ACTIVE') ("GENERATION=1`nOPERATION_ID=test-op-0001`nRESULT=PASS`n")
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# memory-index v1')
    for ($i = 1; $i -le $Records; $i++) {
        $id = ('mem_{0:D4}' -f $i)
        $lines.Add(('{0}|2026-01-{1:D2}T00:00:00Z|subject {1}|tag1;tag2|USER_STATED|evidence-{1}|-|active|pinned-{1}|summary {1}' -f $id, $i))
    }
    Write-File (Join-Path $genDir 'index.md') (($lines -join "`n") + "`n")
    return $r
}

function Write-Current {
    param([string]$Root, [string]$Tag)
    Write-File (Join-Path $Root 'state\current.md') ("# current（現在の状態）`n`n## 目的`n{0}`n`n## 状態`nテスト`n" -f $Tag)
}

function Write-Candidate {
    param([string]$Root, [string]$Text)
    Write-File (Join-Path $Root 'runtime\HOT_STATE.candidate.md') $Text
}

function Write-Facts {
    param([string]$Root, [string]$Text)
    Write-File (Join-Path $Root 'canonical\facts.md') $Text
}

try {

    # ================= FMT (5) =================

    # FMT-01: valid template -> Validate PASS + Bootstrap PASS body <= 4 KB
    $f = New-Root 'fmt01'
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'FMT-01' 'Validate PASS' ($v.exit -eq 0 -and $null -ne $v.json -and $v.json.status -eq 'PASS') $v.line
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    $body = Get-Body $b
    Check 'FMT-01' 'Bootstrap PASS + body<=4096B' ($b.exit -eq 0 -and $b.json.status -eq 'PASS' -and (ByteLen $body) -le 4096) $b.line
    Check 'FMT-01' 'body contains initial marker' ($body.Contains('初期状態')) $body

    # FMT-02: header missing -> Validate FAIL HEADER_MISSING + Bootstrap fail-open exit 0
    $f = New-Root 'fmt02'
    $hp = Join-Path $f.root 'runtime\HOT_STATE.md'
    $t = Read-File $hp
    $lines = @($t -split "`n")
    $idx = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $idx = $i; break } }
    $stripped = ($lines[($idx + 1)..($lines.Count - 1)] -join "`n") + "`n"
    Write-File $hp $stripped
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'FMT-02' 'Validate FAIL HEADER_MISSING' ($v.exit -eq 1 -and $v.json.code -eq 'HEADER_MISSING') $v.line
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    Check 'FMT-02' 'Bootstrap fail-open exit0 UNVERIFIED' ($b.exit -eq 0 -and $b.json.status -eq 'UNVERIFIED') $b.line

    # FMT-03: invalid UTF-8 -> ENCODING_INVALID_UTF8
    $f = New-Root 'fmt03'
    $fp = Join-Path $f.root 'canonical\facts.md'
    $bytes = [System.IO.File]::ReadAllBytes($fp)
    [System.IO.File]::WriteAllBytes($fp, ($bytes + [byte[]](0xFF, 0xFE)))
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'FMT-03' 'Validate FAIL ENCODING_INVALID_UTF8' ($v.exit -eq 1 -and $v.json.code -eq 'ENCODING_INVALID_UTF8') $v.line

    # FMT-04: hard cap exceeded (facts > 16384) -> SIZE_HARD_EXCEEDED
    $f = New-Root 'fmt04'
    Write-Facts $f.root ("# facts（検証済み事実）`n`n" + ('x' * 17000) + "`n")
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'FMT-04' 'Validate FAIL SIZE_HARD_EXCEEDED' ($v.exit -eq 1 -and $v.json.code -eq 'SIZE_HARD_EXCEEDED') $v.line

    # FMT-05: source file missing -> SOURCE_MISSING
    $f = New-Root 'fmt05'
    Remove-Item -LiteralPath (Join-Path $f.root 'state\current.md') -Force
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'FMT-05' 'Validate FAIL SOURCE_MISSING' ($v.exit -eq 1 -and $v.json.code -eq 'SOURCE_MISSING') $v.line

    # ================= STALE (4) =================

    # STALE-01: SOURCE hash mismatch -> Bootstrap STALE exit 0 + pointer; Validate FAIL
    $f = New-Root 'stale01'
    Write-Current $f.root 'STALE-01 v2'
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    Check 'STALE-01' 'Bootstrap STALE exit0 + pointer' ($b.exit -eq 0 -and $b.json.status -eq 'STALE' -and $b.json.code -eq 'STALE_SOURCE_HASH' -and ($b.json.pointer -like '*current*')) $b.line
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'STALE-01' 'Validate FAIL STALE_SOURCE_HASH' ($v.exit -eq 1 -and $v.json.code -eq 'STALE_SOURCE_HASH') $v.line

    # STALE-02: manifest missing -> MANIFEST_MISSING
    $f = New-Root 'stale02'
    Remove-Item -LiteralPath (Join-Path $f.root 'manifest.toml') -Force
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'STALE-02' 'Validate FAIL MANIFEST_MISSING' ($v.exit -eq 1 -and $v.json.code -eq 'MANIFEST_MISSING') $v.line

    # STALE-03: manifest hash mismatch (tamper index.md) -> INTEGRITY_MISMATCH
    $f = New-Root 'stale03'
    $ip = Join-Path $f.root 'index.md'
    Write-File $ip ((Read-File $ip) + "`nTAMPER-LINE`n")
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'STALE-03' 'Validate FAIL INTEGRITY_MISMATCH' ($v.exit -eq 1 -and $v.json.code -eq 'INTEGRITY_MISMATCH') $v.line

    # STALE-04: post-commit manifest update -> Validate PASS
    $f = New-Root 'stale04'
    Write-Current $f.root 'STALE-04'
    Write-Candidate $f.root "## 要約`nSTALE-04-MARKER`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    Check 'STALE-04' 'Commit PASS' ($c.exit -eq 0 -and $c.json.status -eq 'PASS') $c.line
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'STALE-04' 'Validate PASS after commit' ($v.exit -eq 0 -and $v.json.status -eq 'PASS') $v.line

    # ================= COMMIT (4) =================

    # COMMIT-01: success (headerless + preamble candidate)
    $f = New-Root 'commit01'
    Write-Current $f.root 'COMMIT-01'
    Write-Candidate $f.root "preamble line to strip`n## 要約`nCOMMIT-01-SUMMARY`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    $hotP = Join-Path $f.root 'runtime\HOT_STATE.md'
    $hotText = ''
    if (Test-Path -LiteralPath $hotP) { $hotText = Read-File $hotP }
    $warnCodes = @()
    if ($null -ne $c.json -and $null -ne $c.json.warnings) { $warnCodes = @($c.json.warnings | ForEach-Object { "$($_.code)" }) }
    Check 'COMMIT-01' 'Commit PASS + strip warning' ($c.exit -eq 0 -and $c.json.status -eq 'PASS' -and ($warnCodes -contains 'COMMIT_CANDIDATE_PREAMBLE_STRIPPED')) $c.line
    Check 'COMMIT-01' 'HOT_STATE header + body roundtrip' ($hotText.StartsWith('# HOT_STATE') -and $hotText.Contains('COMMIT-01-SUMMARY') -and -not $hotText.Contains('preamble line to strip')) $hotText
    Check 'COMMIT-01' 'candidate deleted' (-not (Test-Path -LiteralPath (Join-Path $f.root 'runtime\HOT_STATE.candidate.md'))) ''
    Check 'COMMIT-01' 'rollback kept' (Test-Path -LiteralPath (Join-Path $f.root 'runtime\HOT_STATE.md.rollback.md')) ''
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'COMMIT-01' 'Validate PASS' ($v.exit -eq 0 -and $v.json.status -eq 'PASS') $v.line

    # COMMIT-02: bad candidate (invalid UTF-8) -> FAIL, HOT_STATE byte-identical, candidate preserved
    $f = New-Root 'commit02'
    $hotP = Join-Path $f.root 'runtime\HOT_STATE.md'
    Write-Current $f.root 'COMMIT-02'
    $candP = Join-Path $f.root 'runtime\HOT_STATE.candidate.md'
    Write-Candidate $f.root "## 要約`nbad candidate`n"
    $cb = [System.IO.File]::ReadAllBytes($candP)
    [System.IO.File]::WriteAllBytes($candP, ($cb + [byte[]](0xFF)))
    $preHot = Hash-File $hotP
    $preCand = Hash-File $candP
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    Check 'COMMIT-02' 'FAIL COMMIT_CANDIDATE_INVALID_UTF8' ($c.exit -eq 1 -and $c.json.code -eq 'COMMIT_CANDIDATE_INVALID_UTF8') $c.line
    Check 'COMMIT-02' 'HOT_STATE byte-identical' ((Hash-File $hotP) -eq $preHot) ''
    Check 'COMMIT-02' 'candidate preserved' ((Hash-File $candP) -eq $preCand) ''

    # COMMIT-03: replace failure (locked target) + manifest write failure (restore path)
    # Note: the read-only FILE attribute does NOT fail File.Replace on Windows
    # (verified empirically). A write handle held by this process (FileShare.ReadWrite)
    # blocks the replace while still permitting the adapter's reads (the adapter opens
    # with a permissive share - see Get-Sha256Hex in bam-adapter.ps1).
    $f = New-Root 'commit03a'
    $hotP = Join-Path $f.root 'runtime\HOT_STATE.md'
    Write-Current $f.root 'COMMIT-03a'
    $preHot = Hash-File $hotP
    $lock = [System.IO.File]::Open($hotP, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    Write-Candidate $f.root "## 要約`nC03A-MARKER`n"
    try {
        $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    } finally {
        $lock.Dispose()
    }
    Check 'COMMIT-03' 'locked target -> COMMIT_REPLACE_FAILED' ($c.exit -eq 1 -and $c.json.code -eq 'COMMIT_REPLACE_FAILED') $c.line
    Check 'COMMIT-03' 'HOT_STATE byte-identical after replace fail' ((Hash-File $hotP) -eq $preHot) ''

    $f = New-Root 'commit03b'
    $hotP = Join-Path $f.root 'runtime\HOT_STATE.md'
    Write-Current $f.root 'COMMIT-03b'
    Write-Candidate $f.root "## 要約`nC03B-1`n"
    $c1 = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    if ($c1.exit -ne 0 -or $c1.json.status -ne 'PASS') { Check 'COMMIT-03' 'setup commit PASS' $false $c1.line }
    $preHot = Hash-File $hotP
    $manP = Join-Path $f.root 'manifest.toml'
    [System.IO.File]::SetAttributes($manP, [System.IO.FileAttributes]::ReadOnly)
    Write-Candidate $f.root "## 要約`nC03B-2`n"
    $c2 = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    $hotText = Read-File $hotP
    Check 'COMMIT-03' 'read-only manifest -> COMMIT_MANIFEST_WRITE_FAILED' ($c2.exit -eq 1 -and $c2.json.code -eq 'COMMIT_MANIFEST_WRITE_FAILED') $c2.line
    Check 'COMMIT-03' 'restored from rollback (pre-commit content)' ((Hash-File $hotP) -eq $preHot -and $hotText.Contains('C03B-1') -and -not $hotText.Contains('C03B-2')) $hotText
    [System.IO.File]::SetAttributes($manP, [System.IO.FileAttributes]::Normal)

    # COMMIT-04: pre-existing candidate not clobbered on failure
    $f = New-Root 'commit04'
    Write-Candidate $f.root "## 要約`nMARKER-KEEP-CANDIDATE`n"
    $candP = Join-Path $f.root 'runtime\HOT_STATE.candidate.md'
    $preCand = Hash-File $candP
    Remove-Item -LiteralPath (Join-Path $f.root 'state\current.md') -Force
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    Check 'COMMIT-04' 'FAIL COMMIT_SOURCE_MISSING' ($c.exit -eq 1 -and $c.json.code -eq 'COMMIT_SOURCE_MISSING') $c.line
    Check 'COMMIT-04' 'candidate not clobbered' ((Hash-File $candP) -eq $preCand) ''

    # ================= PATH (3) =================

    # PATH-01: .. escape rejected
    $f = New-Root 'path01'
    Write-Facts $f.root "# facts（検証済み事実）`n`n- 2026-10-01: パステスト [UNVERIFIED]`n"
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', '..\evil.md')
    Check 'PATH-01' '.. escape -> DEMOTE_PATH_ESCAPE' ($c.exit -eq 1 -and $c.json.code -eq 'DEMOTE_PATH_ESCAPE') $c.line

    # PATH-02: absolute outside root rejected
    $f = New-Root 'path02'
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', 'C:\Windows\bam-outside-test.md')
    Check 'PATH-02' 'absolute outside -> DEMOTE_PATH_OUTSIDE' ($c.exit -eq 1 -and $c.json.code -eq 'DEMOTE_PATH_OUTSIDE') $c.line

    # PATH-03: relative inside root accepted
    $f = New-Root 'path03'
    Write-Facts $f.root "# facts（検証済み事実）`n`n- 2026-10-01: パステスト OK [UNVERIFIED]`n"
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', 'canonical/facts.md', '-N', '1')
    Check 'PATH-03' 'relative inside -> DEMOTED' ($c.exit -eq 0 -and $c.json.status -eq 'DEMOTED') $c.line

    # ================= SIZE (3) =================

    # SIZE-01: BOM rejected
    $f = New-Root 'size01'
    $pp = Join-Path $f.root 'canonical\profile.md'
    $pb = [System.IO.File]::ReadAllBytes($pp)
    [System.IO.File]::WriteAllBytes($pp, ([byte[]](0xEF, 0xBB, 0xBF)) + $pb)
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'SIZE-01' 'Validate FAIL ENCODING_BOM' ($v.exit -eq 1 -and $v.json.code -eq 'ENCODING_BOM') $v.line

    # SIZE-02: archive > 65536 rejected
    $f = New-Root 'size02'
    $ap = Join-Path $f.root 'references\archive.md'
    Write-File $ap ("# archive（降格先・cold tier）`n`n" + ('y' * 66000) + "`n")
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'SIZE-02' 'Validate FAIL SIZE_HARD_EXCEEDED (archive)' ($v.exit -eq 1 -and $v.json.code -eq 'SIZE_HARD_EXCEEDED') $v.line

    # SIZE-03: HOT_STATE target exceeded -> warning only, Commit PASS up to hard
    $f = New-Root 'size03'
    Write-Current $f.root 'SIZE-03'
    Write-Candidate $f.root ("## 要約`n" + ('A' * 4990) + "`n")
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    $warnCodes = @()
    if ($null -ne $c.json -and $null -ne $c.json.warnings) { $warnCodes = @($c.json.warnings | ForEach-Object { "$($_.code)" }) }
    Check 'SIZE-03' 'Commit PASS + SIZE_TARGET_EXCEEDED warning' ($c.exit -eq 0 -and $c.json.status -eq 'PASS' -and ($warnCodes -contains 'SIZE_TARGET_EXCEEDED')) $c.line
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'SIZE-03' 'Validate PASS (warning only)' ($v.exit -eq 0 -and $v.json.status -eq 'PASS') $v.line

    # ================= BOOT (3) =================

    # BOOT-01: PASS -> body printed <= 4 KB, content roundtrip
    $f = New-Root 'boot01'
    Write-Current $f.root 'BOOT-01'
    Write-Candidate $f.root "## 要約`nBOOT01-ROUNDTRIP`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    if ($c.exit -ne 0 -or $c.json.status -ne 'PASS') { Check 'BOOT-01' 'setup commit PASS' $false $c.line }
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    $body = Get-Body $b
    Check 'BOOT-01' 'Bootstrap PASS + body<=4096B' ($b.exit -eq 0 -and $b.json.status -eq 'PASS' -and (ByteLen $body) -le 4096) $b.line
    Check 'BOOT-01' 'content roundtrip' ($body.Contains('BOOT01-ROUNDTRIP')) $body

    # BOOT-02: STALE -> pointer, no block, exit 0
    $f = New-Root 'boot02'
    Write-Current $f.root 'BOOT-02 v1'
    Write-Candidate $f.root "## 要約`nBOOT02`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    if ($c.exit -ne 0 -or $c.json.status -ne 'PASS') { Check 'BOOT-02' 'setup commit PASS' $false $c.line }
    Write-Current $f.root 'BOOT-02 v2 (tamper)'
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    Check 'BOOT-02' 'STALE -> exit 0 + pointer, no block' ($b.exit -eq 0 -and $b.json.status -eq 'STALE' -and ($b.json.pointer -like '*current*')) $b.line

    # BOOT-03: HOT_STATE missing (deleted) -> pointer, no block, exit 0
    $f = New-Root 'boot03'
    Write-Current $f.root 'BOOT-03'
    Write-Candidate $f.root "## 要約`nBOOT03`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    if ($c.exit -ne 0 -or $c.json.status -ne 'PASS') { Check 'BOOT-03' 'setup commit PASS' $false $c.line }
    $hotP3 = Join-Path $f.root 'runtime\HOT_STATE.md'
    Remove-Item -LiteralPath $hotP3 -Force
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root)
    Check 'BOOT-03' 'NO_HOT_STATE -> exit 0 + hint' ($b.exit -eq 0 -and $b.json.status -eq 'NO_HOT_STATE' -and ($b.json.hint_ja -like '*candidate*')) $b.line

    # ================= MIG (3) =================

    # Stub memory-helper: migrate-legacy derives the helper path as
    # <parent of legacy root>\tools\memory-tool\memory-helper.ps1. All MIG fixtures
    # share $work as parent, so one stub covers all of them. Contract:
    #   list -MemoryRoot <root> -Max N   -> one JSON line, exit 0
    #   get  -RecordId <id> -MemoryRoot <root> -> one JSON line (records[0].note inlined), exit 0
    # Thin direct reader of the fixture legacy tree (ACTIVE + .gen\<gen>\index.md).
    $stubP = Join-Path $work 'tools\memory-tool\memory-helper.ps1'
    Write-File $stubP @'
param([string]$Cmd = '', [string]$MemoryRoot = '', [string]$RecordId = '', [int]$Max = 200)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Out-StubFail {
    param([string]$Code, [string]$Detail)
    $d = ($Detail -replace '"', "'")
    Write-Output ('{"status":"FAIL","operation":"' + $Cmd + '","code":"' + $Code + '","detail":"' + $d + '"}')
    exit 1
}
try {
    $root = [System.IO.Path]::GetFullPath($MemoryRoot).TrimEnd('\\')
    if (-not (Test-Path -LiteralPath $root)) { Out-StubFail 'ROOT_MISSING' $root }
    $act = [System.IO.File]::ReadAllText((Join-Path $root 'ACTIVE'), $utf8)
    $gen = 0
    $opId = ''
    foreach ($ln in ($act -split "`n")) {
        if ($ln -match '^GENERATION=(\d+)') { $gen = [int]$Matches[1] }
        if ($ln -match '^OPERATION_ID=(\S+)') { $opId = $Matches[1] }
    }
    $idxP = Join-Path $root ('.gen\{0:D6}\index.md' -f $gen)
    if (-not (Test-Path -LiteralPath $idxP)) { Out-StubFail 'INDEX_MISSING' $idxP }
    $idx = [System.IO.File]::ReadAllText($idxP, $utf8)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($ln in ($idx -split "`n")) {
        $ln = $ln.Trim()
        if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
        $f = $ln.Split('|')
        if ($f.Count -lt 10) { continue }
        $tags = @($f[3].Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
        $all.Add([ordered]@{
            id = $f[0]
            recorded_at = $f[1]
            subject = $f[2]
            tags = @($tags)
            provenance = $f[4]
            note_pointer = $f[6]
            lifecycle = $f[7]
            summary = $f[9]
        })
        if ($all.Count -ge $Max) { break }
    }
    $recs = $all
    if ($Cmd -eq 'get') {
        $sel = $null
        foreach ($r in $all) { if ($r.id -eq $RecordId) { $sel = $r; break } }
        if ($null -eq $sel) { Out-StubFail 'RECORD_NOT_FOUND' $RecordId }
        if ($sel.note_pointer -eq '-') { $sel.note = $null } else { $sel.note = $sel.note_pointer }
        $recs = @($sel)
    }
    $payload = [ordered]@{
        status = 'PASS'
        operation = $Cmd
        records = @($recs | ForEach-Object { [pscustomobject]$_ })
        state_id = $opId
        diagnostics = @()
    }
    Write-Output ($payload | ConvertTo-Json -Compress -Depth 8)
} catch {
    Out-StubFail 'STUB_ERROR' $_.Exception.Message
}
'@

    # MIG-01: fixture legacy tree + DryRun dump -> count in output, legacy hash unchanged, nothing written
    $leg = New-LegacyFixture 'mig-legacy-1' 2
    $h1 = Get-TreeHash $leg
    $out = Join-Path $work 'mig-out-1'
    $m = Invoke-Mig @('-Mode', 'Dump', '-LegacyRoot', $leg, '-OutDir', $out, '-DryRun')
    Check 'MIG-01' 'DryRun exit0 + count=2' ($m.exit -eq 0 -and $null -ne $m.json -and $m.json.status -eq 'DRY_RUN' -and $m.json.count -eq 2) $m.line
    Check 'MIG-01' 'legacy tree hash unchanged' ((Get-TreeHash $leg) -eq $h1) ''
    Check 'MIG-01' 'nothing written' (-not (Test-Path -LiteralPath $out)) ''

    # MIG-02: dump + new root with migrated entries -> Verify caps OK + reconciliation 2 = 1 + 1
    $leg = New-LegacyFixture 'mig-legacy-2' 2
    $out = Join-Path $work 'mig-out-2'
    $m1 = Invoke-Mig @('-Mode', 'Dump', '-LegacyRoot', $leg, '-OutDir', $out)
    Check 'MIG-02' 'dump DUMPED count=2' ($m1.exit -eq 0 -and $m1.json.status -eq 'DUMPED' -and $m1.json.count -eq 2) $m1.line
    Check 'MIG-02' 'dump-manifest.json exists' (Test-Path -LiteralPath (Join-Path $out 'dump-manifest.json')) ''
    $f = New-Root 'mig-new-2'
    $factsP = Join-Path $f.root 'canonical\facts.md'
    Write-File $factsP ((Read-File $factsP) + "`n- 2026-10-20: 移行済み事実 [USER_STATED] [legacy:mem_0001]`n")
    $m2 = Invoke-Mig @('-Mode', 'Verify', '-NewRoot', $f.root, '-OutDir', $out)
    Check 'MIG-02' 'Verify PASS 2 = 1 + 1' ($m2.exit -eq 0 -and $m2.json.status -eq 'PASS' -and $m2.json.count -eq 2 -and $m2.json.migrated -eq 1 -and (@($m2.json.residual)).Count -eq 1) $m2.line

    # MIG-03: Retreat -> legacy hash unchanged + archive-legacy copy present
    $leg = New-LegacyFixture 'mig-legacy-3' 2
    $h1 = Get-TreeHash $leg
    $f = New-Root 'mig-new-3'
    $m = Invoke-Mig @('-Mode', 'Retreat', '-LegacyRoot', $leg, '-NewRoot', $f.root)
    Check 'MIG-03' 'Retreat RETREATED' ($m.exit -eq 0 -and $m.json.status -eq 'RETREATED') $m.line
    Check 'MIG-03' 'legacy tree hash unchanged' ((Get-TreeHash $leg) -eq $h1) ''
    Check 'MIG-03' 'archive-legacy ACTIVE present' (Test-Path -LiteralPath (Join-Path $f.root 'archive-legacy\ACTIVE')) ''
    Check 'MIG-03' 'archive-legacy gen index present' (Test-Path -LiteralPath (Join-Path $f.root 'archive-legacy\.gen\000001\index.md')) ''

    # ================= DEMOTE (3) =================

    # DEMOTE-01: oldest N mechanical move
    $f = New-Root 'demote01'
    $factsP = Join-Path $f.root 'canonical\facts.md'
    $archP = Join-Path $f.root 'references\archive.md'
    $text = "# facts（検証済み事実）`n`n"
    for ($i = 1; $i -le 5; $i++) {
        $text += ("- 2026-01-0{0}: 降格テストエントリ {0} [UNVERIFIED]`n" -f $i)
    }
    Write-File $factsP $text
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', 'canonical/facts.md', '-N', '2')
    $arch = Read-File $archP
    $src = Read-File $factsP
    Check 'DEMOTE-01' 'DEMOTED count=2' ($c.exit -eq 0 -and $c.json.status -eq 'DEMOTED' -and $c.json.count -eq 2) $c.line
    Check 'DEMOTE-01' 'archive gets oldest 2 in order' ($arch.Contains('エントリ 1') -and $arch.Contains('エントリ 2') -and ($arch.IndexOf('エントリ 1') -lt $arch.IndexOf('エントリ 2')) -and -not $arch.Contains('エントリ 3')) $arch
    Check 'DEMOTE-01' 'source keeps rest + pointer' ($src.Contains('エントリ 3') -and $src.Contains('エントリ 5') -and $src.Contains('demote-pointer:') -and -not $src.Contains('エントリ 1')) $src
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'DEMOTE-01' 'Validate PASS after demote' ($v.exit -eq 0 -and $v.json.status -eq 'PASS') $v.line

    # DEMOTE-02: N auto (fill facts > 12288)
    $f = New-Root 'demote02'
    $factsP = Join-Path $f.root 'canonical\facts.md'
    $text = "# facts（検証済み事実）`n`n"
    for ($i = 0; $i -lt 60; $i++) {
        $text += ("- 2026-01-01: " + ('x' * 200) + ("{0:D2} [UNVERIFIED]`n" -f $i))
    }
    Write-File $factsP $text
    $preSize = (Get-Item -LiteralPath $factsP).Length
    if ($preSize -le 12288) { Check 'DEMOTE-02' 'fixture > threshold (setup)' $false ("size={0}" -f $preSize) }
    $s = Invoke-Bam @('-Mode', 'Status', '-Root', $f.root)
    $ds = @()
    if ($null -ne $s.json -and $null -ne $s.json.demote_suggested) { $ds = @($s.json.demote_suggested) }
    Check 'DEMOTE-02' 'Status shows DEMOTE_SUGGESTED' ($s.exit -eq 0 -and @($ds | Where-Object { "$_" -like 'canonical/facts.md*' }).Count -eq 1) $s.line
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', 'canonical/facts.md')
    $postSize = (Get-Item -LiteralPath $factsP).Length
    Check 'DEMOTE-02' 'auto N -> post size < 12288' ($c.exit -eq 0 -and $c.json.status -eq 'DEMOTED' -and $postSize -lt 12288) ("post={0}" -f $postSize)
    $s2 = Invoke-Bam @('-Mode', 'Status', '-Root', $f.root)
    $ds2 = @()
    if ($null -ne $s2.json -and $null -ne $s2.json.demote_suggested) { $ds2 = @($s2.json.demote_suggested) }
    Check 'DEMOTE-02' 'no suggestion after demote' ($ds2.Count -eq 0) $s2.line

    # DEMOTE-03: archive at cap -> DEMOTE_ARCHIVE_FULL, files unchanged
    $f = New-Root 'demote03'
    $factsP = Join-Path $f.root 'canonical\facts.md'
    $archP = Join-Path $f.root 'references\archive.md'
    $head = "# archive（降格先・cold tier）`n`n"
    $padLen = 65536 - (ByteLen $head) - 1
    Write-File $archP ($head + ('z' * $padLen) + "`n")
    if ((Get-Item -LiteralPath $archP).Length -ne 65536) { Check 'DEMOTE-03' 'archive exactly at cap (setup)' $false ("size={0}" -f (Get-Item -LiteralPath $archP).Length) }
    Write-Facts $f.root "# facts（検証済み事実）`n`n- 2026-01-01: 降格テスト archive full [UNVERIFIED]`n"
    $preF = Hash-File $factsP
    $preA = Hash-File $archP
    $c = Invoke-Bam @('-Mode', 'Demote', '-Root', $f.root, '-File', 'canonical/facts.md', '-N', '1')
    Check 'DEMOTE-03' 'DEMOTE_ARCHIVE_FULL' ($c.exit -eq 1 -and $c.json.code -eq 'DEMOTE_ARCHIVE_FULL') $c.line
    Check 'DEMOTE-03' 'files unchanged' ((Hash-File $factsP) -eq $preF -and (Hash-File $archP) -eq $preA) ''

    # ================= REVIEW (5) =================
    # Regression cases for the 2026-10-22 pre-publication review fixes (rev1 + rev2 final review).

    # T-CHAT-INIT: explicit -ChatRoot initializes the chat root independently of
    # project creation; rerun is idempotent
    $f = New-Root 'chatinit01'
    $chatR = Join-Path $work 'chatinit01-chat'
    $b = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root, '-ChatRoot', $chatR)
    Check 'T-CHAT-INIT' 'existing project + new chat root -> PASS + chat_included' ($b.exit -eq 0 -and $null -ne $b.json -and $b.json.status -eq 'PASS' -and $b.json.chat_included -eq $true -and $b.json.chat_root_created -eq $true) $b.line
    Check 'T-CHAT-INIT' 'chat root initialized (manifest present)' (Test-Path -LiteralPath (Join-Path $chatR 'manifest.toml')) ''
    $b2 = Invoke-Bam @('-Mode', 'Bootstrap', '-Root', $f.root, '-ChatRoot', $chatR)
    Check 'T-CHAT-INIT' 'rerun idempotent (chat not re-created)' ($b2.exit -eq 0 -and $null -ne $b2.json -and $b2.json.status -eq 'PASS' -and $b2.json.chat_included -eq $true -and $b2.json.chat_root_created -eq $false) $b2.line

    # T-CRLF-CAP: CRLF (warning-level) must not bypass the hard-cap check
    $f = New-Root 'crlfcap01'
    $fp = Join-Path $f.root 'canonical\facts.md'
    $head = "# facts（検証済み事実）`r`n`r`n"
    $line = ('x' * 40) + "`r`n"
    $lb = ByteLen $line
    $need = 17011 - (ByteLen $head)
    $n = [int][math]::Floor($need / $lb)
    $crlfText = $head + ($line * $n) + ('x' * ($need - $n * $lb))
    [System.IO.File]::WriteAllText($fp, $crlfText, $script:Utf8NoBom)
    if ((Get-Item -LiteralPath $fp).Length -ne 17011) { Check 'T-CRLF-CAP' 'fixture exactly 17011 bytes (setup)' $false ("size={0}" -f (Get-Item -LiteralPath $fp).Length) }
    $manP = Join-Path $f.root 'manifest.toml'
    $man = Read-File $manP
    $man = $man -replace '(?m)^"canonical/facts\.md" = "[0-9a-f]{64}"$', ('"canonical/facts.md" = "' + (Hash-File $fp) + '"')
    Write-File $manP $man
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    $vCodes = @()
    if ($null -ne $v.json -and $null -ne $v.json.codes) { $vCodes = @($v.json.codes) }
    $vWarnCodes = @()
    if ($null -ne $v.json -and $null -ne $v.json.warnings) { $vWarnCodes = @($v.json.warnings | ForEach-Object { "$($_.code)" }) }
    Check 'T-CRLF-CAP' 'Validate FAIL SIZE_HARD_EXCEEDED despite CRLF warning' ($v.exit -eq 1 -and $null -ne $v.json -and $v.json.status -eq 'FAIL' -and $v.json.code -eq 'SIZE_HARD_EXCEEDED' -and ($vCodes -contains 'SIZE_HARD_EXCEEDED:canonical/facts.md')) $v.line
    Check 'T-CRLF-CAP' 'CRLF reported as warning' ($vWarnCodes -contains 'ENCODING_CRLF') $v.line

    # T-MANIFEST-ATOMIC: atomic manifest publish (no tmp residue, stays consistent)
    $f = New-Root 'manatom01'
    Write-Current $f.root 'T-MANIFEST-ATOMIC'
    Write-Candidate $f.root "## summary`nMAN-ATOMIC-MARKER`n"
    $c = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    Check 'T-MANIFEST-ATOMIC' 'Commit PASS' ($c.exit -eq 0 -and $null -ne $c.json -and $c.json.status -eq 'PASS') $c.line
    Check 'T-MANIFEST-ATOMIC' 'no manifest.toml.tmp residue' (-not (Test-Path -LiteralPath (Join-Path $f.root 'manifest.toml.tmp'))) ''
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'T-MANIFEST-ATOMIC' 'Validate PASS (manifest consistent)' ($v.exit -eq 0 -and $null -ne $v.json -and $v.json.status -eq 'PASS') $v.line

    # T-MANIFEST-LOCK: a read handle without DELETE share blocks the manifest
    # replace (editor / sync-reader model; no second memory writer). The failed
    # commit must NOT restore the stale rollback left by the earlier successful
    # operation: manifest AND HOT_STATE keep their pre-commit hashes, and
    # Validate stays PASS.
    $f = New-Root 'manlock01'
    Write-Current $f.root 'T-MANIFEST-LOCK'
    Write-Candidate $f.root "## summary`nMAN-LOCK-C1`n"
    $c1 = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    if ($c1.exit -ne 0 -or $c1.json.status -ne 'PASS') { Check 'T-MANIFEST-LOCK' 'setup commit PASS' $false $c1.line }
    $manP = Join-Path $f.root 'manifest.toml'
    $hotP = Join-Path $f.root 'runtime\HOT_STATE.md'
    $preMan = Hash-File $manP
    $preHot = Hash-File $hotP
    Write-Candidate $f.root "## summary`nMAN-LOCK-C2`n"
    $lock = [System.IO.File]::Open($manP, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $c2 = Invoke-Bam @('-Mode', 'Commit', '-Root', $f.root)
    } finally {
        $lock.Dispose()
    }
    Check 'T-MANIFEST-LOCK' 'locked manifest -> COMMIT_MANIFEST_WRITE_FAILED' ($c2.exit -eq 1 -and $c2.json.code -eq 'COMMIT_MANIFEST_WRITE_FAILED') $c2.line
    Check 'T-MANIFEST-LOCK' 'manifest hash unchanged (no stale rollback)' ((Hash-File $manP) -eq $preMan) ''
    Check 'T-MANIFEST-LOCK' 'HOT_STATE hash unchanged' ((Hash-File $hotP) -eq $preHot) ''
    $v = Invoke-Bam @('-Mode', 'Validate', '-Root', $f.root)
    Check 'T-MANIFEST-LOCK' 'Validate PASS after failed commit' ($v.exit -eq 0 -and $null -ne $v.json -and $v.json.status -eq 'PASS') $v.line

    # T-STATUS-MISSING-TRACKED: Status detects a missing required tracked file
    # (memory root present) and names it as a machine code
    $f = New-Root 'statusmiss01'
    $fp = Join-Path $f.root 'canonical\facts.md'
    $bakP = Join-Path $work 'statusmiss01-facts.bak'
    Move-Item -LiteralPath $fp -Destination $bakP -Force
    $s = Invoke-Bam @('-Mode', 'Status', '-Root', $f.root)
    $miss = @()
    if ($null -ne $s.json -and $null -ne $s.json.manifest_missing) { $miss = @($s.json.manifest_missing) }
    Check 'T-STATUS-MISSING-TRACKED' 'Status manifest=TRACKED_MISSING + missing file named' ($s.exit -eq 0 -and $null -ne $s.json -and $s.json.manifest -eq 'TRACKED_MISSING' -and ($miss -contains 'canonical/facts.md')) $s.line
    Move-Item -LiteralPath $bakP -Destination $fp -Force
    $s2 = Invoke-Bam @('-Mode', 'Status', '-Root', $f.root)
    $miss2Count = 0
    if ($null -ne $s2.json -and $null -ne $s2.json.manifest_missing) { $miss2Count = @($s2.json.manifest_missing).Count }
    Check 'T-STATUS-MISSING-TRACKED' 'Status manifest=OK after restore' ($s2.exit -eq 0 -and $s2.json.manifest -eq 'OK' -and $miss2Count -eq 0) $s2.line

    # ================= summary =================

    $caseTotal = $script:CaseSeen.Count
    $caseFailed = $script:CaseFail.Count
    $allOk = ($script:Fail -eq 0)
    Write-Host ''
    Write-Host ("SUITE cases={0} (failed cases={1}) assertions pass={2} fail={3} max_ms={4} workdir={5}" -f $caseTotal, $caseFailed, $script:Pass, $script:Fail, $script:MaxMs, $work)
    if ($script:MaxMs -ge 5000) {
        Write-Host ("NFR-03 WARNING: max invocation {0} ms >= 5000 ms" -f $script:MaxMs) -ForegroundColor Yellow
    }
    else {
        Write-Host ("NFR-03 OK: max invocation {0} ms < 5000 ms" -f $script:MaxMs) -ForegroundColor Green
    }
    if (-not $allOk) {
        foreach ($k in $script:CaseFail.Keys) { Write-Host ("FAILED CASE: {0}" -f $k) -ForegroundColor Red }
    }
    exit $(if ($allOk) { 0 } else { 1 })
}
catch {
    Write-Host ("SUITE INTERNAL ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 2
}

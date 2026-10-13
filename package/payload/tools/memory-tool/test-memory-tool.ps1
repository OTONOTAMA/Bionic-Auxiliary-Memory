# test-memory-tool.ps1 - Bionic Auxiliary Memory (BAM) machine selftest runner
# Bundle: BIONIC_AUX_MEM v0.5
# Authority: 04_TEST_FIRST_SPECIFICATION.md (dist variant 2026-10-12; SHA256 67E0AF016D6FC8E3255C3EB61CC3FAB2A4D8E1892BCD5B846C0AE3EFD280B57D)
#            01_CANONICAL_NORMATIVE_SPECIFICATION.md (dist variant 2026-10-12; SHA256 65ACEF51E47649F59E072E72CEFA7FCEE0FAEC5D625379761D3DE1EE78F6F62A)
# Platform: Windows PowerShell 5.1. No network. No transcript. No runtime dependencies.
# Output: exactly one JSON summary line on stdout (final line; all other runner stdout lines absent).
# Exit: 0 = all target cases PASS; 1 = one or more cases FAIL; 2 = runner usage error.
# NOT_IMPLEMENTED / NOT_EXECUTED / SKIPPED are never recorded as PASS.
# Fixture root: $env:TEMP\bam-test-<guid>. Deleted on success, kept (and reported) on failure.
# All runner-written text files are UTF-8 without BOM.
# NOTE: ASCII-only source file (no non-ASCII bytes).

param(
    [switch]$All,
    [string]$Case = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
try {
    [Console]::OutputEncoding = $script:Utf8NoBom
    [Console]::InputEncoding = $script:Utf8NoBom
    $OutputEncoding = $script:Utf8NoBom
} catch { }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:Ws = (Split-Path (Split-Path (Split-Path $PSCommandPath)))
$script:Tool = (Join-Path $script:Ws 'tools\memory-tool\memory-tool.ps1')
$script:PsExe = (Get-Process -Id $PID).Path
$script:AuthoritySha = @{
    'REQ'  = 'FEAE3670A6437D68D0E324AEBC4D0705677AE9C6684E4F484A192092C5AF547B'
    '01'   = '65ACEF51E47649F59E072E72CEFA7FCEE0FAEC5D625379761D3DE1EE78F6F62A'
    '02'   = 'E31336E62B8CF69E0C6D34E0BE95D395760B96A14B89FB2339FF54521FF6632E'
    '03'   = 'CA0209775961F60A404BF63C7F569F17B4E0B517FF3D8213A30059A156A9EB04'
    '04'   = '67E0AF016D6FC8E3255C3EB61CC3FAB2A4D8E1892BCD5B846C0AE3EFD280B57D'
    '05'   = 'BC7A18B9681D7E4E77B39BC2370C774D412D9057ABA33F7566D4773A4FDF852D'
}
$script:DraftDir = (Join-Path $script:Ws 'draft_bionic_aux_mem')
$script:ReqPath = (Join-Path $script:DraftDir 'BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md')# Layout guard (distribution variant): the runner requires the standard tool placement.
if (-not (Test-Path -LiteralPath $script:Tool)) { Write-Output '{"error":"LAYOUT_MISMATCH"}'; exit 2 }

# Closed diagnostics vocabulary (frozen 04 DIAGNOSTICS_VOCABULARY; dynamic
# tokens <id> and <n> are matched by pattern).
$script:DiagStatic = @('writer_active', 'cas_mismatch', 'operation_id_reuse', 'idempotent_pass_recovered',
    'receipt_history_conflict', 'staged_verify_failed', 'postswitch_rollback', 'deep_input_exceeds_budget',
    'dangling_evidence', 'out_exceeds_bound', 'restore_source_missing', 'restore_note_missing',
    'pending_invalid', 'active_switch_io_failed', 'active_switch_outcome_unknown', 'FAULT_SEAM_DENIED', 'USAGE_ERROR',
    'SPEC_OP_COUNT')
$script:DiagPatterns = @('^pending_operation:[0-9a-f-]{36}$', '^pending_resumed:[0-9a-f-]{36}$',
    '^pending_aborted:[0-9a-f-]{36}$', '^stale_generation_cleaned:[0-9]+$')
$script:StatusSet = @('PASS', 'HIT', 'MISS', 'INVALID', 'STALE', 'UNVERIFIED', 'BLOCKED', 'FAILED')
$script:OpSet = @('validate', 'status', 'recall', 'commit', 'forget', 'restore', 'abortpending', 'filterdeepout')

# Runner case bookkeeping
$script:Results = @{}          # caseId -> @{ status = 'PASS'/'FAIL'/'ERROR'; failures = list }
$script:Order = @()
$script:Failures = @()
$script:CaseFixture = $null    # fixture root for the currently running case

function New-FixtureRoot {
    $guid = [System.Guid]::NewGuid().ToString().ToLowerInvariant()
    $root = Join-Path ([System.IO.Path]::GetTempPath().TrimEnd('\')) ('bam-test-' + $guid)
    $script:CaseFixture = $root
    # MemoryRoot must be exactly <WorkspaceRoot>\memory (01 D1.1; tool BLOCKS otherwise).
    # Layout: <F>\workspace\memory + <F>\scratchpad.
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $root 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $root 'scratchpad')) | Out-Null
    return $root
}

function Get-ReparsePointDirs {
    param([string]$Root)
    # Breadth-first enumeration that does NOT descend into reparse points
    # (junctions/symlinks), so a self-referential link cannot cause a loop.
    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $subs = @()
        try { $subs = @(Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction Stop) } catch { $subs = @() }
        foreach ($d in $subs) {
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $found.Add($d.FullName) }
            else { $queue.Enqueue($d.FullName) }
        }
    }
    return $found
}

function Remove-FixtureRoot {
    param([string]$Root)
    if ($null -eq $Root) { return }
    if (-not (Test-Path -LiteralPath $Root)) { return }
    # Remove junction/reparse points first: cmd rmdir deletes the link itself and
    # never follows into the target, which .NET Directory.Delete cannot do.
    foreach ($j in (Get-ReparsePointDirs -Root $Root)) {
        try {
            $psiJ = New-Object System.Diagnostics.ProcessStartInfo
            $psiJ.FileName = 'cmd.exe'
            $psiJ.Arguments = ('/c rmdir "{0}"' -f $j)
            $psiJ.UseShellExecute = $false
            $psiJ.CreateNoWindow = $true
            $pJ = New-Object System.Diagnostics.Process
            $pJ.StartInfo = $psiJ
            $null = $pJ.Start()
            $null = $pJ.WaitForExit(10000)
        } catch { }
    }
    # Non-terminating: a cleanup failure leaves the fixture behind (treated as a kept
    # fixture per FIXTURE_CONVENTIONS) but must never abort the whole run.
    try { [System.IO.Directory]::Delete($Root, $true) } catch { }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Sha256File {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256Hex {
    param([string]$Text)
    return (Get-Sha256Hex -Bytes $script:Utf8NoBom.GetBytes($Text))
}

function New-Uuid {
    return [System.Guid]::NewGuid().ToString().ToLowerInvariant()
}

function Get-DateToday {
    return (Get-Date).ToString('yyyy-MM-dd')
}

function Write-FileUtf8 {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-FileBytes {
    param([string]$Path, [byte[]]$Bytes)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write($Bytes, 0, $Bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

function Read-FileBytes {
    param([string]$Path)
    return [System.IO.File]::ReadAllBytes($Path)
}

# ---------------------------------------------------------------------------
# Child invocation (frozen 04 CHILD_INVOCATION_FORM / INVOCATION)
# ---------------------------------------------------------------------------
# C-style escape for a single argument value so it survives the PS 5.1 -File
# legacy tokenizer (inverse of CommandLineToArgvW). Values with no whitespace
# and no double-quote are returned unchanged (byte-identical to the previous
# unquoted join); otherwise the value is wrapped in double quotes with inner
# quotes escaped and backslash runs before a quote or at end-of-value doubled.
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

function Invoke-Tool {
    param([Alias('Args')][object[]]$ArgList = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $tok = foreach ($a in $ArgList) { $s = [string]$a; if ($s.StartsWith('-')) { $s } else { ConvertTo-FileArgToken $s } }
    $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $script:Tool, ($tok -join ' '))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $psi.WorkingDirectory = $script:Ws
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()
    $exited = $p.WaitForExit(180000)
    $timedOut = (-not $exited)
    if ($timedOut) {
        try { $p.Kill() } catch { }
        $null = $p.WaitForExit()
    }
    $so = ''
    $se = ''
    if (-not $timedOut) {
        if (-not $soTask.Wait(15000)) { $timedOut = $true }
        if (-not $seTask.Wait(15000)) { $timedOut = $true }
    }
    if (-not $timedOut) {
        try { $so = $soTask.Result } catch { }
        try { $se = $seTask.Result } catch { }
    }
    $exitCode = -1
    if (-not $timedOut) {
        try { $exitCode = $p.ExitCode } catch { $exitCode = -1 }
    }
    $lines = @($so -split "`r`n" | Where-Object { $_ -ne '' })
    $sw.Stop()
    return @{
        exit = $exitCode
        stdout = $so
        stdout_lines = $lines
        json = $null
        stderr = $se
        timed_out = $timedOut
        ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    }
}

function Parse-JsonLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { return ($Line | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------
# Diagnostics / structured output checks
# ---------------------------------------------------------------------------
function Test-DiagVocabulary {
    param($Diags)
    foreach ($d in $Diags) {
        $s = [string]$d
        if ($script:DiagStatic -contains $s) { continue }
        $ok = $false
        foreach ($pat in $script:DiagPatterns) { if ($s -match $pat) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    return $true
}

function Check-JsonContract {
    param($R, [string]$ExpectedStatus, [string]$ExpectedOp, $ExpectedRecords, $ExpectedDiagContains, $ExpectedExit)
    # Returns list of failure strings. Enforces the frozen structured-output
    # contract: exactly one stdout line, valid single JSON object, status in the
    # 8-status vocabulary, operation in the 8-op vocabulary, exit mapping,
    # diagnostics within the closed vocabulary.
    $f = New-Object System.Collections.Generic.List[string]
    if ($R.timed_out) { $f.Add('child process timed out'); return $f }
    if ($R.stdout_lines.Count -ne 1) { $f.Add(('stdout line count ' + $R.stdout_lines.Count + ' != 1')) }
    $j = $null
    if ($R.stdout_lines.Count -ge 1) { $j = Parse-JsonLine -Line $R.stdout_lines[0] }
    if ($null -eq $j) {
        if ($f.Count -eq 0) { $f.Add('stdout is not a single valid JSON object line') }
        return $f
    }
    $st = [string]$j.status
    if ($st -notin $script:StatusSet) { $f.Add(('status ' + $st + ' outside 8-status vocabulary')) }
    if ($null -ne $ExpectedStatus -and $st -cne $ExpectedStatus) { $f.Add(('status ' + $st + ' != expected ' + $ExpectedStatus)) }
    $op = [string]$j.operation
    if ($op -notin $script:OpSet) { $f.Add(('operation ' + $op + ' outside 8-op vocabulary')) }
    if ($null -ne $ExpectedOp -and $op -cne $ExpectedOp) { $f.Add(('operation ' + $op + ' != expected ' + $ExpectedOp)) }
    $recs = @()
    if ($null -ne $j.records) { $recs = @($j.records) }
    if ($null -ne $ExpectedRecords) {
        $er = @($ExpectedRecords)
        if ($recs.Count -ne $er.Count) {
            $f.Add(('records count ' + $recs.Count + ' != expected ' + $er.Count))
        } else {
            for ($i = 0; $i -lt $recs.Count; $i++) {
                if ("$($recs[$i])" -cne "$($er[$i])") { $f.Add(('records[' + $i + '] ' + $recs[$i] + ' != ' + $er[$i])) }
            }
        }
    }
    $diags = @()
    if ($null -ne $j.diagnostics) { $diags = @($j.diagnostics) }
    if (-not (Test-DiagVocabulary -Diags $diags)) {
        $bad = @($diags | Where-Object {
            $s = [string]$_
            if ($script:DiagStatic -contains $s) { return $false }
            foreach ($pat in $script:DiagPatterns) { if ($s -match $pat) { return $false } }
            return $true
        })
        $f.Add(('diagnostics outside vocabulary: ' + ($bad -join ',')))
    }
    foreach ($d in $ExpectedDiagContains) {
        if ($diags -notcontains $d) { $f.Add(('diagnostics missing ' + $d)) }
    }
    if ($null -ne $ExpectedExit) {
        if ($R.exit -ne $ExpectedExit) { $f.Add(('exit ' + $R.exit + ' != expected ' + $ExpectedExit)) }
    } else {
        # frozen exit mapping: PASS/HIT/MISS -> 0, operational non-success -> 1,
        # pre-operation FAILED+USAGE_ERROR -> 2
        if ($st -in @('PASS', 'HIT', 'MISS')) {
            if ($R.exit -ne 0) { $f.Add(('exit ' + $R.exit + ' != 0 for ' + $st)) }
        } elseif ($st -eq 'FAILED' -and ($diags -contains 'USAGE_ERROR')) {
            if ($R.exit -ne 2) { $f.Add(('exit ' + $R.exit + ' != 2 for usage error')) }
        } else {
            if ($R.exit -ne 1) { $f.Add(('exit ' + $R.exit + ' != 1 for ' + $st)) }
        }
    }
    # state_id shape
    $sid = $j.state_id
    if ($null -eq $sid) { $f.Add('state_id missing') } else {
        foreach ($k in @('generation', 'operation_id', 'spec_sha256', 'core_sha256', 'index_sha256', 'archive_sha256', 'current')) {
            if (-not ($sid.PSObject.Properties.Name -contains $k)) { $f.Add(('state_id missing key ' + $k)) }
        }
    }
    return $f
}

# ---------------------------------------------------------------------------
# STATE_SNAPSHOT_RULE (frozen 04): recursive hash manifest of memory root and
# scratchpad root before/after every invocation. The empty .lock file at
# memory root is excluded from unexpected-file checks.
# ---------------------------------------------------------------------------
function Get-Manifest {
    param([string]$Root)
    $m = [ordered]@{}
    if (Test-Path -LiteralPath $Root) {
        foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
            if ($rel -ieq '.lock') { continue }
            $m[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $m
}

function Get-GenList {
    param([string]$MemRoot)
    $g = Join-Path $MemRoot '.gen'
    if (-not (Test-Path -LiteralPath $g)) { return @() }
    return @((Get-ChildItem -LiteralPath $g -Directory -Force | ForEach-Object { $_.Name }))
}

function Compare-Manifests {
    param($Before, $After)
    $f = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Before.Keys) {
        if (-not $After.Contains($k)) { $f.Add('file removed: ' + $k) }
        elseif ($Before[$k] -cne $After[$k]) { $f.Add('file changed: ' + $k) }
    }
    foreach ($k in $After.Keys) {
        if (-not $Before.Contains($k)) { $f.Add('unexpected new file: ' + $k) }
    }
    return $f
}

# ---------------------------------------------------------------------------
# Spec builders (frozen 04 SPEC_FILE_RULES: UTF-8 no BOM, fresh lowercase UUID
# operation_id, exact bytes preserved, SHA256 computed by the runner)
# ---------------------------------------------------------------------------
function Get-ActiveStateHashes {
    param([string]$MemRoot)
    # returns @{ gen; core; index; archive; op } for the ACTIVE generation
    $ap = Join-Path $MemRoot 'ACTIVE'
    if (-not (Test-Path -LiteralPath $ap)) { return $null }
    $txt = [System.IO.File]::ReadAllText($ap, $script:Utf8NoBom)
    $lines = @($txt -split "`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -ne 7) { return $null }
    $vals = @{}
    foreach ($ln in $lines) { $i = $ln.IndexOf('='); $vals[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    $g = [int]$vals['GENERATION']
    $dir = Join-Path (Join-Path $MemRoot '.gen') ('{0:000000}' -f $g)
    $stPath = Join-Path $dir 'STATE'
    if (-not (Test-Path -LiteralPath $stPath)) { return $null }
    $st = [System.IO.File]::ReadAllText($stPath, $script:Utf8NoBom)
    $vals2 = @{}
    foreach ($ln in (@($st -split "`n" | Where-Object { $_ -ne '' }))) { $i = $ln.IndexOf('='); $vals2[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    return @{ gen = $g; core = $vals2['CORE_SHA256']; index = $vals2['INDEX_SHA256']; archive = $vals2['ARCHIVE_SHA256']; op = $vals['OPERATION_ID'] }
}

function Write-SpecFile {
    param([string]$Root, [string]$Name, $SpecObj)
    $json = $SpecObj | ConvertTo-Json -Depth 12 -Compress
    $bytes = $script:Utf8NoBom.GetBytes($json)
    $path = Join-Path (Join-Path $Root 'scratchpad') $Name
    Write-FileBytes -Path $path -Bytes $bytes
    return @{ path = $path; sha = (Get-Sha256Hex -Bytes $bytes); bytes = $bytes }
}

function New-ExpectedBlock {
    param([int]$Generation, [string]$Core, [string]$Index, [string]$Archive)
    return [pscustomobject]@{ generation = $Generation; core = $Core; index = $Index; archive = $Archive }
}

function New-EmptyExpected {
    return (New-ExpectedBlock -Generation 0 -Core 'ABSENT' -Index 'ABSENT' -Archive 'ABSENT')
}

function New-InitializeSpec {
    param([string]$OpId, $Expected)
    return [pscustomobject]@{ operation_id = $OpId; expected = $Expected; operations = @([pscustomobject]@{ op = 'initialize' }) }
}

function New-AddOp {
    param([string]$Subject, [string]$Summary, [string]$Provenance, $Tags, $Note, $Evidence, $Pin, $Supersedes)
    $o = [ordered]@{ op = 'add' }
    $o['subject'] = $Subject
    $o['summary'] = $Summary
    $o['provenance'] = $Provenance
    if ($null -ne $Tags) { $o['tags'] = $Tags }
    if ($null -ne $Note) { $o['note'] = $Note }
    if ($null -ne $Evidence) { $o['evidence'] = $Evidence }
    if ($null -ne $Pin) { $o['pin'] = $Pin }
    if ($null -ne $Supersedes) { $o['supersedes'] = $Supersedes }
    return (New-Object PSObject -Property $o)
}

function New-CommitSpec {
    param([string]$OpId, $Expected, $Ops)
    return [pscustomobject]@{ operation_id = $OpId; expected = $Expected; operations = $Ops }
}

function New-ForgetSpec {
    param([string]$OpId, [string]$RecordId, $Expected)
    return [pscustomobject]@{ operation_id = $OpId; expected = $Expected; operations = @([pscustomobject]@{ op = 'forget'; record_id = $RecordId }) }
}

function New-RestoreSpec {
    param([string]$OpId, [string]$RecordId, $Expected)
    return [pscustomobject]@{ operation_id = $OpId; expected = $Expected; operations = @([pscustomobject]@{ op = 'restore'; record_id = $RecordId }) }
}

function New-PinSpec {
    param([string]$OpId, [string]$RecordId, $Expected, [string]$OpType)
    return [pscustomobject]@{ operation_id = $OpId; expected = $Expected; operations = @([pscustomobject]@{ op = $OpType; record_id = $RecordId }) }
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
# Build an initialized fixture (generation 1) and return the spec sha of the
# initialize operation for later assertions.
function Build-InitializedFixture {
    param([string]$Root)
    $mem = Join-Path (Join-Path $Root 'workspace') 'memory'
    $opId = New-Uuid
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_init.json' -SpecObj (New-InitializeSpec -OpId $opId -Expected (New-EmptyExpected))
    $r = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', $mem, '-WorkspaceRoot', (Join-Path $Root 'workspace'), '-ScratchpadRoot', (Join-Path $Root 'scratchpad'), '-Spec', $sp.path)
    return @{ opId = $opId; specSha = $sp.sha; r = $r }
}

# Build generation 1 + one committed record with note (generation 2).
# Returns mem root and the record id (mem_0001).
function Build-Gen2Fixture {
    param([string]$Root, [string]$Subject, [string]$Summary, [string]$Provenance, [string]$Note, $EvidenceRel)
    $mem = Join-Path (Join-Path $Root 'workspace') 'memory'
    $init = Build-InitializedFixture -Root $Root
    $st = Get-ActiveStateHashes -MemRoot $mem
    $opId = New-Uuid
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_add1.json' -SpecObj (New-CommitSpec -OpId $opId -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @(New-AddOp -Subject $Subject -Summary $Summary -Provenance $Provenance -Tags @('t1') -Note $Note -Evidence $EvidenceRel))
    $r = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', $mem, '-WorkspaceRoot', (Join-Path $Root 'workspace'), '-ScratchpadRoot', (Join-Path $Root 'scratchpad'), '-Spec', $sp.path)
    return @{ init = $init; st = $st; opId = $opId; specSha = $sp.sha; r = $r; mem = $mem }
}

# Build generation 2 with a MACHINE_VERIFIED record + evidence + note.
function Build-Gen2EvidenceFixture {
    param([string]$Root)
    $ws = Join-Path $Root 'workspace'
    $evDir = Join-Path $ws 'evidence'
    [System.IO.Directory]::CreateDirectory($evDir) | Out-Null
    Write-FileUtf8 -Path (Join-Path $evDir 'fact1.md') -Text 'DETERMINISTIC EVIDENCE FACT 1 for BAM fixture'
    return (Build-Gen2Fixture -Root $Root -Subject 'alpha fact' -Summary 'deterministic summary alpha' -Provenance 'MACHINE_VERIFIED' -Note 'NOTE BODY alpha deterministic content N1' -EvidenceRel 'evidence/fact1.md')
}

# ---------------------------------------------------------------------------
# Per-case harness
# ---------------------------------------------------------------------------
function Register-Case {
    param([string]$Id)
    if (-not $script:Results.ContainsKey($Id)) {
        $script:Results[$Id] = @{ status = 'NOT_RUN'; failures = @() }
        $script:Order += $Id
    }
}

function Set-CaseFailure {
    param([string]$Id, $Msgs)
    $script:Results[$Id].status = 'FAIL'
    $script:Results[$Id].failures += @($Msgs)
}

function Set-CaseError {
    param([string]$Id, [string]$Msg)
    $script:Results[$Id].status = 'FAIL'
    $script:Results[$Id].failures += @('RUNNER_ERROR: ' + $Msg)
}

function Set-CasePass {
    param([string]$Id)
    if ($script:Results[$Id].status -ne 'FAIL') { $script:Results[$Id].status = 'PASS' }
}

# Run one case. $ScriptBlock receives the fixture root path as $args[0].
# The script block may register additional failures via Set-CaseFailure.
function Run-Case {
    param([string]$Id, [scriptblock]$Block)
    Register-Case -Id $Id
    $root = $null
    try {
        $root = New-FixtureRoot
        $script:Results[$Id].fixture = $root
        & $Block $root
        if ($script:Results[$Id].status -ne 'FAIL') { Set-CasePass -Id $Id }
    } catch {
        Set-CaseError -Id $Id -Msg ($_.Exception.Message)
    } finally {
        # success -> delete fixture; failure -> keep fixture (frozen 04 FIXTURE_CONVENTIONS)
        if ($script:Results[$Id].status -eq 'PASS') {
            Remove-FixtureRoot -Root $root
        }
    }
}

function Get-CaseRootArgs {
    param([string]$Root)
    return @{ mem = (Join-Path (Join-Path $Root 'workspace') 'memory'); ws = (Join-Path $Root 'workspace'); sp = (Join-Path $Root 'scratchpad') }
}

function Tool-Args {
    param([string]$Root, [string]$Mode, [hashtable]$Extra = @{})
    $a = @('-Mode', $Mode, '-MemoryRoot', (Join-Path (Join-Path $Root 'workspace') 'memory'), '-WorkspaceRoot', (Join-Path $Root 'workspace'))
    if ($Extra.ContainsKey('sp')) { $a += @('-ScratchpadRoot', (Join-Path $Root 'scratchpad')) }
    # Labeled extra parameters (runner bug fix): every extra key is emitted as
    # '-<key>' + value(s). A bare [bool]$true maps to a name-only switch token
    # (tool [switch] parameters, e.g. -TestMode); arrays/scalars carry their values.
    foreach ($k in $Extra.Keys) {
        if ($k -eq 'sp') { continue }
        $v = $Extra[$k]
        if ($v -is [bool]) { $a += ('-' + $k) }
        elseif ($v -is [string] -or $v -is [int]) { $a += @(('-' + $k), ([string]$v)) }
        else { $a += (@('-' + $k) + @($v)) }
    }
    return $a
}

function New-String {
    param([int]$Len, [string]$Ch, [string]$Suffix = '')
    return (($Ch * $Len) + $Suffix)
}

# ---------------------------------------------------------------------------
# Case: AM-T-001
# ---------------------------------------------------------------------------
function Test-AMT001 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $opId = New-Uuid
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_a.json' -SpecObj (New-InitializeSpec -OpId $opId -Expected (New-EmptyExpected))
    $specSha = $sp.sha
    $m0 = Get-Manifest -Root $a.mem
    $s0 = Get-Manifest -Root $a.sp
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r1 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id 'AM-T-001' $f; return }
    $j1 = Parse-JsonLine -Line $r1.stdout_lines[0]
    if ([int]$j1.state_id.generation -ne 1) { Set-CaseFailure -Id 'AM-T-001' @('state_id.generation != 1 after initialize') }
    if ([string]$j1.state_id.operation_id -cne $opId) { Set-CaseFailure -Id 'AM-T-001' @('state_id.operation_id != spec operation_id') }
    # canonical state assertions
    $actPath = Join-Path $a.mem 'ACTIVE'
    if (-not (Test-Path -LiteralPath $actPath)) { Set-CaseFailure -Id 'AM-T-001' @('ACTIVE missing'); return }
    $actTxt = [System.IO.File]::ReadAllText($actPath, $script:Utf8NoBom)
    $expAct = ('GENERATION=1' + "`n" + 'OPERATION_ID=' + $opId + "`n" + 'SPEC_SHA256=' + $specSha + "`n" + 'STATE_SHA256=' + (Get-TextSha256Hex -Text (Get-StateTextOf -MemRoot $a.mem -Gen 1)) + "`n" + 'ACTION=initialize' + "`n" + 'AFFECTED_IDS=-' + "`n" + 'RESULT=PASS' + "`n")
    if ($actTxt -cne $expAct) { Set-CaseFailure -Id 'AM-T-001' @('ACTIVE receipt text deviates from expected 7-line form') }
    # CURRENT is the 4-line WRITER record (GENERATION/OPERATION_ID/SPEC_SHA256/STATE_SHA256);
    # ACTIVE is the 7-line receipt. Identity = first 4 lines identical (01 D3.5; 04 AM-T-001).
    $curPath = Join-Path $a.mem 'CURRENT'
    if (-not (Test-Path -LiteralPath $curPath)) { Set-CaseFailure -Id 'AM-T-001' @('CURRENT missing') } else {
        $curTxt = [System.IO.File]::ReadAllText($curPath, $script:Utf8NoBom)
        $curLines = @($curTxt -split "`n" | Where-Object { $_ -ne '' })
        if ($curLines.Count -ne 4) {
            Set-CaseFailure -Id 'AM-T-001' @('CURRENT not exactly 4-line writer record')
        } else {
            $actLines = @($actTxt -split "`n" | Where-Object { $_ -ne '' })
            for ($i = 0; $i -lt 4; $i++) {
                if ($curLines[$i] -cne $actLines[$i]) { Set-CaseFailure -Id 'AM-T-001' @('CURRENT line ' + ($i + 1) + ' deviates from ACTIVE identity line') }
            }
        }
    }
    $gen1 = Join-Path (Join-Path $a.mem '.gen') '000001'
    foreach ($fn in @('core.md', 'index.md', 'archive.md', 'STATE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $gen1 $fn))) { Set-CaseFailure -Id 'AM-T-001' @('gen1 ' + $fn + ' missing') }
    }
    $coreTxt = [System.IO.File]::ReadAllText((Join-Path $gen1 'core.md'), $script:Utf8NoBom)
    if ($coreTxt -cne ('# memory-core v1' + "`n")) { Set-CaseFailure -Id 'AM-T-001' @('core.md not header-only') }
    $idxTxt = [System.IO.File]::ReadAllText((Join-Path $gen1 'index.md'), $script:Utf8NoBom)
    if ($idxTxt -cne ('# memory-index v1' + "`n")) { Set-CaseFailure -Id 'AM-T-001' @('index.md not header-only') }
    $arcTxt = [System.IO.File]::ReadAllText((Join-Path $gen1 'archive.md'), $script:Utf8NoBom)
    if ($arcTxt -cne ('# memory-archive v1' + "`n")) { Set-CaseFailure -Id 'AM-T-001' @('archive.md not header-only') }
    $stateTxt = [System.IO.File]::ReadAllText((Join-Path $gen1 'STATE'), $script:Utf8NoBom)
    $stateLines = @($stateTxt -split "`n" | Where-Object { $_ -ne '' })
    if ($stateLines.Count -ne 11) { Set-CaseFailure -Id 'AM-T-001' @('STATE not exactly 11 head lines') }
    # receipts empty
    $recDir = Join-Path $a.mem 'receipts'
    if (Test-Path -LiteralPath $recDir) {
        $rc = @(Get-ChildItem -LiteralPath $recDir -File -Force).Count
        if ($rc -ne 0) { Set-CaseFailure -Id 'AM-T-001' @('receipts not empty after initialize') }
    }
    # Validate
    $r2 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f2 = @(Check-JsonContract -R $r2 -ExpectedStatus 'PASS' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f2.Count -gt 0) { Set-CaseFailure -Id 'AM-T-001' $f2; return }
    $j2 = Parse-JsonLine -Line $r2.stdout_lines[0]
    if ([int]$j2.state_id.generation -ne 1) { Set-CaseFailure -Id 'AM-T-001' @('Validate state_id.generation != 1') }
    if ([string]$j2.state_id.operation_id -cne $opId) { Set-CaseFailure -Id 'AM-T-001' @('Validate state_id.operation_id mismatch') }
    # no note files anywhere; scratchpad only spec A
    $notes = @(Get-ChildItem -LiteralPath (Join-Path $gen1 'notes') -File -Force -ErrorAction SilentlyContinue)
    if ($notes.Count -ne 0) { Set-CaseFailure -Id 'AM-T-001' @('note files exist in gen1') }
    $spFiles = @(Get-ChildItem -LiteralPath $a.sp -Recurse -File -Force)
    if ($spFiles.Count -ne 1) { Set-CaseFailure -Id 'AM-T-001' @('scratchpad contains more than spec A') }
}

# ---------------------------------------------------------------------------
# Shared assertion helpers (added for the AM-T-002..041 case set)
# ---------------------------------------------------------------------------
function Get-StateTextOf {
    param([string]$MemRoot, [int]$Gen)
    $p = Join-Path (Join-Path (Join-Path $MemRoot '.gen') ('{0:000000}' -f $Gen)) 'STATE'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [System.IO.File]::ReadAllText($p, $script:Utf8NoBom)
}

function Get-GenDirOf {
    param([string]$MemRoot, [int]$Gen)
    return (Join-Path (Join-Path $MemRoot '.gen') ('{0:000000}' -f $Gen))
}

function Get-RecordLineOf {
    param([string]$MemRoot, [int]$Gen, [string]$Id)
    $g = Get-GenDirOf -MemRoot $MemRoot -Gen $Gen
    foreach ($fn in @('core.md', 'index.md')) {
        $p = Join-Path $g $fn
        if (Test-Path -LiteralPath $p) {
            foreach ($ln in (@(([System.IO.File]::ReadAllText($p, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' }))) {
                if ($ln.StartsWith($Id + '|')) { return $ln }
            }
        }
    }
    return ''
}

function Get-RecordLineFields {
    param([string]$Line)
    $f = $Line -split '\|'
    if ($f.Count -lt 10) { return $null }
    return $f
}

function Get-GenNoteBytes {
    param([string]$MemRoot, [int]$Gen, [string]$Id)
    $p = Join-Path (Join-Path (Get-GenDirOf -MemRoot $MemRoot -Gen $Gen) 'notes') ($Id + '.md')
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Read-FileBytes -Path $p)
}

function Get-ArchiveLines {
    param([string]$MemRoot, [int]$Gen)
    $p = Join-Path (Get-GenDirOf -MemRoot $MemRoot -Gen $Gen) 'archive.md'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(([System.IO.File]::ReadAllText($p, $script:Utf8NoBom)) -split "`n" | Where-Object { ($_ -ne '') -and ($_ -notmatch '^#') })
}

function Assert-ManifestUnchanged {
    param([string]$Id, $Before, $After)
    $d = @(Compare-Manifests -Before $Before -After $After)
    if ($d.Count -gt 0) { Set-CaseFailure -Id $Id @(('manifest changed: ' + ($d -join ' | '))) }
}

function Assert-GenFilesPresent {
    param([string]$Id, [string]$MemRoot, [int]$Gen)
    $g = Get-GenDirOf -MemRoot $MemRoot -Gen $Gen
    foreach ($fn in @('core.md', 'index.md', 'archive.md', 'STATE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $g $fn))) { Set-CaseFailure -Id $Id @(('gen' + $Gen + ' file missing: ' + $fn)) }
    }
}

function New-NoteFiller {
    param([int]$Bytes)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .-'
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($sb.Length -lt $Bytes) { $null = $sb.Append($chars[$i % $chars.Length]); $i++ }
    return ($sb.ToString().Substring(0, $Bytes))
}

function Get-ContentBytesAfterHeader {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $b = Read-FileBytes -Path $Path
    $i = 0
    while ($i -lt $b.Length -and $b[$i] -ne 10) { $i++ }
    if ($i -ge $b.Length) { return 0 }
    return ($b.Length - ($i + 1))
}

function Assert-Candidates {
    param([string]$Id, $J, $ExpectedIds)
    $cands = @($J.candidates)
    if ($cands.Count -ne $ExpectedIds.Count) { Set-CaseFailure -Id $Id @(('candidate count ' + $cands.Count + ' != expected ' + $ExpectedIds.Count)); return }
    $ids = @($cands | ForEach-Object { [string]$_.record_id })
    $exp = @($ExpectedIds)
    if ($ids.Count -ne $exp.Count) { Set-CaseFailure -Id $Id @('candidate id set size mismatch'); return }
    $missing = @($exp | Where-Object { $ids -notcontains $_ })
    $extra = @($ids | Where-Object { $exp -notcontains $_ })
    if ($missing.Count -gt 0) { Set-CaseFailure -Id $Id @('candidates missing: ' + ($missing -join ',')) }
    if ($extra.Count -gt 0) { Set-CaseFailure -Id $Id @('candidates unexpected: ' + ($extra -join ',')) }
    foreach ($c in $cands) {
        foreach ($k in @('record_id', 'recorded_at', 'subject', 'tags', 'provenance', 'source_pointer', 'note_pointer', 'evidence_status', 'matched_fields', 'matched_terms', 'score')) {
            if (-not ($c.PSObject.Properties.Name -contains $k)) { Set-CaseFailure -Id $Id @('candidate missing field ' + $k + ' on ' + [string]$c.record_id) }
        }
    }
}

function Assert-ActiveReceiptOf {
    param([string]$Id, [string]$MemRoot, [int]$Gen, [string]$OpId, [string]$SpecSha)
    $ap = Join-Path $MemRoot 'ACTIVE'
    if (-not (Test-Path -LiteralPath $ap)) { Set-CaseFailure -Id $Id @('ACTIVE missing'); return }
    $txt = [System.IO.File]::ReadAllText($ap, $script:Utf8NoBom)
    $ln = @($txt -split "`n" | Where-Object { $_ -ne '' })
    if ($ln.Count -ne 7) { Set-CaseFailure -Id $Id @('ACTIVE not 7-line receipt'); return }
    $kv = @{}
    foreach ($l in $ln) { $i2 = $l.IndexOf('='); $kv[$l.Substring(0, $i2)] = $l.Substring($i2 + 1) }
    if ([int]$kv['GENERATION'] -ne $Gen) { Set-CaseFailure -Id $Id @(('ACTIVE generation ' + $kv['GENERATION'] + ' != ' + $Gen)) }
    if ($kv['OPERATION_ID'] -cne $OpId) { Set-CaseFailure -Id $Id @('ACTIVE operation_id mismatch') }
    if ($kv['SPEC_SHA256'] -cne $SpecSha) { Set-CaseFailure -Id $Id @('ACTIVE spec_sha256 mismatch') }
    if ($kv['RESULT'] -cne 'PASS') { Set-CaseFailure -Id $Id @('ACTIVE RESULT != PASS') }
    $stateTxt = Get-StateTextOf -MemRoot $MemRoot -Gen $Gen
    if ($kv['STATE_SHA256'] -cne (Get-TextSha256Hex -Text $stateTxt)) { Set-CaseFailure -Id $Id @('ACTIVE STATE_SHA256 != sha(STATE)') }
}

function Assert-CurrentMatchesActive {
    param([string]$Id, [string]$MemRoot)
    $ap = Join-Path $MemRoot 'ACTIVE'
    $cp = Join-Path $MemRoot 'CURRENT'
    if (-not (Test-Path -LiteralPath $ap) -or -not (Test-Path -LiteralPath $cp)) { Set-CaseFailure -Id $Id @('ACTIVE or CURRENT missing'); return }
    $a = @([System.IO.File]::ReadAllText($ap, $script:Utf8NoBom) -split "`n" | Where-Object { $_ -ne '' })
    $c = @([System.IO.File]::ReadAllText($cp, $script:Utf8NoBom) -split "`n" | Where-Object { $_ -ne '' })
    if ($c.Count -ne 4) { Set-CaseFailure -Id $Id @('CURRENT not 4-line writer record'); return }
    for ($i = 0; $i -lt 4; $i++) {
        if ($c[$i] -cne $a[$i]) { Set-CaseFailure -Id $Id @('CURRENT line ' + ($i + 1) + ' != ACTIVE identity line') }
    }
}

function Commit-ExpectPass {
    param([string]$Id, [string]$Root, $SpecObj, [int]$ExpGen, [string[]]$ExpRecords)
    $opId = [string]$SpecObj.operation_id
    $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_op_' + $opId.Substring(0, 8) + '.json') -SpecObj $SpecObj
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords $ExpRecords -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $Id $f; return @{ opId = $opId; specSha = $sp.sha; r = $r; ok = $false } }
    $j = Parse-JsonLine -Line $r.stdout_lines[0]
    if ([int]$j.state_id.generation -ne $ExpGen) { Set-CaseFailure -Id $Id @(('state_id.generation ' + $j.state_id.generation + ' != ' + $ExpGen)) }
    return @{ opId = $opId; specSha = $sp.sha; r = $r; ok = $true }
}

function Commit-ExpectInvalid {
    param([string]$Id, [string]$Root, $SpecObj, $DiagContains)
    $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_bad_' + (Get-Random -Maximum 2147483646) + '.json') -SpecObj $SpecObj
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains $DiagContains -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $Id $f }
    return $r
}

# C5 (2026-10-12 amendment): chunk add ops into <=16-op commit specs so large
# fixtures respect the 01 D3.4 1..16 operation bound. All ops must be plain
# adds. $Base = number of records already in the fixture before the first op
# (0 for a fresh init fixture). Returns the final active state hashes or
# $null on failure.
function Commit-BoundedMultiSpec {
    param([string]$Id, [string]$Root, $Ops, [int]$BatchSize = 16, [int]$Base = 0)
    $a = Get-CaseRootArgs -Root $Root
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opsArr = @($Ops)
    $count = $opsArr.Count
    for ($off = 0; $off -lt $count; $off += $BatchSize) {
        $n = [Math]::Min($BatchSize, $count - $off)
        $chunk = @($opsArr[$off..($off + $n - 1)])
        $expRecs = @()
        for ($k = 1; $k -le $n; $k++) { $expRecs += ('mem_{0:0000}' -f ($Base + $off + $k)) }
        $res = Commit-ExpectPass -Id $Id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st.gen -Core $st.core -Index $st.index -Archive $st.archive) -Ops $chunk) -ExpGen ($st.gen + 1) -ExpRecords $expRecs
        if (-not $res.ok) { return $null }
        $st = Get-ActiveStateHashes -MemRoot $a.mem
    }
    return $st
}

# O60: Forget/Restore are spec-driven tool modes (frozen 04), not Commit ops.
# Commit-ExpectPass/Invalid hard-code -Mode 'Commit', which the tool rejects
# with SPEC_OP_TYPE -> INVALID. These helpers mirror their style with the
# correct mode so parent and sub-cases share one verified invocation path.
function ForgetRestore-ExpectPass {
    param([string]$Id, [string]$Root, $SpecObj, [string]$Mode, [int]$ExpGen, [string[]]$ExpRecords)
    $opId = [string]$SpecObj.operation_id
    $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_op_' + $opId.Substring(0, 8) + '.json') -SpecObj $SpecObj
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode $Mode -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'PASS' -ExpectedOp ($Mode.ToLowerInvariant()) -ExpectedRecords $ExpRecords -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $Id $f; return @{ opId = $opId; specSha = $sp.sha; r = $r; ok = $false } }
    $j = Parse-JsonLine -Line $r.stdout_lines[0]
    if ([int]$j.state_id.generation -ne $ExpGen) { Set-CaseFailure -Id $Id @(('state_id.generation ' + $j.state_id.generation + ' != ' + $ExpGen)) }
    return @{ opId = $opId; specSha = $sp.sha; r = $r; ok = $true }
}

function ForgetRestore-ExpectInvalid {
    param([string]$Id, [string]$Root, $SpecObj, [string]$Mode, $DiagContains)
    $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_bad_' + (Get-Random -Maximum 2147483646) + '.json') -SpecObj $SpecObj
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode $Mode -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp ($Mode.ToLowerInvariant()) -ExpectedRecords @() -ExpectedDiagContains $DiagContains -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $Id $f }
    return $r
}

function Invoke-RecallExpect {
    param([string]$Id, [string]$Root, [string]$Query, [string]$ExpStatus, [int]$ExpMax)
    $a = Get-CaseRootArgs -Root $Root
    $args2 = @('-Mode', 'Recall', '-MemoryRoot', $a.mem, '-WorkspaceRoot', $a.ws, '-Query', $Query)
    if ($ExpMax -gt 0) { $args2 += @('-Max', [string]$ExpMax) }
    $r = Invoke-Tool -Args $args2
    $f = @(Check-JsonContract -R $r -ExpectedStatus $ExpStatus -ExpectedOp 'recall' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $Id $f }
    $j = $null
    if ($r.stdout_lines.Count -eq 1) { $j = Parse-JsonLine -Line $r.stdout_lines[0] }
    return @{ r = $r; j = $j }
}

function Flip-ByteAt {
    param([string]$Path, [int]$Idx, [byte]$Val)
    $b = Read-FileBytes -Path $Path
    $b[$Idx] = $Val
    Write-FileBytes -Path $Path -Bytes $b
}

function Write-SpecRawBytes {
    param([string]$Root, [string]$Name, [byte[]]$Bytes)
    $p = Join-Path (Join-Path $Root 'scratchpad') $Name
    Write-FileBytes -Path $p -Bytes $Bytes
    return @{ path = $p; sha = (Get-Sha256Hex -Bytes $Bytes) }
}

function Get-ReceiptsFiles {
    param([string]$MemRoot)
    $d = Join-Path $MemRoot 'receipts'
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -File -Force)
}

function Get-NoteShaLines {
    param([string]$MemRoot, [int]$Gen)
    $t = Get-StateTextOf -MemRoot $MemRoot -Gen $Gen
    return @(($t -split "`n") | Where-Object { $_ -like 'NOTE_SHA256=*' })
}
# ---------------------------------------------------------------------------
# Case: AM-T-002 (parent: spec validation variants a-f, corruption g-h)
# ---------------------------------------------------------------------------
function Test-AMT002 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002'
    # Parent own variants (a)-(f): spec-level validation on a fresh gen1 base
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $variants = @(
        @{ s = (New-String -Len 65 -Ch 'a'); su = 's1' },
        @{ s = 'ok subject'; su = ('bad|pipe') },
        @{ s = 'ok subject'; su = 's2'; tags = @('a', 'b', 'c', 'd', 'e') },
        @{ s = 'ok subject'; su = 's3'; tags = @('UPPER') },
        @{ s = 'ok subject'; su = 's4'; prov = 'INVENTED' },
        @{ s = 'ok subject'; su = (New-String -Len 257 -Ch 'b') }
    )
    for ($i = 0; $i -lt $variants.Count; $i++) {
        $v = $variants[$i]
        $prov = 'USER_STATED'
        if ($v.Contains('prov')) { $prov = $v['prov'] }
        $tags = $null
        if ($v.Contains('tags')) { $tags = $v['tags'] }
        $op = New-AddOp -Subject $v['s'] -Summary $v['su'] -Provenance $prov -Tags $tags -Note $null -Evidence $null -Pin $null -Supersedes $null
        $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
        $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_v' + $i + '.json') -SpecObj $spec
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
        $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
        if ($f.Count -gt 0) { Set-CaseFailure -Id $id @(('variant ' + [char](97 + $i) + ': ' + ($f -join ' | '))); continue }
        $m1 = Get-Manifest -Root $a.mem
        $d = @(Compare-Manifests -Before $m0 -After $m1)
        if ($d.Count -gt 0) { Set-CaseFailure -Id $id @(('variant ' + [char](97 + $i) + ' state change: ' + ($d -join ' | '))) }
    }
    # (g)(h) post-commit corruption variants
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'corr base' -Summary 'corr summary' -Provenance 'USER_STATED' -Note 'NOTE CORP BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    # (g) parent own corruption: rewrite one index.md record line to 9 pipe fields
    $idx = Join-Path $gen2 'index.md'
    $lines = [System.IO.File]::ReadAllLines($idx, $script:Utf8NoBom)
    $gi = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('mem_')) { $gi = $i; break } }
    if ($gi -lt 0) { Set-CaseFailure -Id $id @('(g) no record line found in index.md'); return }
    $fld = @($lines[$gi] -split '\|')
    $nine = (($fld[0..8]) -join '|')
    $lines[$gi] = $nine
    [System.IO.File]::WriteAllLines($idx, $lines, $script:Utf8NoBom)
    $rg = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fg = @(Check-JsonContract -R $rg -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fg.Count -gt 0) { Set-CaseFailure -Id $id @('(g) ' + ($fg -join ' | ')) }
    # (h) parent own corruption: flip one byte inside notes/mem_0001.md
    # (this parent variant is the same corruption as frozen group-E row AM-T-002.d)
    $np = Join-Path (Join-Path $gen2 'notes') 'mem_0001.md'
    Flip-ByteAt -Path $np -Idx 0 -Val 65
    $rh = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fh = @(Check-JsonContract -R $rh -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fh.Count -gt 0) { Set-CaseFailure -Id $id @('(h) ' + ($fh -join ' | ')) }
    # Group E frozen sub-case rows 002.a-e (each on a fresh gen2 base in its own sub-root)
    foreach ($gv in @('a', 'b', 'c', 'e', 'f')) {
        $eRoot = Join-Path $Root ('ge_' + $gv)
        [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $eRoot 'workspace') 'memory')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $eRoot 'scratchpad')) | Out-Null
        $aE = Get-CaseRootArgs -Root $eRoot
        $g2e = Build-Gen2Fixture -Root $eRoot -Subject ('ge' + $gv + ' base') -Summary ('ge' + $gv + ' base sum') -Provenance 'USER_STATED' -Note ('GE' + $gv + ' NOTE BODY base content') -Evidence $null
        if ($g2e.r.exit -ne 0) { Set-CaseFailure -Id $id @(('002.' + $gv + ' gen2 build failed')); return }
        $gen2e = Get-GenDirOf -MemRoot $aE.mem -Gen 2
        if ($gv -eq 'a') {
            Flip-ByteAt -Path (Join-Path $gen2e 'core.md') -Idx ([math]::Min(20, (Read-FileBytes -Path (Join-Path $gen2e 'core.md')).Length - 1)) -Val 65
        } elseif ($gv -eq 'b') {
            $ipE = Join-Path $gen2e 'index.md'
            $ibE = Read-FileBytes -Path $ipE
            Flip-ByteAt -Path $ipE -Idx ([math]::Min(24, $ibE.Length - 1)) -Val 65
        } elseif ($gv -eq 'c') {
            $apE = Join-Path $gen2e 'archive.md'
            $abE = Read-FileBytes -Path $apE
            Flip-ByteAt -Path $apE -Idx ([math]::Min(20, $abE.Length - 1)) -Val 65
        } elseif ($gv -eq 'e') {
            Write-FileUtf8 -Path (Join-Path (Join-Path $gen2e 'notes') 'mem_9999.md') -Text 'UNLISTED NOTE FILE body'
        } else {
            [System.IO.File]::Delete((Join-Path (Join-Path $gen2e 'notes') 'mem_0001.md'))
        }
        $mE0 = Get-Manifest -Root $aE.mem
        $rv = Invoke-Tool -Args (Tool-Args -Root $eRoot -Mode 'Validate')
        $fv = @(Check-JsonContract -R $rv -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
        if ($fv.Count -gt 0) { Set-CaseFailure -Id $id @(('002.' + $gv + ': ' + ($fv -join ' | '))) }
        Assert-ManifestUnchanged -Id $id -Before $mE0 -After (Get-Manifest -Root $aE.mem)
    }
    # Group E frozen sub-case rows 002.g/002.h (fresh gen2 base each, own sub-root)
    foreach ($gv in @('g', 'h')) {
        $eRoot = Join-Path $Root ('ge_' + $gv)
        [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $eRoot 'workspace') 'memory')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $eRoot 'scratchpad')) | Out-Null
        $aE = Get-CaseRootArgs -Root $eRoot
        $g2e = Build-Gen2Fixture -Root $eRoot -Subject ('ge' + $gv + ' base') -Summary ('ge' + $gv + ' base sum') -Provenance 'USER_STATED' -Note ('GE' + $gv + ' NOTE BODY base content') -Evidence $null
        if ($g2e.r.exit -ne 0) { Set-CaseFailure -Id $id @(('002.' + $gv + ' gen2 build failed')); return }
        $gen2e = Get-GenDirOf -MemRoot $aE.mem -Gen 2
        if ($gv -eq 'g') {
            $cpE = Join-Path $gen2e 'core.md'
            $cbE = Read-FileBytes -Path $cpE
            $cb2E = New-Object byte[] ($cbE.Length + 1)
            $insPosE = [Math]::Min(1, $cbE.Length - 1); if ($insPosE -lt 0) { $insPosE = 0 }
            [Array]::Copy($cbE, 0, $cb2E, 0, $insPosE)
            $cb2E[$insPosE] = 0xFF
            [Array]::Copy($cbE, $insPosE, $cb2E, ($insPosE + 1), ($cbE.Length - $insPosE))
            Write-FileBytes -Path $cpE -Bytes $cb2E
        } else {
            $ipE = Join-Path $gen2e 'index.md'
            $ibE = Read-FileBytes -Path $ipE
            $ib2E = New-Object byte[] ($ibE.Length + 3)
            $ib2E[0] = 0xEF; $ib2E[1] = 0xBB; $ib2E[2] = 0xBF
            [Array]::Copy($ibE, 0, $ib2E, 3, $ibE.Length)
            Write-FileBytes -Path $ipE -Bytes $ib2E
        }
        $mE0 = Get-Manifest -Root $aE.mem
        $rv = Invoke-Tool -Args (Tool-Args -Root $eRoot -Mode 'Validate')
        $fv = @(Check-JsonContract -R $rv -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
        if ($fv.Count -gt 0) { Set-CaseFailure -Id $id @(('002.' + $gv + ': ' + ($fv -join ' | '))) }
        Assert-ManifestUnchanged -Id $id -Before $mE0 -After (Get-Manifest -Root $aE.mem)
    }
    # Group E frozen sub-case row 002.i: two generations (gen2, gen3); Recall after gen3 (own sub-root)
    $eRootI = Join-Path $Root 'ge_i'
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $eRootI 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $eRootI 'scratchpad')) | Out-Null
    $g2i = Build-Gen2Fixture -Root $eRootI -Subject 'gei base' -Summary 'gei base sum' -Provenance 'USER_STATED' -Note 'GEI NOTE BODY' -Evidence $null
    if ($g2i.r.exit -ne 0) { Set-CaseFailure -Id $id @('002.i gen2 build failed'); return }
    $sti = Get-ActiveStateHashes -MemRoot (Join-Path (Join-Path $eRootI 'workspace') 'memory')
    $null = Commit-ExpectPass -Id $id -Root $eRootI -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $sti.core -Index $sti.index -Archive $sti.archive) -Ops @(New-AddOp -Subject 'gei second' -Summary 'gei second sum' -Provenance 'USER_STATED' -Tags @() -Note $null -Evidence $null -Pin $null -Supersedes $null)) -ExpGen 3 -ExpRecords @('mem_0002')
    $rrI = Invoke-RecallExpect -Id $id -Root $eRootI -Query 'gei' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rrI.j) { Set-CaseFailure -Id $id @('002.i recall no json'); return }
    Assert-Candidates -Id $id -J $rrI.j -ExpectedIds @('mem_0001', 'mem_0002')
}

# ---------------------------------------------------------------------------
# Case: AM-T-003 (parent: path escape / reparse / dangling evidence)
# ---------------------------------------------------------------------------
function Test-AMT003 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    # junction fixture (d): <F>\outside_dir\evidence.md, junction <F>\workspace\sub -> outside_dir
    $od = Join-Path $Root 'outside_dir'
    [System.IO.Directory]::CreateDirectory($od) | Out-Null
    Write-FileUtf8 -Path (Join-Path $od 'evidence.md') -Text 'OUTSIDE EVIDENCE for AM-T-003(d)'
    $nul = New-Object -ComObject WScript.Shell
    $null = $nul.CreateShortcut('JAMT003.lnk') | Out-Null
    # create junction via cmd mklink /J (reliable on Windows)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = ('/c mklink /J "{0}" "{1}"' -f (Join-Path $a.ws 'sub'), $od)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $jp = New-Object System.Diagnostics.Process; $jp.StartInfo = $psi; $null = $jp.Start(); $null = $jp.WaitForExit(10000)
    if (-not (Test-Path -LiteralPath (Join-Path $a.ws 'sub'))) { Set-CaseFailure -Id $id @('junction creation failed'); return }
    $variants = @(
        @{ ev = '<F>WSREL..outside.md' },
        @{ ev = 'C:\abs\evidence.md' },
        @{ ev = 'D:\other\evidence.md' },
        @{ ev = 'sub\evidence.md' },
        @{ ev = 'missing\file.md' }
    )
    $variants[0]['ev'] = ('workspace\..\outside.md')
    for ($i = 0; $i -lt $variants.Count; $i++) {
        $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence $variants[$i]['ev'] -Pin $null -Supersedes $null
        $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
        $sp = Write-SpecFile -Root $Root -Name ('draft_bam_spec_e' + $i + '.json') -SpecObj $spec
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
        $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
        if ($f.Count -gt 0) { Set-CaseFailure -Id $id @(('variant ' + [char](97 + $i) + ': ' + ($f -join ' | '))) }
        $d = @(Compare-Manifests -Before $m0 -After (Get-Manifest -Root $a.mem))
        if ($d.Count -gt 0) { Set-CaseFailure -Id $id @(('variant ' + [char](97 + $i) + ' state change: ' + ($d -join ' | '))) }
    }
    # (f) positive control: USER_STATED, evidence omitted
    $opf = New-AddOp -Subject 'self stated' -Summary 'self sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $specf = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($opf)
    $res = Commit-ExpectPass -Id $id -Root $Root -SpecObj $specf -ExpGen 2 -ExpRecords @('mem_0001')
    if (-not $res.ok) { return }
    $line = Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0001'
    $fl = Get-RecordLineFields -Line $line
    if ($null -eq $fl) { Set-CaseFailure -Id $id @('(f) record line unparseable') }
    else {
        if ($fl[5] -cne '-') { Set-CaseFailure -Id $id @('(f) source_pointer != -') }
        if ($fl[6] -cne '-') { Set-CaseFailure -Id $id @('(f) note_pointer != -') }
    }
    # Group D/H frozen row mapping (04 tables) for this parent case:
    #   003.a (evidence <F>\workspace\..\outside.md) + 003.d (.. resolving outside
    #   workspace root) = variant 'workspace\..\outside.md' (resolves to <F>\outside.md)
    #   003.c absolute C:\ = variant 'C:\abs\evidence.md'
    #   003.e different drive = variant 'D:\other\evidence.md'
    #   003.b junction path + 003.f every existing component reparse-checked =
    #   variant 'sub\evidence.md' (junction dir in the middle of the path)
    #   variant 'missing\file.md' = parent own missing-evidence positive rejection
    # Frozen row 003.g (TOCTOU residual, documentation-only per 04 table): the
    # check-then-use replacement race is an ACCEPTED RESIDUAL RISK under the
    # single-user local PC assumption (AM-C-001). It is recorded here by the
    # selftest suite (this note + 06 report) and is NOT silently ignored; the
    # component reparse checking it relies on is mechanically proven by 003.f
    # (variant 'sub\evidence.md' above). No tool invocation is defined for 003.g.
    $residualNote = 'ACCEPTED_RESIDUAL_TOCTOU_SINGLE_USER_LOCAL_PC_AM-C-001_PROVEN_BY_003f'
    if ($residualNote -notmatch 'ACCEPTED_RESIDUAL_TOCTOU') { Set-CaseFailure -Id $id @('003.g accepted-residual note not recorded') }
}

# ---------------------------------------------------------------------------
# Case: AM-T-004 (parent: malformed encoding)
# ---------------------------------------------------------------------------
function Test-AMT004 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-004'
    # (a) spec with BOM prefix (otherwise valid initialize spec)
    $opIdA = New-Uuid
    $specObjA = New-InitializeSpec -OpId $opIdA -Expected (New-EmptyExpected)
    $jsonA = $script:Utf8NoBom.GetBytes(($specObjA | ConvertTo-Json -Depth 12 -Compress))
    $bomA = New-Object byte[] ($jsonA.Length + 3)
    $bomA[0] = 0xEF; $bomA[1] = 0xBB; $bomA[2] = 0xBF
    [Array]::Copy($jsonA, 0, $bomA, 3, $jsonA.Length)
    $spA = Write-SpecRawBytes -Root $Root -Name 'draft_bam_spec_bom.json' -Bytes $bomA
    $ra = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spA.path) })
    $fa = @(Check-JsonContract -R $ra -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fa.Count -gt 0) { Set-CaseFailure -Id $id @('(a) ' + ($fa -join ' | ')) }
    $da = @(Compare-Manifests -Before (Get-Manifest -Root $a.mem) -After (Get-Manifest -Root $a.mem))
    # fresh root must still be empty
    $filesA = @(Get-ChildItem -LiteralPath $a.mem -Recurse -File -Force)
    if ($filesA.Count -ne 0) { Set-CaseFailure -Id $id @('(a) memory root not empty after rejected BOM spec') }
    # (b) invalid UTF-8 bytes mid-text in an add spec (on a gen1 base)
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init for (b) failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op = New-AddOp -Subject 'enc subj' -Summary 'enc sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $specB = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $jsonB = $script:Utf8NoBom.GetBytes(($specB | ConvertTo-Json -Depth 12 -Compress))
    $badB = New-Object byte[] ($jsonB.Length + 2)
    [Array]::Copy($jsonB, 0, $badB, 0, 5)
    $badB[5] = 0xFF; $badB[6] = 0xFE
    [Array]::Copy($jsonB, 5, $badB, 7, ($jsonB.Length - 5))
    $spB = Write-SpecRawBytes -Root $Root -Name 'draft_bam_spec_badutf.json' -Bytes $badB
    $rb = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spB.path) })
    $fb = @(Check-JsonContract -R $rb -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fb.Count -gt 0) { Set-CaseFailure -Id $id @('(b) ' + ($fb -join ' | ')) }
    $mB0 = Get-Manifest -Root $a.mem
    $d = @(Compare-Manifests -Before $mB0 -After (Get-Manifest -Root $a.mem))
    # (c)(d) post-commit corruption of canonical files
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'enc base' -Summary 'enc base sum' -Provenance 'USER_STATED' -Note 'ENC NOTE BASE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    # (c) invalid UTF-8 byte into core.md (insert at a position always < core.md length)
    $cp = Join-Path $gen2 'core.md'
    $cb = Read-FileBytes -Path $cp
    $cb2 = New-Object byte[] ($cb.Length + 1)
    $insPos = [Math]::Min(1, $cb.Length - 1); if ($insPos -lt 0) { $insPos = 0 }
    [Array]::Copy($cb, 0, $cb2, 0, $insPos)
    $cb2[$insPos] = 0xFF
    [Array]::Copy($cb, $insPos, $cb2, ($insPos + 1), ($cb.Length - $insPos))
    Write-FileBytes -Path $cp -Bytes $cb2
    $rc = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fc = @(Check-JsonContract -R $rc -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fc.Count -gt 0) { Set-CaseFailure -Id $id @('(c) ' + ($fc -join ' | ')) }
    # restore core.md, then (d) BOM prepend to index.md
    $cbOrig = Read-FileBytes -Path (Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 1) 'core.md')
    # rebuild gen2 core from gen1 (header-only) - gen2 core is header-only for this fixture
    Write-FileUtf8 -Path $cp -Text ('# memory-core v1' + "`n")
    $ip = Join-Path $gen2 'index.md'
    $ib = Read-FileBytes -Path $ip
    $ib2 = New-Object byte[] ($ib.Length + 3)
    $ib2[0] = 0xEF; $ib2[1] = 0xBB; $ib2[2] = 0xBF
    [Array]::Copy($ib, 0, $ib2, 3, $ib.Length)
    Write-FileBytes -Path $ip -Bytes $ib2
    $rd = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fd = @(Check-JsonContract -R $rd -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fd.Count -gt 0) { Set-CaseFailure -Id $id @('(d) ' + ($fd -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Case: AM-T-005 (parent: note + index reference as one consistent transition)
# ---------------------------------------------------------------------------
function Test-AMT005 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005'
    $evDir = Join-Path $a.ws 'evidence'
    [System.IO.Directory]::CreateDirectory($evDir) | Out-Null
    $evText = 'DETERMINISTIC EVIDENCE FACT 1 for BAM fixture'
    Write-FileUtf8 -Path (Join-Path $evDir 'fact1.md') -Text $evText
    $N1 = 'NOTE BODY alpha deterministic content N1'
    $N2 = 'NOTE BODY beta deterministic content N2'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    # spec B: MACHINE_VERIFIED add with note + evidence, pin=false
    $opB = New-AddOp -Subject 'alpha fact' -Summary 'S1 deterministic summary alpha' -Provenance 'MACHINE_VERIFIED' -Tags @('alpha') -Note $N1 -Evidence 'evidence/fact1.md' -Pin $false -Supersedes $null
    $resB = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($opB)) -ExpGen 2 -ExpRecords @('mem_0001')
    if (-not $resB.ok) { return }
    # gen2 assertions
    $line2 = Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0001'
    $fl = Get-RecordLineFields -Line $line2
    if ($null -eq $fl) { Set-CaseFailure -Id $id @('gen2 index line unparseable') }
    else {
        if ($fl[0] -cne 'mem_0001') { Set-CaseFailure -Id $id @('gen2 id mismatch') }
        if ($fl[5] -cne 'evidence/fact1.md') { Set-CaseFailure -Id $id @('gen2 source_pointer wrong: ' + $fl[5]) }
        if ($fl[6] -cne 'notes/mem_0001.md') { Set-CaseFailure -Id $id @('gen2 note_pointer wrong') }
        if ($fl[7] -cne 'active') { Set-CaseFailure -Id $id @('gen2 lifecycle != active') }
    }
    $nb = Get-GenNoteBytes -MemRoot $a.mem -Gen 2 -Id 'mem_0001'
    if ($null -eq $nb) { Set-CaseFailure -Id $id @('gen2 note missing') }
    elseif ((Get-Sha256Hex -Bytes $nb) -cne (Get-TextSha256Hex -Text $N1)) { Set-CaseFailure -Id $id @('gen2 note bytes != N1') }
    $state2 = Get-StateTextOf -MemRoot $a.mem -Gen 2
    if ($state2 -notmatch 'NOTE_SHA256=mem_0001:') { Set-CaseFailure -Id $id @('gen2 STATE missing NOTE_SHA256 mem_0001') }
    $core2 = [System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 2) 'core.md'), $script:Utf8NoBom)
    if ($core2 -cne ('# memory-core v1' + "`n")) { Set-CaseFailure -Id $id @('gen2 core not header-only') }
    # spec C: USER_STATED add with note, pin=true
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opC = New-AddOp -Subject 'beta fact' -Summary 'S2 deterministic summary beta' -Provenance 'USER_STATED' -Tags @('beta') -Note $N2 -Evidence $null -Pin $true -Supersedes $null
    $resC = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops @($opC)) -ExpGen 3 -ExpRecords @('mem_0002')
    if (-not $resC.ok) { return }
    # gen3 assertions: mem_0002 in index (active) AND core (pinned), field-identical except lifecycle
    $idxP = Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 3) 'index.md'
    $lineIdx = ''
    foreach ($lnI in @(([System.IO.File]::ReadAllText($idxP, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })) {
        if ($lnI.StartsWith('mem_0002|')) { $lineIdx = $lnI }
    }
    $lineCore = ''
    $coreP = Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 3) 'core.md'
    foreach ($ln in @(([System.IO.File]::ReadAllText($coreP, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })) {
        if ($ln.StartsWith('mem_0002|')) { $lineCore = $ln }
    }
    if ($lineIdx -eq '' -or $lineCore -eq '') { Set-CaseFailure -Id $id @('gen3 mem_0002 missing from index or core') }
    else {
        $fi = @($lineIdx -split '\|'); $fc2 = @($lineCore -split '\|')
        if ($fi[7] -cne 'active') { Set-CaseFailure -Id $id @('gen3 index lifecycle != active') }
        if ($fc2[7] -cne 'pinned') { Set-CaseFailure -Id $id @('gen3 core lifecycle != pinned') }
        for ($k = 0; $k -lt 10; $k++) {
            if ($k -eq 7) { continue }
            if ($fi[$k] -cne $fc2[$k]) { Set-CaseFailure -Id $id @(('gen3 field ' + $k + ' differs between core and index')) }
        }
    }
    $nb2 = Get-GenNoteBytes -MemRoot $a.mem -Gen 3 -Id 'mem_0002'
    if ($null -eq $nb2 -or (Get-Sha256Hex -Bytes $nb2) -cne (Get-TextSha256Hex -Text $N2)) { Set-CaseFailure -Id $id @('gen3 note bytes != N2') }
    # Recall alpha -> HIT exactly one candidate mem_0001
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rr.j) { Set-CaseFailure -Id $id @('recall no json'); return }
    $cands = @($rr.j.candidates)
    if ($cands.Count -ne 1) { Set-CaseFailure -Id $id @('candidate count != 1'); return }
    if ([string]$cands[0].record_id -cne 'mem_0001') { Set-CaseFailure -Id $id @('candidate is not mem_0001') }
    if ([string]$cands[0].evidence_status -cne 'ok') { Set-CaseFailure -Id $id @('evidence_status != ok') }
    if ([string]$cands[0].note_pointer -cne 'notes/mem_0001.md') { Set-CaseFailure -Id $id @('note_pointer wrong') }
    if ([string]$cands[0].source_pointer -cne 'evidence/fact1.md') { Set-CaseFailure -Id $id @('source_pointer wrong') }
    # Group D frozen sub-case rows 005.b-g (row 005.a is covered by the recall
    # assertion above: MACHINE_VERIFIED add with evidence present -> evidence_status=ok)
    $stNow = Get-ActiveStateHashes -MemRoot $a.mem
    # 005.b: MACHINE_VERIFIED add with missing evidence file -> INVALID, no state change
    $mD = Get-Manifest -Root $a.mem
    $opD = New-AddOp -Subject 'mv missing ev' -Summary 'mv missing ev sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'evidence/absent-file.md' -Pin $null -Supersedes $null
    $rDb = Commit-ExpectInvalid -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive) -Ops @($opD)) -DiagContains @()
    Assert-ManifestUnchanged -Id $id -Before $mD -After (Get-Manifest -Root $a.mem)
    # 005.c: forget mem_0001, then restore with evidence present -> PASS then PASS
    # O60: forget/restore are spec-driven tool modes, not Commit ops (mode helpers)
    $resD1 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stNow.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive))
    if (-not $resD1.ok) { return }
    $stD1 = Get-ActiveStateHashes -MemRoot $a.mem
    $resD2 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Restore' -ExpGen ($stD1.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stD1.gen -Core $stD1.core -Index $stD1.index -Archive $stD1.archive))
    if (-not $resD2.ok) { return }
    # O60b: after forget the record exists only in archive.md of the forget gen
    $lineD = ''
    foreach ($lnD in @(Get-ArchiveLines -MemRoot $a.mem -Gen $stD1.gen)) {
        $pD = @($lnD -split '\|', 3)
        if ($pD.Count -eq 3 -and $pD[2].StartsWith('mem_0001|')) { $lineD = $pD[2]; break }
    }
    if ($lineD -eq '') { Set-CaseFailure -Id $id @('005.c forgotten line not found in archive'); return }
    $lineD2 = Get-RecordLineOf -MemRoot $a.mem -Gen ($stD1.gen + 1) -Id 'mem_0001'
    $fd1 = Get-RecordLineFields -Line $lineD
    $fd2 = Get-RecordLineFields -Line $lineD2
    if ($null -eq $fd1 -or $null -eq $fd2) { Set-CaseFailure -Id $id @('005.c record line unparseable') }
    else {
        if ($fd1[0] -cne $fd2[0] -or $fd1[1] -cne $fd2[1]) { Set-CaseFailure -Id $id @('005.c identity changed on restore') }
    }
    $nbD = Get-GenNoteBytes -MemRoot $a.mem -Gen ($stD1.gen + 1) -Id 'mem_0001'
    if ($null -eq $nbD -or (Get-Sha256Hex -Bytes $nbD) -cne (Get-TextSha256Hex -Text $N1)) { Set-CaseFailure -Id $id @('005.c note not intact after restore') }
    $rrD = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rrD.j) { Set-CaseFailure -Id $id @('005.c recall no json'); return }
    $cD = @($rrD.j.candidates)
    if ($cD.Count -ne 1 -or [string]$cD[0].record_id -cne 'mem_0001') { Set-CaseFailure -Id $id @('005.c recall candidate set wrong') }
    if ([string]$cD[0].evidence_status -cne 'ok') { Set-CaseFailure -Id $id @('005.c evidence_status != ok') }
    # 005.d: forget mem_0002 (USER_STATED), delete its evidence file, restore -> INVALID restore_source_missing
    # (mem_0001 keeps its evidence; mem_0002 is USER_STATED with source='-', so use mem_0001
    #  for the source-missing variant: forget mem_0001, delete its evidence, restore it)
    $stD2 = Get-ActiveStateHashes -MemRoot $a.mem
    $resD3 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stD2.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stD2.gen -Core $stD2.core -Index $stD2.index -Archive $stD2.archive))
    if (-not $resD3.ok) { return }
    [System.IO.File]::Delete((Join-Path $evDir 'fact1.md'))
    $stD3 = Get-ActiveStateHashes -MemRoot $a.mem
    $mD3 = Get-Manifest -Root $a.mem
    $null = ForgetRestore-ExpectInvalid -Id $id -Root $Root -Mode 'Restore' -DiagContains @('restore_source_missing') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stD3.gen -Core $stD3.core -Index $stD3.index -Archive $stD3.archive))
    Assert-ManifestUnchanged -Id $id -Before $mD3 -After (Get-Manifest -Root $a.mem)
    # 005.e: committed MACHINE_VERIFIED record whose evidence disappears after activation -> dangling
    # (re-create evidence under a second file for a fresh MV record, commit, then delete it)
    Write-FileUtf8 -Path (Join-Path $evDir 'fact2.md') -Text 'DETERMINISTIC EVIDENCE FACT 2'
    $stD4 = Get-ActiveStateHashes -MemRoot $a.mem
    $resD4 = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stD4.gen -Core $stD4.core -Index $stD4.index -Archive $stD4.archive) -Ops @(New-AddOp -Subject 'gamma fact' -Summary 'S3 deterministic summary gamma' -Provenance 'MACHINE_VERIFIED' -Tags @('gamma') -Note 'NOTE BODY gamma deterministic content N3' -Evidence 'evidence/fact2.md' -Pin $false -Supersedes $null)) -ExpGen ($stD4.gen + 1) -ExpRecords @('mem_0003')
    if (-not $resD4.ok) { return }
    [System.IO.File]::Delete((Join-Path $evDir 'fact2.md'))
    $mD5 = Get-Manifest -Root $a.mem
    $rrE = Invoke-RecallExpect -Id $id -Root $Root -Query 'gamma' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rrE.j) { Set-CaseFailure -Id $id @('005.e recall no json'); return }
    $cE = @($rrE.j.candidates)
    if ($cE.Count -ne 1 -or [string]$cE[0].record_id -cne 'mem_0003') { Set-CaseFailure -Id $id @('005.e recall candidate set wrong') }
    if ([string]$cE[0].evidence_status -cne 'dangling') { Set-CaseFailure -Id $id @('005.e evidence_status != dangling') }
    $diagsE = @($rrE.j.diagnostics)
    if ($diagsE -notcontains 'dangling_evidence') { Set-CaseFailure -Id $id @('005.e diagnostics missing dangling_evidence') }
    Assert-ManifestUnchanged -Id $id -Before $mD5 -After (Get-Manifest -Root $a.mem)
    # 005.f: dangling record moves lifecycle normally; dangling never blocks
    $stD5 = Get-ActiveStateHashes -MemRoot $a.mem
    $resF1 = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-PinSpec -OpId (New-Uuid) -RecordId 'mem_0003' -Expected (New-ExpectedBlock -Generation $stD5.gen -Core $stD5.core -Index $stD5.index -Archive $stD5.archive) -OpType 'pin') -ExpGen ($stD5.gen + 1) -ExpRecords @('mem_0003')
    if (-not $resF1.ok) { return }
    $stF1 = Get-ActiveStateHashes -MemRoot $a.mem
    $resF2 = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-PinSpec -OpId (New-Uuid) -RecordId 'mem_0003' -Expected (New-ExpectedBlock -Generation $stF1.gen -Core $stF1.core -Index $stF1.index -Archive $stF1.archive) -OpType 'unpin') -ExpGen ($stF1.gen + 1) -ExpRecords @('mem_0003')
    if (-not $resF2.ok) { return }
    $stF2 = Get-ActiveStateHashes -MemRoot $a.mem
    $resF3 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stF2.gen + 1) -ExpRecords @('mem_0003') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0003' -Expected (New-ExpectedBlock -Generation $stF2.gen -Core $stF2.core -Index $stF2.index -Archive $stF2.archive))
    if (-not $resF3.ok) { return }
    $stF3 = Get-ActiveStateHashes -MemRoot $a.mem
    $resF4 = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stF3.gen -Core $stF3.core -Index $stF3.index -Archive $stF3.archive) -Ops @(New-AddOp -Subject 'unrelated new' -Summary 'unrelated new sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)) -ExpGen ($stF3.gen + 1) -ExpRecords @('mem_0004')
    if (-not $resF4.ok) { return }
    # 005.g: three records with independently combined pointers in one spec
    Write-FileUtf8 -Path (Join-Path $evDir 'fact3.md') -Text 'DETERMINISTIC EVIDENCE FACT 3'
    $stG = Get-ActiveStateHashes -MemRoot $a.mem
    $opG1 = New-AddOp -Subject 'tri both pointers' -Summary 'tri both pointers sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note 'TRI NOTE BODY one' -Evidence 'evidence/fact3.md' -Pin $null -Supersedes $null
    $opG2 = New-AddOp -Subject 'tri note only' -Summary 'tri note only sum' -Provenance 'USER_STATED' -Tags $null -Note 'TRI NOTE BODY two' -Evidence $null -Pin $null -Supersedes $null
    $opG3 = New-AddOp -Subject 'tri source only' -Summary 'tri source only sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'evidence/fact3.md' -Pin $null -Supersedes $null
    $resG = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stG.gen -Core $stG.core -Index $stG.index -Archive $stG.archive) -Ops @($opG1, $opG2, $opG3)) -ExpGen ($stG.gen + 1) -ExpRecords @('mem_0005', 'mem_0006', 'mem_0007')
    if (-not $resG.ok) { return }
    $genG = Get-GenDirOf -MemRoot $a.mem -Gen ($stG.gen + 1)
    $flG1 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen ($stG.gen + 1) -Id 'mem_0005')
    $flG2 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen ($stG.gen + 1) -Id 'mem_0006')
    $flG3 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen ($stG.gen + 1) -Id 'mem_0007')
    if ($null -eq $flG1 -or $null -eq $flG2 -or $null -eq $flG3) { Set-CaseFailure -Id $id @('005.g record line unparseable'); return }
    if ($flG1[5] -cne 'evidence/fact3.md' -or $flG1[6] -cne 'notes/mem_0005.md') { Set-CaseFailure -Id $id @('005.g record 1 pointers wrong') }
    if ($flG2[5] -cne '-' -or $flG2[6] -cne 'notes/mem_0006.md') { Set-CaseFailure -Id $id @('005.g record 2 pointers wrong') }
    if ($flG3[5] -cne 'evidence/fact3.md' -or $flG3[6] -cne '-') { Set-CaseFailure -Id $id @('005.g record 3 pointers wrong') }
    $stateG = Get-StateTextOf -MemRoot $a.mem -Gen ($stG.gen + 1)
    if ($stateG -notmatch 'NOTE_SHA256=mem_0005:' -or $stateG -notmatch 'NOTE_SHA256=mem_0006:') { Set-CaseFailure -Id $id @('005.g STATE missing note lines for records 1+2') }
    if ($stateG -match 'NOTE_SHA256=mem_0007:') { Set-CaseFailure -Id $id @('005.g STATE lists note for record 3') }
}

# ---------------------------------------------------------------------------
# Case: AM-T-006 (parent: representative fault injection window)
# ---------------------------------------------------------------------------
function Test-AMT006 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fault base' -Summary 'fault base sum' -Provenance 'USER_STATED' -Note 'FAULT NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $cur0 = Read-FileBytes -Path (Join-Path $a.mem 'CURRENT')
    $m0 = Get-Manifest -Root $a.mem
    $opF = New-AddOp -Subject 'fault rec' -Summary 'fault rec sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $specF = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($opF)
    $spF = Write-SpecFile -Root $Root -Name 'draft_bam_spec_fault.json' -SpecObj $specF
    $rf = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spF.path); 'TestMode' = $true; 'FaultAt' = @('FAULT_BEFORE_CURRENT_SWITCH') })
    $ff = @(Check-JsonContract -R $rf -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('staged_verify_failed') -ExpectedExit 1)
    if ($ff.Count -gt 0) { Set-CaseFailure -Id $id @('fault: ' + ($ff -join ' | ')) }
    $act1 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $cur1 = Read-FileBytes -Path (Join-Path $a.mem 'CURRENT')
    if ((Get-Sha256Hex -Bytes $act1) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('ACTIVE changed by fault') }
    if ((Get-Sha256Hex -Bytes $cur1) -cne (Get-Sha256Hex -Bytes $cur0)) { Set-CaseFailure -Id $id @('CURRENT changed by fault') }
    # follow-up plain commit must PASS and clean any remnant
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opG = New-AddOp -Subject 'follow rec' -Summary 'follow rec sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $resG = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops @($opG)) -ExpGen 3 -ExpRecords @('mem_0002')
    if (-not $resG.ok) { return }
    $stA = Get-ActiveStateHashes -MemRoot $a.mem
    if ([int]$stA.gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after follow-up') }
}

# ---------------------------------------------------------------------------
# Case: AM-T-007 (parent: lock contention + stale CAS)
# ---------------------------------------------------------------------------
function Test-AMT007 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'lock base' -Summary 'lock base sum' -Provenance 'USER_STATED' -Note 'LOCK NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op = New-AddOp -Subject 'lock rec' -Summary 'lock rec sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_lock.json' -SpecObj $spec
    # (a) hold the lock for a bounded window, then commit with -LockTimeoutSeconds 1
    $lockPath = Join-Path $a.mem '.lock'
    $holder = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path); 'LockTimeoutSeconds' = @('1') })
    $holder.Dispose()
    $f1 = @(Check-JsonContract -R $r1 -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('writer_active') -ExpectedExit 1)
    if ($f1.Count -gt 0) { Set-CaseFailure -Id $id @('(a) ' + ($f1 -join ' | ')) }
    $d = @(Compare-Manifests -Before $m0 -After (Get-Manifest -Root $a.mem))
    if ($d.Count -gt 0) { Set-CaseFailure -Id $id @('(a) state change: ' + ($d -join ' | ')) }
    # (b) stale expected.generation = current-1 with stale content hashes
    $staleSpec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core '0000000000000000000000000000000000000000000000000000000000000000' -Index '0000000000000000000000000000000000000000000000000000000000000000' -Archive '0000000000000000000000000000000000000000000000000000000000000000') -Ops @($op)
    $sp2 = Write-SpecFile -Root $Root -Name 'draft_bam_spec_stale.json' -SpecObj $staleSpec
    $r2 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp2.path) })
    $f2 = @(Check-JsonContract -R $r2 -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('cas_mismatch') -ExpectedExit 1)
    if ($f2.Count -gt 0) { Set-CaseFailure -Id $id @('(b) ' + ($f2 -join ' | ')) }
    $d2 = @(Compare-Manifests -Before $m0 -After (Get-Manifest -Root $a.mem))
    if ($d2.Count -gt 0) { Set-CaseFailure -Id $id @('(b) state change: ' + ($d2 -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Case: AM-T-008 (parent: two records share a tag)
# ---------------------------------------------------------------------------
function Test-AMT008 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-008'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $ops = @(
        (New-AddOp -Subject 'tag share one' -Summary 'S1 share' -Provenance 'USER_STATED' -Tags @('shared-tag') -Note $null -Evidence $null -Pin $null -Supersedes $null),
        (New-AddOp -Subject 'tag share two' -Summary 'S2 share' -Provenance 'USER_STATED' -Tags @('shared-tag') -Note $null -Evidence $null -Pin $null -Supersedes $null)
    )
    $res = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops $ops) -ExpGen 2 -ExpRecords @('mem_0001', 'mem_0002')
    if (-not $res.ok) { return }
    $idx = Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 2) 'index.md'
    $lines = @(([System.IO.File]::ReadAllText($idx, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($lines.Count -ne 2) { Set-CaseFailure -Id $id @('index record line count != 2') }
    foreach ($ln in $lines) {
        $fl = Get-RecordLineFields -Line $ln
        if ($null -eq $fl) { Set-CaseFailure -Id $id @('index line unparseable'); continue }
        if ($fl[3] -cne 'shared-tag') { Set-CaseFailure -Id $id @('tag field wrong: ' + $fl[3]) }
        if ($fl[7] -cne 'active') { Set-CaseFailure -Id $id @('lifecycle != active') }
    }
    $coreT = [System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 2) 'core.md'), $script:Utf8NoBom)
    if ($coreT -cne ('# memory-core v1' + "`n")) { Set-CaseFailure -Id $id @('core not header-only') }
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'shared-tag' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rr.j) { Set-CaseFailure -Id $id @('recall no json'); return }
    Assert-Candidates -Id $id -J $rr.j -ExpectedIds @('mem_0001', 'mem_0002')
}

# ---------------------------------------------------------------------------
# Case: AM-T-009 (parent: supersede only the explicitly named record)
# ---------------------------------------------------------------------------
function Test-AMT009 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-009'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $ops = @(
        (New-AddOp -Subject 'topic one' -Summary 'S1 topic' -Provenance 'USER_STATED' -Tags @('topic') -Note $null -Evidence $null -Pin $null -Supersedes $null),
        (New-AddOp -Subject 'topic two' -Summary 'S2 topic' -Provenance 'USER_STATED' -Tags @('topic') -Note $null -Evidence $null -Pin $null -Supersedes $null)
    )
    $res = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops $ops) -ExpGen 2 -ExpRecords @('mem_0001', 'mem_0002')
    if (-not $res.ok) { return }
    $lineOld = Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0001'
    $m0 = Get-Manifest -Root $a.mem
    # (1) spec F: supersedes=mem_0099 (nonexistent) -> INVALID
    $stF = Get-ActiveStateHashes -MemRoot $a.mem
    $opF = New-AddOp -Subject 'bad target' -Summary 'S3 bad' -Provenance 'USER_STATED' -Tags @('topic') -Note $null -Evidence $null -Pin $null -Supersedes 'mem_0099'
    Commit-ExpectInvalid -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stF.gen -Core $stF.core -Index $stF.index -Archive $stF.archive) -Ops @($opF)) -DiagContains @() | Out-Null
    $d = @(Compare-Manifests -Before $m0 -After (Get-Manifest -Root $a.mem))
    if ($d.Count -gt 0) { Set-CaseFailure -Id $id @('step1 state change: ' + ($d -join ' | ')) }
    # (2) spec E: supersedes=mem_0001 -> PASS mem_0003 gen3
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opE = New-AddOp -Subject 'topic corrected' -Summary 'S3 corrected' -Provenance 'USER_STATED' -Tags @('topic') -Note $null -Evidence $null -Pin $null -Supersedes 'mem_0001'
    $resE = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops @($opE)) -ExpGen 3 -ExpRecords @('mem_0003', 'mem_0001')
    if (-not $resE.ok) { return }
    # gen3 assertions
    $l3 = Get-RecordLineOf -MemRoot $a.mem -Gen 3 -Id 'mem_0003'
    $fl3 = Get-RecordLineFields -Line $l3
    if ($null -eq $fl3) { Set-CaseFailure -Id $id @('gen3 mem_0003 line unparseable') }
    elseif ($fl3[8] -cne 'mem_0001') { Set-CaseFailure -Id $id @('mem_0003 supersedes_id wrong: ' + $fl3[8]) }
    if (Get-RecordLineOf -MemRoot $a.mem -Gen 3 -Id 'mem_0001' -ne '') { Set-CaseFailure -Id $id @('mem_0001 still in gen3 corpus') }
    $alines = @(Get-ArchiveLines -MemRoot $a.mem -Gen 3)
    if ($alines.Count -ne 1) { Set-CaseFailure -Id $id @('gen3 archive line count != 1') }
    else {
        $af = @($alines[0] -split '\|')
        if ($af.Count -ne 12) { Set-CaseFailure -Id $id @('archive line field count != 12') }
        elseif ($af[1] -cne 'superseded') { Set-CaseFailure -Id $id @('archive reason != superseded') }
        elseif ((($af[2..11]) -join '|') -cne $lineOld) { Set-CaseFailure -Id $id @('archive original line not byte-identical') }
    }
    # (3) recall topic -> includes mem_0002+mem_0003, excludes mem_0001
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'topic' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rr.j) { Set-CaseFailure -Id $id @('recall no json'); return }
    Assert-Candidates -Id $id -J $rr.j -ExpectedIds @('mem_0002', 'mem_0003')
}

# ---------------------------------------------------------------------------
# Case: AM-T-010 (parent: core record and byte bounds at limit and limit+1)
# ---------------------------------------------------------------------------
function Test-AMT010 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-010'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    # (a) 30 pinned adds, content < 4096 (14 records lenS+lenSumm=84, 16 records =85)
    $opsA = @()
    for ($i = 0; $i -lt 30; $i++) {
        $total = 85
        if ($i -lt 14) { $total = 84 }
        $ls = [math]::Min(40, $total - 1)
        $lsum = $total - $ls
        $opsA += (New-AddOp -Subject (New-String -Len $ls -Ch 'A' -Suffix ($i.ToString('000'))) -Summary (New-String -Len $lsum -Ch 's') -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $true -Supersedes $null)
    }
    $stA = Commit-BoundedMultiSpec -Id $id -Root $Root -Ops $opsA
    if ($null -eq $stA) { return }
    if ($stA.gen -ne 3) { Set-CaseFailure -Id $id @(('(a) final gen ' + $stA.gen + ' != 3')); return }
    $coreBytes = Get-ContentBytesAfterHeader -Path (Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 3) 'core.md')
    if ($coreBytes -ge 4096) { Set-CaseFailure -Id $id @(('(a) core bytes ' + $coreBytes + ' >= 4096')) }
    $coreLines = @(([System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 3) 'core.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($coreLines.Count -ne 30) { Set-CaseFailure -Id $id @('(a) core record lines != 30') }
    # (b) 31st pinned add -> INVALID
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opB = New-AddOp -Subject 'b31' -Summary 'b31 sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $true -Supersedes $null
    $mB = Get-Manifest -Root $a.mem
    $rB = Commit-ExpectInvalid -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops @($opB)) -DiagContains @()
    $dB = @(Compare-Manifests -Before $mB -After (Get-Manifest -Root $a.mem))
    if ($dB.Count -gt 0) { Set-CaseFailure -Id $id @('(b) state change: ' + ($dB -join ' | ')) }
    # (c) unpin mem_0001 then 31st add -> PASS then PASS
    $opU = New-AddOp -Subject 'u' -Summary 'u' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    $unpinSpec = [pscustomobject]@{ operation_id = (New-Uuid); expected = (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive); operations = @([pscustomobject]@{ op = 'unpin'; record_id = 'mem_0001' }) }
    $resU = Commit-ExpectPass -Id $id -Root $Root -SpecObj $unpinSpec -ExpGen ($st2.gen + 1) -ExpRecords @('mem_0001')
    if (-not $resU.ok) { return }
    $coreLines3 = @(([System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen ($st2.gen + 1)) 'core.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($coreLines3.Count -ne 29) { Set-CaseFailure -Id $id @('(c) core lines after unpin != 29') }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $opC = New-AddOp -Subject 'c31' -Summary 'c31 sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $true -Supersedes $null
    $resC = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st3.gen -Core $st3.core -Index $st3.index -Archive $st3.archive) -Ops @($opC)) -ExpGen ($st3.gen + 1) -ExpRecords @('mem_0031')
    if (-not $resC.ok) { return }
    $coreLines4 = @(([System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen ($st3.gen + 1)) 'core.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($coreLines4.Count -ne 30) { Set-CaseFailure -Id $id @('(c) core lines after re-add != 30') }
}

# ---------------------------------------------------------------------------
# Case: AM-T-011 (parent: index bounds + FIFO eviction of oldest eligible)
# ---------------------------------------------------------------------------
function Test-AMT011 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-011'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    # (a) 100 unpinned adds
    $opsA = @()
    for ($i = 0; $i -lt 100; $i++) {
        $opsA += (New-AddOp -Subject ('R' + ($i + 1).ToString('0000')) -Summary ('summary R' + ($i + 1).ToString('0000') + ' deterministic filler body') -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $false -Supersedes $null)
    }
    $stA = Commit-BoundedMultiSpec -Id $id -Root $Root -Ops $opsA
    if ($null -eq $stA) { return }
    if ($stA.gen -ne 8) { Set-CaseFailure -Id $id @(('(a) final gen ' + $stA.gen + ' != 8')); return }
    $idx2 = Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen $stA.gen) 'index.md'
    $idxLines2 = @(([System.IO.File]::ReadAllText($idx2, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($idxLines2.Count -ne 100) { Set-CaseFailure -Id $id @('(a) index lines != 100') }
    $lineR1 = Get-RecordLineOf -MemRoot $a.mem -Gen $stA.gen -Id 'mem_0001'
    # (b) 101st add -> PASS, R0001 evicted
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opB = New-AddOp -Subject 'R0101' -Summary 'summary R0101 deterministic filler body' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $false -Supersedes $null
    $resB = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops @($opB)) -ExpGen ($st2.gen + 1) -ExpRecords @('mem_0101')
    if (-not $resB.ok) { return }
    $idxLines3 = @(([System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen ($st2.gen + 1)) 'index.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($idxLines3.Count -ne 100) { Set-CaseFailure -Id $id @('(b) index lines after 101st != 100') }
    if (Get-RecordLineOf -MemRoot $a.mem -Gen ($st2.gen + 1) -Id 'mem_0001' -ne '') { Set-CaseFailure -Id $id @('(b) mem_0001 still in index') }
    $al3 = @(Get-ArchiveLines -MemRoot $a.mem -Gen ($st2.gen + 1))
    if ($al3.Count -ne 1) { Set-CaseFailure -Id $id @('(b) archive lines != 1') }
    else {
        $af = @($al3[0] -split '\|')
        if ($af.Count -ne 12) { Set-CaseFailure -Id $id @('(b) archive field count != 12') }
        elseif ($af[1] -cne 'evicted') { Set-CaseFailure -Id $id @('(b) archive reason != evicted') }
        elseif ((($af[2..11]) -join '|') -cne $lineR1) { Set-CaseFailure -Id $id @('(b) archived line not byte-identical') }
    }
}

# ---------------------------------------------------------------------------
# Case: AM-T-012 (parent: forget / recall exclusion / restore by id)
# ---------------------------------------------------------------------------
function Test-AMT012 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-012'
    $evDir = Join-Path $a.ws 'evidence'
    [System.IO.Directory]::CreateDirectory($evDir) | Out-Null
    Write-FileUtf8 -Path (Join-Path $evDir 'fact12.md') -Text 'DETERMINISTIC EVIDENCE FACT 12'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'unique-mem0001-term record' -Summary 'unique summary 12' -Provenance 'MACHINE_VERIFIED' -Note 'NOTE 12 BODY' -Evidence 'evidence/fact12.md'
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $lineOriginal = Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0001'
    # (1) forget
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $res1 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen 3 -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 2 -Core $st.core -Index $st.index -Archive $st.archive))
    if (-not $res1.ok) { return }
    $j1 = Parse-JsonLine -Line $res1.r.stdout_lines[0]
    if ([string]$j1.operation -cne 'forget') { Set-CaseFailure -Id $id @('(1) operation != forget') }
    $al3 = @(Get-ArchiveLines -MemRoot $a.mem -Gen 3)
    if ($al3.Count -ne 1) { Set-CaseFailure -Id $id @('(1) archive lines != 1') }
    else {
        $af = @($al3[0] -split '\|')
        if ($af[1] -cne 'forgotten') { Set-CaseFailure -Id $id @('(1) reason != forgotten') }
        if ((($af[2..11]) -join '|') -cne $lineOriginal) { Set-CaseFailure -Id $id @('(1) archived line not byte-identical') }
    }
    # (2) recall -> MISS
    Invoke-RecallExpect -Id $id -Root $Root -Query 'unique-mem0001-term' -ExpStatus 'MISS' -ExpMax 0 | Out-Null
    # (3) restore
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $res3 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Restore' -ExpGen 4 -ExpRecords @('mem_0001') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 3 -Core $st3.core -Index $st3.index -Archive $st3.archive))
    if (-not $res3.ok) { return }
    $j3 = Parse-JsonLine -Line $res3.r.stdout_lines[0]
    if ([string]$j3.operation -cne 'restore') { Set-CaseFailure -Id $id @('(3) operation != restore') }
    $lineRestored = Get-RecordLineOf -MemRoot $a.mem -Gen 4 -Id 'mem_0001'
    if ($lineRestored -eq '') { Set-CaseFailure -Id $id @('(3) mem_0001 not restored to index') }
    else {
        $fo = @($lineOriginal -split '\|'); $fr = @($lineRestored -split '\|')
        if ($fo[0] -cne $fr[0] -or $fo[1] -cne $fr[1]) { Set-CaseFailure -Id $id @('(3) identity (id/recorded_at) changed on restore') }
    }
    $nb4 = Get-GenNoteBytes -MemRoot $a.mem -Gen 4 -Id 'mem_0001'
    if ($null -eq $nb4) { Set-CaseFailure -Id $id @('(3) note missing after restore') }
    $al4 = @(Get-ArchiveLines -MemRoot $a.mem -Gen 4)
    if ($al4.Count -ne 0) { Set-CaseFailure -Id $id @('(3) archive line not removed on restore') }
    # (4)-(7) repeated forget/restore (01 D3.7: restore removes the matching archive line)
    $st4 = Get-ActiveStateHashes -MemRoot $a.mem
    $null = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen 5 -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 4 -Core $st4.core -Index $st4.index -Archive $st4.archive))
    $st5 = Get-ActiveStateHashes -MemRoot $a.mem
    $null = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Restore' -ExpGen 6 -ExpRecords @('mem_0001') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 5 -Core $st5.core -Index $st5.index -Archive $st5.archive))
    $st6 = Get-ActiveStateHashes -MemRoot $a.mem
    $res6 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen 7 -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 6 -Core $st6.core -Index $st6.index -Archive $st6.archive))
    if (-not $res6.ok) { return }
    $al7 = @(Get-ArchiveLines -MemRoot $a.mem -Gen 7)
    if ($al7.Count -ne 1) { Set-CaseFailure -Id $id @('(6) archive lines != 1 after third forget') }
    $st7 = Get-ActiveStateHashes -MemRoot $a.mem
    $res7 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Restore' -ExpGen 8 -ExpRecords @('mem_0001') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation 7 -Core $st7.core -Index $st7.index -Archive $st7.archive))
    if (-not $res7.ok) { return }
    $al8 = @(Get-ArchiveLines -MemRoot $a.mem -Gen 8)
    if ($al8.Count -ne 0) { Set-CaseFailure -Id $id @('(7) archive lines != 0 after third restore') }
    # (8) recall -> HIT one candidate
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'unique-mem0001-term' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rr.j) { Set-CaseFailure -Id $id @('(8) recall no json'); return }
    Assert-Candidates -Id $id -J $rr.j -ExpectedIds @('mem_0001')
    # (9) restore mem_0099 (not in archive) -> INVALID
    $st8 = Get-ActiveStateHashes -MemRoot $a.mem
    $m9 = Get-Manifest -Root $a.mem
    $null = ForgetRestore-ExpectInvalid -Id $id -Root $Root -Mode 'Restore' -DiagContains @() -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0099' -Expected (New-ExpectedBlock -Generation 8 -Core $st8.core -Index $st8.index -Archive $st8.archive))
    $d9 = @(Compare-Manifests -Before $m9 -After (Get-Manifest -Root $a.mem))
    if ($d9.Count -gt 0) { Set-CaseFailure -Id $id @('(9) state change: ' + ($d9 -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Case: AM-T-013 (parent: bounded lexical recall, read-only)
# C4 (2026-10-12 amendment): 01 D6 substring matching kept. "strategy" is a
# HIT exactly R4 (matched_fields/terms verified non-empty); the MISS step uses
# a token mechanically verified absent from all fixture strings.
# ---------------------------------------------------------------------------
function Test-AMT013 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-013'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $ops = @(
        (New-AddOp -Subject 'alpha one' -Summary 'contains alpha term' -Provenance 'USER_STATED' -Tags @('alpha') -Note $null -Evidence $null -Pin $null -Supersedes $null),
        (New-AddOp -Subject 'alpha two' -Summary 'contains alpha term' -Provenance 'USER_STATED' -Tags @() -Note $null -Evidence $null -Pin $true -Supersedes $null),
        (New-AddOp -Subject 'beta three' -Summary 'unrelated text' -Provenance 'USER_STATED' -Tags @('beta') -Note $null -Evidence $null -Pin $null -Supersedes $null),
        (New-AddOp -Subject 'strategy four' -Summary 'chess strategy notes' -Provenance 'USER_STATED' -Tags @() -Note $null -Evidence $null -Pin $null -Supersedes $null)
    )
    $res = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops $ops) -ExpGen 2 -ExpRecords @('mem_0001', 'mem_0002', 'mem_0003', 'mem_0004')
    if (-not $res.ok) { return }
    $m0 = Get-Manifest -Root $a.mem
    # (1) Recall "alpha" -> HIT exactly R2+R1 (R2 once, deduped)
    $r1 = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $r1.j) { Set-CaseFailure -Id $id @('(1) recall no json'); return }
    $c1 = @($r1.j.candidates)
    if ($c1.Count -ne 2) { Set-CaseFailure -Id $id @('(1) candidate count != 2') }
    else {
        $ids1 = @($c1 | ForEach-Object { [string]$_.record_id })
        if (-not (($ids1 -contains 'mem_0001') -and ($ids1 -contains 'mem_0002'))) { Set-CaseFailure -Id $id @('(1) candidate set wrong: ' + ($ids1 -join ',')) }
        # ordering: score desc, recorded_at desc, memory_id asc; both score 3, same date -> id asc
        if ($ids1[0] -cne 'mem_0001' -or $ids1[1] -cne 'mem_0002') { Set-CaseFailure -Id $id @('(1) candidate order wrong: ' + ($ids1 -join ',')) }
        foreach ($c in $c1) {
            foreach ($k in @('record_id', 'recorded_at', 'subject', 'tags', 'provenance', 'source_pointer', 'note_pointer', 'evidence_status', 'matched_fields', 'matched_terms', 'score')) {
                if (-not ($c.PSObject.Properties.Name -contains $k)) { Set-CaseFailure -Id $id @('(1) candidate missing field ' + $k) }
            }
        }
    }
    # (2) Recall "strategy" -> HIT exactly R4 (01 D6 substring matching)
    $r2 = Invoke-RecallExpect -Id $id -Root $Root -Query 'strategy' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $r2.j) { Set-CaseFailure -Id $id @('(2) recall no json'); return }
    $c2 = @($r2.j.candidates)
    if ($c2.Count -ne 1) { Set-CaseFailure -Id $id @('(2) candidate count != 1') }
    else {
        if ([string]$c2[0].record_id -cne 'mem_0004') { Set-CaseFailure -Id $id @('(2) candidate not mem_0004: ' + [string]$c2[0].record_id) }
        $mf2 = @($c2[0].matched_fields)
        $mt2 = @($c2[0].matched_terms)
        if ($mf2.Count -eq 0) { Set-CaseFailure -Id $id @('(2) matched_fields empty') }
        if ($mt2.Count -eq 0) { Set-CaseFailure -Id $id @('(2) matched_terms empty') }
    }
    # (3) Recall absent token -> MISS (token verified absent from all fixture strings)
    $absent = 'zzznope027'
    foreach ($s in @('alpha one', 'contains alpha term', 'alpha two', 'contains alpha term', 'beta three', 'unrelated text', 'strategy four', 'chess strategy notes', 'alpha', 'beta')) {
        if ($s.IndexOf($absent, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Set-CaseFailure -Id $id @('(3) absent token unexpectedly present in fixture string'); return }
    }
    $r3m = Invoke-RecallExpect -Id $id -Root $Root -Query $absent -ExpStatus 'MISS' -ExpMax 0
    if ($null -ne $r3m.j) {
        $c3m = @($r3m.j.candidates)
        if ($c3m.Count -ne 0) { Set-CaseFailure -Id $id @('(3) MISS must have zero candidates') }
    }
    # (4) Recall "alpha,term" -> HIT bounded set {R1, R2}
    $r4 = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha,term' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $r4.j) { Set-CaseFailure -Id $id @('(4) recall no json'); return }
    Assert-Candidates -Id $id -J $r4.j -ExpectedIds @('mem_0001', 'mem_0002')
    # (5) manifest byte-identical
    $m1 = Get-Manifest -Root $a.mem
    $d = @(Compare-Manifests -Before $m0 -After $m1)
    if ($d.Count -gt 0) { Set-CaseFailure -Id $id @('state change: ' + ($d -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Case: AM-T-044 (C5 amendment: 01 D3.4 operation bound 1..16)
# 16 ops accept; 17 ops and 0 ops reject with SPEC_OP_COUNT and zero state
# change (AM-F-006 spec validation).
# ---------------------------------------------------------------------------
function Test-AMT044 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-044'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $ops16 = @()
    for ($i = 0; $i -lt 16; $i++) {
        $ops16 += (New-AddOp -Subject ('op44a' + ($i).ToString('000')) -Summary 's44' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $true -Supersedes $null)
    }
    $res16 = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st.gen -Core $st.core -Index $st.index -Archive $st.archive) -Ops $ops16) -ExpGen 2 -ExpRecords (1..16 | ForEach-Object { 'mem_{0:0000}' -f $_ })
    if (-not $res16.ok) { return }
    $coreLines = @(([System.IO.File]::ReadAllText((Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 2) 'core.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' -and ($_ -notmatch '^#') })
    if ($coreLines.Count -ne 16) { Set-CaseFailure -Id $id @('(1) gen2 core record lines != 16') }
    # (2) 17 ops -> INVALID + SPEC_OP_COUNT + zero state change
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $ops17 = @()
    for ($i = 0; $i -lt 17; $i++) {
        $ops17 += (New-AddOp -Subject ('op44b' + ($i).ToString('000')) -Summary 's44' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
    }
    $m2 = Get-Manifest -Root $a.mem
    Commit-ExpectInvalid -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive) -Ops $ops17) -DiagContains @('SPEC_OP_COUNT') | Out-Null
    $d2 = @(Compare-Manifests -Before $m2 -After (Get-Manifest -Root $a.mem))
    if ($d2.Count -gt 0) { Set-CaseFailure -Id $id @('(2) state change: ' + ($d2 -join ' | ')) }
    # (3) 0 ops (explicit empty operations array) -> INVALID + SPEC_OP_COUNT + zero state change
    $zeroSpec = [pscustomobject]@{ operation_id = (New-Uuid); expected = (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive); operations = [object[]]@() }
    $m3 = Get-Manifest -Root $a.mem
    Commit-ExpectInvalid -Id $id -Root $Root -SpecObj $zeroSpec -DiagContains @('SPEC_OP_COUNT') | Out-Null
    $d3 = @(Compare-Manifests -Before $m3 -After (Get-Manifest -Root $a.mem))
    if ($d3.Count -gt 0) { Set-CaseFailure -Id $id @('(3) state change: ' + ($d3 -join ' | ')) }
}
# ---------------------------------------------------------------------------
# Group A - Crash / transaction windows (parent AM-T-006): 006.a..006.k
# ---------------------------------------------------------------------------
function New-AddOpX {
    param([string]$Subject, [string]$Summary)
    return (New-AddOp -Subject $Subject -Summary $Summary -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
}

function New-CommitSpecX {
    param([string]$Root, [string]$Name, [int]$Gen, $St, [string]$OpId, $Ops)
    $sp = Write-SpecFile -Root $Root -Name $Name -SpecObj (New-CommitSpec -OpId $OpId -Expected (New-ExpectedBlock -Generation $Gen -Core $St.core -Index $St.index -Archive $St.archive) -Ops $Ops)
    return $sp
}

function Fault-Commit {
    param([string]$Root, $Sp, [string]$Point)
    return (Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($Sp.path); 'TestMode' = $true; 'FaultAt' = @($Point) }))
}

function Retry-Spec {
    param([string]$Root, $Sp)
    return (Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($Sp.path) }))
}

function Test-AMT006A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.a'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fa base' -Summary 'fa base sum' -Provenance 'USER_STATED' -Note 'FA NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $cur0 = Read-FileBytes -Path (Join-Path $a.mem 'CURRENT')
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fa.json' -Gen 2 -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'fa rec' -Summary 'fa rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    $ff = @(Check-JsonContract -R $rf -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('staged_verify_failed') -ExpectedExit 1)
    if ($ff.Count -gt 0) { Set-CaseFailure -Id $id $ff }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE'))) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('ACTIVE changed by fault') }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path (Join-Path $a.mem 'CURRENT'))) -cne (Get-Sha256Hex -Bytes $cur0)) { Set-CaseFailure -Id $id @('CURRENT changed by fault') }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $spG = New-CommitSpecX -Root $Root -Name 'draft_bam_fa_follow.json' -Gen 2 -St $st2 -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'fa follow' -Summary 'fa follow sum')
    $rg = Retry-Spec -Root $Root -Sp $spG
    $fg = @(Check-JsonContract -R $rg -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fg.Count -gt 0) { Set-CaseFailure -Id $id @('follow-up: ' + ($fg -join ' | ')) }
    $jg = Parse-JsonLine -Line $rg.stdout_lines[0]
    $hasClean = $false
    foreach ($d in @($jg.diagnostics)) { if ("$d" -match '^stale_generation_cleaned:[0-9]+$') { $hasClean = $true } }
    if (-not $hasClean) { Set-CaseFailure -Id $id @('follow-up did not clean failed-candidate remnant (no stale_generation_cleaned)') }
    if ([int]$jg.state_id.generation -ne 3) { Set-CaseFailure -Id $id @('follow-up ACTIVE generation != 3') }
}

function Test-AMT006B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.b'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fb base' -Summary 'fb base sum' -Provenance 'USER_STATED' -Note 'FB NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fb.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fb rec' -Summary 'fb rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout (expected silent)') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0 (expected nonzero)') }
    $ri = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fi = @(Check-JsonContract -R $ri -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @('pending_operation:' + $opFid) -ExpectedExit 1)
    if ($fi.Count -gt 0) { Set-CaseFailure -Id $id @('(i) ' + ($fi -join ' | ')) }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE'))) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('(i) ACTIVE changed by read mode') }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $spD = New-CommitSpecX -Root $Root -Name 'draft_bam_fb_diff.json' -Gen 2 -St $st2 -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'fb diff' -Summary 'fb diff sum')
    $rii = Retry-Spec -Root $Root -Sp $spD
    $fii = @(Check-JsonContract -R $rii -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('pending_operation:' + $opFid) -ExpectedExit 1)
    if ($fii.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) ' + ($fii -join ' | ')) }
    $riii = Retry-Spec -Root $Root -Sp $spF
    $fiii = @(Check-JsonContract -R $riii -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('pending_resumed:' + $opFid) -ExpectedExit 0)
    if ($fiii.Count -gt 0) { Set-CaseFailure -Id $id @('(iii) ' + ($fiii -join ' | ')) }
    $stA = Get-ActiveStateHashes -MemRoot $a.mem
    if ([int]$stA.gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after retry') }
}

function Test-AMT006C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fc base' -Summary 'fc base sum' -Provenance 'USER_STATED' -Note 'FC NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fc.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fc rec' -Summary 'fc rec sum')
    $recPath = Join-Path (Join-Path $a.mem 'receipts') ($g2.opId + '.pass')
    if (Test-Path -LiteralPath $recPath) { Set-CaseFailure -Id $id @('prior receipt already present before fault'); return }
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_BEFORE_RECEIPT_ARCHIVE'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout (expected silent)') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0 (expected nonzero)') }
    if (Test-Path -LiteralPath $recPath) { Set-CaseFailure -Id $id @('receipt archived before the fault point') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('pending_resumed:' + $opFid) -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('retry: ' + ($fr -join ' | ')) }
    if (-not (Test-Path -LiteralPath $recPath)) { Set-CaseFailure -Id $id @('receipt not created during retry') }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after retry') }
    $rb = Read-FileBytes -Path $recPath
    $rl = @(([System.IO.File]::ReadAllText($recPath, $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })
    if ($rl.Count -ne 7) { Set-CaseFailure -Id $id @('receipt not 7 lines') }
    if ($rb.Length -gt 1024) { Set-CaseFailure -Id $id @('receipt exceeds 1024 bytes') }
}

function Test-AMT006D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.d'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fd base' -Summary 'fd base sum' -Provenance 'USER_STATED' -Note 'FD NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fd.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fd rec' -Summary 'fd rec sum')
    $recPath = Join-Path (Join-Path $a.mem 'receipts') ($g2.opId + '.pass')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_RECEIPT_ARCHIVE'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout (expected silent)') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0 (expected nonzero)') }
    if (-not (Test-Path -LiteralPath $recPath)) { Set-CaseFailure -Id $id @('receipt not archived at AFTER_RECEIPT_ARCHIVE fault') }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path $recPath)) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('receipt != old ACTIVE bytes at fault') }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE'))) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('ACTIVE changed before retry') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('retry: ' + ($fr -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after retry') }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path $recPath)) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('receipt overwritten by retry (must stay byte-identical)') }
}

function Test-AMT006E {
    param([string]$Root)
    $id = 'AM-T-006.e'
    # state (ii): tool's own ACTIVE_TORN end state (ACTIVE = valid new receipt) -> idempotent_pass_recovered
    $rootB = (Join-Path $Root 'alt2')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $g2b = Build-Gen2Fixture -Root $rootB -Subject 'fe2 base' -Summary 'fe2 base sum' -Provenance 'USER_STATED' -Note 'FE2 NOTE BASE' -Evidence $null
    if ($g2b.r.exit -ne 0) { Set-CaseFailure -Id $id @('state(ii) gen2 build failed'); return }
    $stb = Get-ActiveStateHashes -MemRoot (Join-Path (Join-Path $rootB 'workspace') 'memory')
    $opFidB = New-Uuid
    $spFb = New-CommitSpecX -Root $rootB -Name 'draft_bam_fe2.json' -Gen 2 -St $stb -OpId $opFidB -Ops @(New-AddOpX -Subject 'fe2 rec' -Summary 'fe2 rec sum')
    $rFB = Fault-Commit -Root $rootB -Sp $spFb -Point 'FAULT_ACTIVE_TORN'
    if ($rFB.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('state(ii) fault produced stdout') }
    if ($rFB.exit -eq 0) { Set-CaseFailure -Id $id @('state(ii) fault exit 0') }
    $rrB = Retry-Spec -Root $rootB -Sp $spFb
    $frB = @(Check-JsonContract -R $rrB -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($frB.Count -gt 0) { Set-CaseFailure -Id $id @('state(ii) ' + ($frB -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot (Join-Path (Join-Path $rootB 'workspace') 'memory')).gen -ne 3) { Set-CaseFailure -Id $id @('state(ii) ACTIVE generation != 3') }
    # state (i): runner forces ACTIVE back to valid old receipt -> pending_resumed
    $rootA = (Join-Path $Root 'alt1')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootA 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootA 'scratchpad')) | Out-Null
    $g2a = Build-Gen2Fixture -Root $rootA -Subject 'fe1 base' -Summary 'fe1 base sum' -Provenance 'USER_STATED' -Note 'FE1 NOTE BASE' -Evidence $null
    if ($g2a.r.exit -ne 0) { Set-CaseFailure -Id $id @('state(i) gen2 build failed'); return }
    $sta = Get-ActiveStateHashes -MemRoot (Join-Path (Join-Path $rootA 'workspace') 'memory')
    $actOld = Read-FileBytes -Path (Join-Path (Join-Path (Join-Path $rootA 'workspace') 'memory') 'ACTIVE')
    $opFidA = New-Uuid
    $spFa = New-CommitSpecX -Root $rootA -Name 'draft_bam_fe1.json' -Gen 2 -St $sta -OpId $opFidA -Ops @(New-AddOpX -Subject 'fe1 rec' -Summary 'fe1 rec sum')
    $rFA = Fault-Commit -Root $rootA -Sp $spFa -Point 'FAULT_ACTIVE_TORN'
    if ($rFA.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('state(i) fault produced stdout') }
    if ($rFA.exit -eq 0) { Set-CaseFailure -Id $id @('state(i) fault exit 0') }
    Write-FileBytes -Path (Join-Path (Join-Path (Join-Path $rootA 'workspace') 'memory') 'ACTIVE') -Bytes $actOld
    $rrA = Retry-Spec -Root $rootA -Sp $spFa
    $frA = @(Check-JsonContract -R $rrA -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('pending_resumed:' + $opFidA) -ExpectedExit 0)
    if ($frA.Count -gt 0) { Set-CaseFailure -Id $id @('state(i) ' + ($frA -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot (Join-Path (Join-Path $rootA 'workspace') 'memory')).gen -ne 3) { Set-CaseFailure -Id $id @('state(i) ACTIVE generation != 3') }
}

function Test-AMT006F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.f'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'ff base' -Summary 'ff base sum' -Provenance 'USER_STATED' -Note 'FF NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_ff.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'ff rec' -Summary 'ff rec sum')
    $gen3 = Join-Path (Join-Path $a.mem '.gen') '000003'
    $gen4 = Join-Path (Join-Path $a.mem '.gen') '000004'
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_BEFORE_STDOUT'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout (expected silent)') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0 (expected nonzero)') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('retry: ' + ($fr -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after retry') }
    if (Test-Path -LiteralPath $gen4) { Set-CaseFailure -Id $id @('duplicate generation gen4 created by retry') }
}

function Test-AMT006G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.g'
    # (i) empty root: initialize fault BEFORE_CURRENT_SWITCH -> FAILED, then follow-up init PASS gen1
    $opI1 = New-Uuid
    $spI1 = Write-SpecFile -Root $Root -Name 'draft_bam_fgi1.json' -SpecObj (New-InitializeSpec -OpId $opI1 -Expected (New-EmptyExpected))
    $ri1 = Fault-Commit -Root $Root -Sp $spI1 -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    $fi1 = @(Check-JsonContract -R $ri1 -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('staged_verify_failed') -ExpectedExit 1)
    if ($fi1.Count -gt 0) { Set-CaseFailure -Id $id @('(i) ' + ($fi1 -join ' | ')) }
    if (Test-Path -LiteralPath (Join-Path $a.mem 'ACTIVE')) { Set-CaseFailure -Id $id @('(i) ACTIVE exists before durable first receipt') }
    $opI2 = New-Uuid
    $spI2 = Write-SpecFile -Root $Root -Name 'draft_bam_fgi2.json' -SpecObj (New-InitializeSpec -OpId $opI2 -Expected (New-EmptyExpected))
    $ri2 = Retry-Spec -Root $Root -Sp $spI2
    $fi2 = @(Check-JsonContract -R $ri2 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fi2.Count -gt 0) { Set-CaseFailure -Id $id @('(i) follow-up ' + ($fi2 -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 1) { Set-CaseFailure -Id $id @('(i) ACTIVE generation != 1') }
    # (ii) fresh fixture: initialize fault AFTER_CURRENT_SWITCH -> read modes pending, diff op STALE, retry PASS, AbortPending PASS
    $rootB = (Join-Path $Root 'altg')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $ab = Get-CaseRootArgs -Root $rootB
    $opI3 = New-Uuid
    $spI3 = Write-SpecFile -Root $rootB -Name 'draft_bam_fgi3.json' -SpecObj (New-InitializeSpec -OpId $opI3 -Expected (New-EmptyExpected))
    $ri3 = Fault-Commit -Root $rootB -Sp $spI3 -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($ri3.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('(ii) fault produced stdout') }
    if ($ri3.exit -eq 0) { Set-CaseFailure -Id $id @('(ii) fault exit 0') }
    $rv = Invoke-Tool -Args (Tool-Args -Root $rootB -Mode 'Validate')
    $fv = @(Check-JsonContract -R $rv -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @('pending_operation:' + $opI3) -ExpectedExit 1)
    if ($fv.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) validate ' + ($fv -join ' | ')) }
    $stB = Get-ActiveStateHashes -MemRoot $ab.mem
    $expB = (New-EmptyExpected)
    if ($stB -ne $null) { $expB = (New-ExpectedBlock -Generation $stB.gen -Core $stB.core -Index $stB.index -Archive $stB.archive) }
    $opI4 = New-Uuid
    $spI4 = Write-SpecFile -Root $rootB -Name 'draft_bam_fgi4.json' -SpecObj (New-InitializeSpec -OpId $opI4 -Expected $expB)
    $rd = Retry-Spec -Root $rootB -Sp $spI4
    $fd = @(Check-JsonContract -R $rd -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('pending_operation:' + $opI3) -ExpectedExit 1)
    if ($fd.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) diff op ' + ($fd -join ' | ')) }
    $rr = Retry-Spec -Root $rootB -Sp $spI3
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('pending_resumed:' + $opI3) -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) retry ' + ($fr -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $ab.mem).gen -ne 1) { Set-CaseFailure -Id $id @('(ii) ACTIVE generation != 1 after retry') }
    # AbortPending variant on a fresh pending
    $rootC = (Join-Path $Root 'altg2')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootC 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootC 'scratchpad')) | Out-Null
    $ac = Get-CaseRootArgs -Root $rootC
    $opI5 = New-Uuid
    $spI5 = Write-SpecFile -Root $rootC -Name 'draft_bam_fgi5.json' -SpecObj (New-InitializeSpec -OpId $opI5 -Expected (New-EmptyExpected))
    $ri5 = Fault-Commit -Root $rootC -Sp $spI5 -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($ri5.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('(ii) abort fault produced stdout') }
    if ($ri5.exit -eq 0) { Set-CaseFailure -Id $id @('(ii) abort fault exit 0') }
    $rp = Invoke-Tool -Args (Tool-Args -Root $rootC -Mode 'AbortPending' -Extra @{ 'PendingOperationId' = @($opI5) })
    $fp = @(Check-JsonContract -R $rp -ExpectedStatus 'PASS' -ExpectedOp 'abortpending' -ExpectedRecords @() -ExpectedDiagContains @('pending_aborted:' + $opI5) -ExpectedExit 0)
    if ($fp.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) abort ' + ($fp -join ' | ')) }
    if (Test-Path -LiteralPath (Join-Path $ac.mem 'CURRENT')) { Set-CaseFailure -Id $id @('(ii) CURRENT not removed after abort at A=0') }
    if (Test-Path -LiteralPath (Join-Path $ac.mem 'ACTIVE')) { Set-CaseFailure -Id $id @('(ii) ACTIVE exists after abort at A=0') }
}

function Test-AMT006H {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.h'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fh base' -Summary 'fh base sum' -Provenance 'USER_STATED' -Note 'FH NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fh.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fh rec' -Summary 'fh rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('pending_resumed:' + $opFid) -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id $fr }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3') }
}

function Test-AMT006I {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.i'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fi base' -Summary 'fi base sum' -Provenance 'USER_STATED' -Note 'FI NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fi.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fi rec' -Summary 'fi rec sum')
    $gen4 = Join-Path (Join-Path $a.mem '.gen') '000004'
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_BEFORE_STDOUT'
    if ($rf.stdout_lines.Count -ne 0) { Set-CaseFailure -Id $id @('fault produced stdout') }
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id $fr }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3') }
    if (Test-Path -LiteralPath $gen4) { Set-CaseFailure -Id $id @('duplicate generation gen4 created') }
}

function Test-AMT006J {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.j'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fj base' -Summary 'fj base sum' -Provenance 'USER_STATED' -Note 'FJ NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fj.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fj rec' -Summary 'fj rec sum')
    $rf = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spF.path) })
    $fr0 = @(Check-JsonContract -R $rf -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fr0.Count -gt 0) { Set-CaseFailure -Id $id @('setup commit ' + ($fr0 -join ' | ')); return }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    # corrupt ACTIVE with garbage (neither valid old nor valid new)
    $actPath = Join-Path $a.mem 'ACTIVE'
    Write-FileUtf8 -Path $actPath -Text 'GARBAGE-CORRUPTED-ACTIVE-RECEIPT-NO-VALID-LINE-1' + "`n" + 'GARBAGE-CORRUPTED-ACTIVE-RECEIPT-NO-VALID-LINE-2' + "`n"
    $m0 = Get-Manifest -Root $a.mem
    $rv = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fv = @(Check-JsonContract -R $rv -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @('active_switch_outcome_unknown') -ExpectedExit 1)
    if ($fv.Count -gt 0) { Set-CaseFailure -Id $id @('validate: ' + ($fv -join ' | ')) }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $jr = Parse-JsonLine -Line $rr.stdout_lines[0]
    $stR = [string]$jr.status
    if ($stR -ne 'UNVERIFIED' -and $stR -ne 'BLOCKED') { Set-CaseFailure -Id $id @('retry status ' + $stR + ' not in UNVERIFIED/BLOCKED') }
    if ($rr.exit -ne 1) { Set-CaseFailure -Id $id @('retry exit ' + $rr.exit + ' != 1') }
    $opDiff = New-AddOpX -Subject 'fj diff' -Summary 'fj diff sum'
    $spD = New-CommitSpecX -Root $Root -Name 'draft_bam_fj_diff.json' -Gen 3 -St $st3 -OpId (New-Uuid) -Ops @($opDiff)
    $rd = Retry-Spec -Root $Root -Sp $spD
    $jrd = Parse-JsonLine -Line $rd.stdout_lines[0]
    if ([string]$jrd.status -notin @('UNVERIFIED', 'BLOCKED')) { Set-CaseFailure -Id $id @('different-op status ' + $jrd.status + ' not refused') }
    # no generation deleted; both gen dirs intact; no auto-repair (ACTIVE still corrupted)
    $actAfter = [System.IO.File]::ReadAllText($actPath, $script:Utf8NoBom)
    if ($actAfter -notlike 'GARBAGE-CORRUPTED-ACTIVE*') { Set-CaseFailure -Id $id @('ACTIVE auto-repaired (must not)') }
    foreach ($g in @(2, 3)) { Assert-GenFilesPresent -Id $id -MemRoot $a.mem -Gen $g }
}

function Test-AMT006K {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.k'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fk base' -Summary 'fk base sum' -Provenance 'USER_STATED' -Note 'FK NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $gen3 = Join-Path (Join-Path $a.mem '.gen') '000003'
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_fk.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'fk rec' -Summary 'fk rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_POSTSWITCH_REVALIDATE'
    $ff = @(Check-JsonContract -R $rf -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('postswitch_rollback') -ExpectedExit 1)
    if ($ff.Count -gt 0) { Set-CaseFailure -Id $id $ff }
    if (Test-Path -LiteralPath $gen3) { Set-CaseFailure -Id $id @('staged generation gen3 not removed by rollback') }
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE'))) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('ACTIVE changed by postswitch rollback') }
    Assert-CurrentMatchesActive -Id $id -MemRoot $a.mem
}
# ---------------------------------------------------------------------------
# Independent-measurement + receipt helpers (Groups C/E/I; 028.b / 041.a)
# ---------------------------------------------------------------------------
function Build-ReceiptText {
    param([int]$Generation, [string]$OperationId, [string]$SpecSha, [string]$StateSha, [string]$Action, [string]$AffectedIds)
    return ('GENERATION=' + $Generation + "`n" +
            'OPERATION_ID=' + $OperationId + "`n" +
            'SPEC_SHA256=' + $SpecSha + "`n" +
            'STATE_SHA256=' + $StateSha + "`n" +
            'ACTION=' + $Action + "`n" +
            'AFFECTED_IDS=' + $AffectedIds + "`n" +
            'RESULT=PASS' + "`n")
}

function Get-DirBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force)) { $sum += $f.Length }
    return $sum
}

# Replicates memory-tool.ps1 Get-StatusMetrics EXACTLY for independent comparison.
function Measure-StatusMetricsIndependent {
    param([string]$MemRoot)
    $genA = 0
    if (Test-Path -LiteralPath (Join-Path $MemRoot 'ACTIVE')) {
        $txt = [System.IO.File]::ReadAllText((Join-Path $MemRoot 'ACTIVE'), $script:Utf8NoBom)
        foreach ($ln in (@($txt -split "`n" | Where-Object { $_ -ne '' }))) {
            if ($ln.StartsWith('GENERATION=')) { $genA = [int]$ln.Substring(11) }
        }
    }
    $completedCount = 0; $completedBytes = 0; $activeBytes = 0; $largestBytes = 0; $nonCanonicalBytes = 0
    $genRoot = Join-Path $MemRoot '.gen'
    if (Test-Path -LiteralPath $genRoot) {
        foreach ($d in (Get-ChildItem -LiteralPath $genRoot -Directory -Force)) {
            if ($d.Name -notmatch '^[0-9]{6}$') { continue }
            $n = [int]$d.Name
            $bytes = (Get-DirBytes -Path $d.FullName)
            if ($n -le $genA) {
                $completedCount++
                $completedBytes += $bytes
                if ($n -eq $genA) { $activeBytes = $bytes }
                if ($bytes -gt $largestBytes) { $largestBytes = $bytes }
            } else { $nonCanonicalBytes += $bytes }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $MemRoot 'CURRENT')) {
        $nonCanonicalBytes += (Get-Item -LiteralPath (Join-Path $MemRoot 'CURRENT') -Force).Length
    }
    $rc = 0; $rb = 0
    $recDir = Join-Path $MemRoot 'receipts'
    if (Test-Path -LiteralPath $recDir) {
        foreach ($rf in (Get-ChildItem -LiteralPath $recDir -File -Force)) { $rc++; $rb += $rf.Length }
    }
    return @{ generation_count = $completedCount; completed_bytes_total = $completedBytes; active_generation_bytes = $activeBytes; largest_generation_bytes = $largestBytes; noncanonical_bytes = $nonCanonicalBytes; receipt_count = $rc; receipt_bytes_total = $rb }
}

function PrePlace-Receipt {
    param([string]$MemRoot, [string]$OpId, [string]$Text)
    $d = Join-Path $MemRoot 'receipts'
    [System.IO.Directory]::CreateDirectory($d) | Out-Null
    $p = Join-Path $d ($OpId + '.pass')
    Write-FileUtf8 -Path $p -Text $Text
    return $p
}

function Write-DeepOut {
    param([string]$Root, [string]$Name, [string]$Text)
    $p = Join-Path (Join-Path $Root 'scratchpad') $Name
    Write-FileUtf8 -Path $p -Text $Text
    return $p
}

# ---------------------------------------------------------------------------
# Group B - Operation idempotency (parent AM-T-007)
# ---------------------------------------------------------------------------
function Test-AMT007A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.a'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'ga base' -Summary 'ga base sum' -Provenance 'USER_STATED' -Note 'GA NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opX = New-Uuid
    $spX = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_a.json' -Gen 2 -St $st -OpId $opX -Ops @(New-AddOpX -Subject 'ga rec X' -Summary 'ga rec X sum')
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spX.path) })
    $f1 = @(Check-JsonContract -R $r1 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f1.Count -gt 0) { Set-CaseFailure -Id $id @('setup ' + ($f1 -join ' | ')); return }
    $rr = Retry-Spec -Root $Root -Sp $spX
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('resend: ' + ($fr -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3') }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $a.mem '.gen') '000004')) { Set-CaseFailure -Id $id @('duplicate generation gen4 created') }
}

function Test-AMT007B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.b'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gb base' -Summary 'gb base sum' -Provenance 'USER_STATED' -Note 'GB NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opX = New-Uuid
    $spX = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_b.json' -Gen 2 -St $st -OpId $opX -Ops @(New-AddOpX -Subject 'gb rec X' -Summary 'gb rec X sum')
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spX.path) })
    $f1 = @(Check-JsonContract -R $r1 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f1.Count -gt 0) { Set-CaseFailure -Id $id @('setup ' + ($f1 -join ' | ')); return }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $spXp = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_bp.json' -Gen 3 -St $st3 -OpId $opX -Ops @(New-AddOpX -Subject 'gb rec Xp DIFFERENT BYTES' -Summary 'gb rec Xp sum')
    $rb = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spXp.path) })
    $fb = @(Check-JsonContract -R $rb -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('operation_id_reuse') -ExpectedExit 1)
    if ($fb.Count -gt 0) { Set-CaseFailure -Id $id @('X-prime: ' + ($fb -join ' | ')) }
    $rr = Retry-Spec -Root $Root -Sp $spX
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('recover: ' + ($fr -join ' | ')) }
}

function Test-AMT007C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gc base' -Summary 'gc base sum' -Provenance 'USER_STATED' -Note 'GC NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_c.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'gc rec' -Summary 'gc rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.stdout_lines.Count -ne 0 -or $rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault setup wrong') }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $spY = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_cy.json' -Gen 2 -St $st2 -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'gc rec Y' -Summary 'gc rec Y sum')
    $rr = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spY.path) })
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('pending_operation:' + $opFid) -ExpectedExit 1)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id $fr }
}

function Test-AMT007D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.d'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gd base' -Summary 'gd base sum' -Provenance 'USER_STATED' -Note 'GD NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_d.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'gd rec' -Summary 'gd rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.stdout_lines.Count -ne 0 -or $rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault setup wrong') }
    # (ii) non-matching abort id while a pending exists -> STALE, nothing changed
    $rpBad = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'AbortPending' -Extra @{ 'PendingOperationId' = @((New-Uuid)) })
    $fpBad = @(Check-JsonContract -R $rpBad -ExpectedStatus 'STALE' -ExpectedOp 'abortpending' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fpBad.Count -gt 0) { Set-CaseFailure -Id $id @('(ii) ' + ($fpBad -join ' | ')) }
    # (i) matching abort id -> PASS pending_aborted, CURRENT==ACTIVE identity, pending dir removed
    $rp = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'AbortPending' -Extra @{ 'PendingOperationId' = @($opFid) })
    $fp = @(Check-JsonContract -R $rp -ExpectedStatus 'PASS' -ExpectedOp 'abortpending' -ExpectedRecords @() -ExpectedDiagContains @('pending_aborted:' + $opFid) -ExpectedExit 0)
    if ($fp.Count -gt 0) { Set-CaseFailure -Id $id @('(i) ' + ($fp -join ' | ')) }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $a.mem '.gen') '000003')) { Set-CaseFailure -Id $id @('pending gen3 dir not removed') }
    Assert-CurrentMatchesActive -Id $id -MemRoot $a.mem
    # (iii) plain commit after abort -> PASS gen3
    $stA = Get-ActiveStateHashes -MemRoot $a.mem
    $spN = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_dn.json' -Gen 2 -St $stA -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'gd rec N' -Summary 'gd rec N sum')
    $rn = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spN.path) })
    $fn = @(Check-JsonContract -R $rn -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fn.Count -gt 0) { Set-CaseFailure -Id $id @('(iii) ' + ($fn -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 3) { Set-CaseFailure -Id $id @('ACTIVE generation != 3 after post-abort commit') }
}

function Test-AMT007E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.e'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'ge base' -Summary 'ge base sum' -Provenance 'USER_STATED' -Note 'GE NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_e.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'ge rec' -Summary 'ge rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_BEFORE_STDOUT'
    if ($rf.stdout_lines.Count -ne 0 -or $rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault setup wrong') }
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id $fr }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $a.mem '.gen') '000004')) { Set-CaseFailure -Id $id @('duplicate generation gen4 created') }
}

function Test-AMT007F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.f'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gf base' -Summary 'gf base sum' -Provenance 'USER_STATED' -Note 'GF NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opX = New-Uuid
    $spX = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_fx.json' -Gen 2 -St $st -OpId $opX -Ops @(New-AddOpX -Subject 'gf rec X' -Summary 'gf rec X sum')
    $rx = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spX.path) })
    if (@(Check-JsonContract -R $rx -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('X setup'); return }
    $stY = Get-ActiveStateHashes -MemRoot $a.mem
    $opY = New-Uuid
    $spY = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_fy.json' -Gen 3 -St $stY -OpId $opY -Ops @(New-AddOpX -Subject 'gf rec Y' -Summary 'gf rec Y sum')
    $ry = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spY.path) })
    if (@(Check-JsonContract -R $ry -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0003') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('Y setup'); return }
    $stZ = Get-ActiveStateHashes -MemRoot $a.mem
    $spZ = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_fz.json' -Gen 4 -St $stZ -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'gf rec Z' -Summary 'gf rec Z sum')
    $rz = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spZ.path) })
    if (@(Check-JsonContract -R $rz -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0004') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('Z setup'); return }
    # resend X after two later commits -> historical O(1) recovery
    $rr = Retry-Spec -Root $Root -Sp $spX
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('resend X: ' + ($fr -join ' | ')) }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 5) { Set-CaseFailure -Id $id @('ACTIVE generation != 5') }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $a.mem '.gen') '000006')) { Set-CaseFailure -Id $id @('duplicate generation gen6 created') }
}

function Test-AMT007G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.g'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gg base' -Summary 'gg base sum' -Provenance 'USER_STATED' -Note 'GG NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opX = New-Uuid
    $spX = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_gx.json' -Gen 2 -St $st -OpId $opX -Ops @(New-AddOpX -Subject 'gg rec X' -Summary 'gg rec X sum')
    $rx = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spX.path) })
    if (@(Check-JsonContract -R $rx -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('X setup'); return }
    $stY = Get-ActiveStateHashes -MemRoot $a.mem
    $spY = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_gy.json' -Gen 3 -St $stY -OpId (New-Uuid) -Ops @(New-AddOpX -Subject 'gg rec Y' -Summary 'gg rec Y sum')
    $ry = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spY.path) })
    if (@(Check-JsonContract -R $ry -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0003') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('Y setup'); return }
    # operator out-of-band: delete .gen\000003 (the X snapshot)
    $gen3 = Join-Path (Join-Path $a.mem '.gen') '000003'
    [System.IO.Directory]::Delete($gen3, $true)
    $rr = Retry-Spec -Root $Root -Sp $spX
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @('idempotent_pass_recovered') -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('resend X after snapshot delete: ' + ($fr -join ' | ')) }
    $recX = Join-Path (Join-Path $a.mem 'receipts') ($opX + '.pass')
    if (-not (Test-Path -LiteralPath $recX)) { Set-CaseFailure -Id $id @('receipt for X lost with snapshot') }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 4) { Set-CaseFailure -Id $id @('ACTIVE generation != 4') }
}

function Test-AMT007H {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-007.h'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gh base' -Summary 'gh base sum' -Provenance 'USER_STATED' -Note 'GH NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opX = New-Uuid
    $spX = New-CommitSpecX -Root $Root -Name 'draft_bam_gb_hx.json' -Gen 2 -St $st -OpId $opX -Ops @(New-AddOpX -Subject 'gh rec X' -Summary 'gh rec X sum')
    $rx = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spX.path) })
    if (@(Check-JsonContract -R $rx -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('X setup'); return }
    $rr = Retry-Spec -Root $Root -Sp $spX
    if ($rr.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('retry stdout not exactly one line'); return }
    $line = $rr.stdout_lines[0]
    $j = Parse-JsonLine -Line $line
    $allowed = @('status', 'operation', 'records', 'state_id', 'diagnostics')
    foreach ($p in $j.PSObject.Properties) {
        if ($allowed -notcontains $p.Name) { Set-CaseFailure -Id $id @('unexpected top-level JSON field: ' + $p.Name) }
    }
    $recs = @($j.records)
    if ($recs.Count -ne 1 -or [string]$recs[0] -cne 'mem_0002') { Set-CaseFailure -Id $id @('records != affected ids only') }
    # no content-bearing field (note/summary/subject/file bytes) anywhere in the line
    foreach ($bad in @('NOTE', 'NOTE BODY', 'GH NOTE', 'note_content', 'file_content')) {
        if ($line.IndexOf($bad, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Set-CaseFailure -Id $id @('content-bearing text in JSON: ' + $bad) }
    }
}

# ---------------------------------------------------------------------------
# Group C - Receipt integrity (parent AM-T-006): 006.l..006.r
# ---------------------------------------------------------------------------
function Test-AMT006L {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.l'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cl base' -Summary 'cl base sum' -Provenance 'USER_STATED' -Note 'CL NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op1 = New-Uuid
    $sp1 = New-CommitSpecX -Root $Root -Name 'draft_bam_cl1.json' -Gen 2 -St $st -OpId $op1 -Ops @(New-AddOpX -Subject 'cl rec' -Summary 'cl rec sum')
    $r1 = Retry-Spec -Root $Root -Sp $sp1
    $f1 = @(Check-JsonContract -R $r1 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f1.Count -gt 0) { Set-CaseFailure -Id $id @('commit: ' + ($f1 -join ' | ')); return }
    $recPath = Join-Path (Join-Path $a.mem 'receipts') ($g2.opId + '.pass')
    if (-not (Test-Path -LiteralPath $recPath)) { Set-CaseFailure -Id $id @('receipt not archived after commit'); return }
    $rb = Read-FileBytes -Path $recPath
    $txt = [System.IO.File]::ReadAllText($recPath, $script:Utf8NoBom)
    $rl = @($txt -split "`n" | Where-Object { $_ -ne '' })
    if ($rl.Count -ne 7) { Set-CaseFailure -Id $id @(('receipt lines ' + $rl.Count + ' != 7')) }
    if ($rb.Length -ge 3 -and $rb[0] -eq 0xEF -and $rb[1] -eq 0xBB -and $rb[2] -eq 0xBF) { Set-CaseFailure -Id $id @('receipt has BOM') }
    if ($rb.Length -gt 1024) { Set-CaseFailure -Id $id @(('receipt bytes ' + $rb.Length + ' > 1024')) }
    $fnUuid = [System.IO.Path]::GetFileNameWithoutExtension($recPath)
    $opLine = $rl | Where-Object { $_ -like 'OPERATION_ID=*' }
    $opVal = $opLine.Substring('OPERATION_ID='.Length)
    if ($fnUuid -cne $opVal) { Set-CaseFailure -Id $id @('filename UUID != internal OPERATION_ID') }
    $resLine = $rl | Where-Object { $_ -like 'RESULT=*' }
    if ($resLine -cne 'RESULT=PASS') { Set-CaseFailure -Id $id @('RESULT line wrong: ' + $resLine) }
}

function Test-AMT006M {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.m'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cm base' -Summary 'cm base sum' -Provenance 'USER_STATED' -Note 'CM NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op1 = New-Uuid
    $sp1 = New-CommitSpecX -Root $Root -Name 'draft_bam_cm1.json' -Gen 2 -St $st -OpId $op1 -Ops @(New-AddOpX -Subject 'cm rec' -Summary 'cm rec sum')
    $r1 = Retry-Spec -Root $Root -Sp $sp1
    if ($r1.exit -ne 0) { Set-CaseFailure -Id $id @('first commit failed'); return }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $op2 = New-Uuid
    $sp2 = New-CommitSpecX -Root $Root -Name 'draft_bam_cm2.json' -Gen 3 -St $st2 -OpId $op2 -Ops @(New-AddOpX -Subject 'cm rec2' -Summary 'cm rec2 sum')
    $rf = Fault-Commit -Root $Root -Sp $sp2 -Point 'FAULT_AFTER_RECEIPT_ARCHIVE'
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $recOp1 = Join-Path (Join-Path $a.mem 'receipts') ($op1 + '.pass')
    if (-not (Test-Path -LiteralPath $recOp1)) { Set-CaseFailure -Id $id @('receipts op1 pass not created before fault'); return }
    $shaBefore = (Get-FileHash -LiteralPath $recOp1 -Algorithm SHA256).Hash.ToLowerInvariant()
    $rr = Retry-Spec -Root $Root -Sp $sp2
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0003') -ExpectedDiagContains @('pending_resumed:' + $op2) -ExpectedExit 0)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('retry: ' + ($fr -join ' | ')) }
    $shaAfter = (Get-FileHash -LiteralPath $recOp1 -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($shaBefore -cne $shaAfter) { Set-CaseFailure -Id $id @('receipt bytes changed by re-archive') }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 4) { Set-CaseFailure -Id $id @('ACTIVE generation != 4') }
}

function Test-AMT006N {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.n'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cn base' -Summary 'cn base sum' -Provenance 'USER_STATED' -Note 'CN NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_cn.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'cn rec' -Summary 'cn rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $gen3 = Get-GenDirOf -MemRoot $a.mem -Gen 3
    $stPath = Join-Path $gen3 'STATE'
    $stateSha = (Get-FileHash -LiteralPath $stPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrongReceipt = Build-ReceiptText -Generation 3 -OperationId $opFid -SpecSha $spF.sha -StateSha $stateSha -Action 'add' -AffectedIds 'mem_9999'
    $recPath = PrePlace-Receipt -MemRoot $a.mem -OpId $opFid -Text $wrongReceipt
    $shaBefore = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $rr = Retry-Spec -Root $Root -Sp $spF
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('receipt_history_conflict') -ExpectedExit 1)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('retry: ' + ($fr -join ' | ')) }
    $shaAfter = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($shaBefore -cne $shaAfter) { Set-CaseFailure -Id $id @('pre-placed receipt bytes changed') }
    $cp = Join-Path $a.mem 'CURRENT'
    $ct = [System.IO.File]::ReadAllText($cp, $script:Utf8NoBom)
    if ($ct -notlike '*GENERATION=3*') { Set-CaseFailure -Id $id @('pending state changed (CURRENT gen != 3)') }
}

function Test-AMT006O {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.o'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'co base' -Summary 'co base sum' -Provenance 'USER_STATED' -Note 'CO NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opNew = New-Uuid
    $malformed = 'GEN=1' + "`n" + 'OP=' + $opNew + "`n" + 'SPEC=x' + "`n" + 'STATE=y' + "`n" + 'ACT=add' + "`n" + 'IDS=mem_0002' + "`n"
    $recPath = PrePlace-Receipt -MemRoot $a.mem -OpId $opNew -Text $malformed
    $shaBefore = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $spN = New-CommitSpecX -Root $Root -Name 'draft_bam_co.json' -Gen 2 -St $st -OpId $opNew -Ops @(New-AddOpX -Subject 'co rec' -Summary 'co rec sum')
    $rr = Retry-Spec -Root $Root -Sp $spN
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('receipt_history_conflict') -ExpectedExit 1)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('commit: ' + ($fr -join ' | ')) }
    $shaAfter = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($shaBefore -cne $shaAfter) { Set-CaseFailure -Id $id @('malformed receipt file was modified') }
    if ([int](Get-ActiveStateHashes -MemRoot $a.mem).gen -ne 2) { Set-CaseFailure -Id $id @('state changed (ACTIVE gen != 2)') }
}

function Test-AMT006P {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.p'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cp base' -Summary 'cp base sum' -Provenance 'USER_STATED' -Note 'CP NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $uuidA = New-Uuid
    $uuidB = New-Uuid
    $gen3 = Get-GenDirOf -MemRoot $a.mem -Gen 3
    $stPath = Join-Path $gen3 'STATE'
    if (-not (Test-Path -LiteralPath $stPath)) {
        $stPath = Join-Path (Get-GenDirOf -MemRoot $a.mem -Gen 2) 'STATE'
    }
    $stateSha = (Get-FileHash -LiteralPath $stPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptText = Build-ReceiptText -Generation 2 -OperationId $uuidB -SpecSha 'aabbcc' -StateSha $stateSha -Action 'add' -AffectedIds 'mem_0001'
    $recPath = PrePlace-Receipt -MemRoot $a.mem -OpId $uuidA -Text $receiptText
    $shaBefore = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $spN = New-CommitSpecX -Root $Root -Name 'draft_bam_cp.json' -Gen 2 -St $st -OpId $uuidA -Ops @(New-AddOpX -Subject 'cp rec' -Summary 'cp rec sum')
    $rr = Retry-Spec -Root $Root -Sp $spN
    $fr = @(Check-JsonContract -R $rr -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('receipt_history_conflict') -ExpectedExit 1)
    if ($fr.Count -gt 0) { Set-CaseFailure -Id $id @('commit: ' + ($fr -join ' | ')) }
    $shaAfter = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($shaBefore -cne $shaAfter) { Set-CaseFailure -Id $id @('uuid-mismatch receipt file was modified') }
}

function Test-AMT006Q {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.q'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cq base' -Summary 'cq base sum' -Provenance 'USER_STATED' -Note 'CQ NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $act0 = Read-FileBytes -Path (Join-Path $a.mem 'ACTIVE')
    $op2 = New-Uuid
    $sp2 = New-CommitSpecX -Root $Root -Name 'draft_bam_cq.json' -Gen 2 -St $st -OpId $op2 -Ops @(New-AddOpX -Subject 'cq rec' -Summary 'cq rec sum')
    $rf = Fault-Commit -Root $Root -Sp $sp2 -Point 'FAULT_AFTER_RECEIPT_ARCHIVE'
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $recPath = Join-Path (Join-Path $a.mem 'receipts') ($g2.opId + '.pass')
    if ((Get-Sha256Hex -Bytes (Read-FileBytes -Path $recPath)) -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('receipt != old ACTIVE at fault'); return }
    $rr = Retry-Spec -Root $Root -Sp $sp2
    if (@(Check-JsonContract -R $rr -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0).Count -gt 0) { Set-CaseFailure -Id $id @('retry failed'); return }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $op3 = New-Uuid
    $sp3 = New-CommitSpecX -Root $Root -Name 'draft_bam_cq3.json' -Gen 3 -St $st3 -OpId $op3 -Ops @(New-AddOpX -Subject 'cq rec3' -Summary 'cq rec3 sum')
    $r3 = Retry-Spec -Root $Root -Sp $sp3
    $f3 = @(Check-JsonContract -R $r3 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0003') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f3.Count -gt 0) { Set-CaseFailure -Id $id @('later commit: ' + ($f3 -join ' | ')) }
    $recSha = (Get-Sha256Hex -Bytes (Read-FileBytes -Path $recPath))
    if ($recSha -cne (Get-Sha256Hex -Bytes $act0)) { Set-CaseFailure -Id $id @('byte-identical pair drifted after later commit') }
}

function Test-AMT006R {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.r'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cr base' -Summary 'cr base sum' -Provenance 'USER_STATED' -Note 'CR NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_cr.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'cr rec' -Summary 'cr rec sum')
    $rf = Fault-Commit -Root $Root -Sp $spF -Point 'FAULT_AFTER_CURRENT_SWITCH'
    if ($rf.exit -eq 0) { Set-CaseFailure -Id $id @('fault exit 0') }
    $gen3 = Get-GenDirOf -MemRoot $a.mem -Gen 3
    $stPath = Join-Path $gen3 'STATE'
    $stateSha = (Get-FileHash -LiteralPath $stPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrongReceipt = Build-ReceiptText -Generation 3 -OperationId $opFid -SpecSha $spF.sha -StateSha $stateSha -Action 'add' -AffectedIds 'mem_9999'
    $recPath = PrePlace-Receipt -MemRoot $a.mem -OpId $opFid -Text $wrongReceipt
    $shaBefore = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $rr = Retry-Spec -Root $Root -Sp $spF
    if ($rr.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('not one-line JSON'); return }
    $j = Parse-JsonLine -Line $rr.stdout_lines[0]
    if ($null -eq $j -or $j.status -cne 'UNVERIFIED') { Set-CaseFailure -Id $id @('expected UNVERIFIED') }
    $shaAfter = (Get-FileHash -LiteralPath $recPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($shaBefore -cne $shaAfter) { Set-CaseFailure -Id $id @('pre-placed file SHA changed') }
}

# ---------------------------------------------------------------------------
# Group I - Fault-seam isolation (parent AM-T-006): 006.s..006.v
# ---------------------------------------------------------------------------
function Test-AMT006S {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.s'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cs base' -Summary 'cs base sum' -Provenance 'USER_STATED' -Note 'CS NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opFid = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_cs.json' -Gen 2 -St $st -OpId $opFid -Ops @(New-AddOpX -Subject 'cs rec' -Summary 'cs rec sum')
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spF.path); 'FaultAt' = @('FAULT_BEFORE_CURRENT_SWITCH') })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('FAULT_SEAM_DENIED') -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('fault seam: ' + ($f -join ' | ')) }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('state change: ' + ($diff -join ' | ')) }
}

function Test-AMT006T {
    param([string]$Root)
    $id = 'AM-T-006.t'
    $plainGuid = [System.Guid]::NewGuid().ToString().ToLowerInvariant()
    $plainRoot = Join-Path ([System.IO.Path]::GetTempPath().TrimEnd('\')) ('bam-plain-' + $plainGuid)
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $plainRoot 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $plainRoot 'scratchpad')) | Out-Null
    $plainMem = Join-Path (Join-Path $plainRoot 'workspace') 'memory'
    $initOp = New-Uuid
    $spInit = Write-SpecFile -Root $plainRoot -Name 'draft_bam_ct_init.json' -SpecObj (New-InitializeSpec -OpId $initOp -Expected (New-EmptyExpected))
    $rInit = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', $plainMem, '-WorkspaceRoot', (Join-Path $plainRoot 'workspace'), '-ScratchpadRoot', (Join-Path $plainRoot 'scratchpad'), '-Spec', $spInit.path)
    if ($rInit.exit -ne 0) { Set-CaseFailure -Id $id @('init in plain root failed'); Remove-FixtureRoot -Root $plainRoot; return }
    $stP = Get-ActiveStateHashes -MemRoot $plainMem
    $opFid = New-Uuid
    $spF = Write-SpecFile -Root $plainRoot -Name 'draft_bam_ct.json' -SpecObj (New-CommitSpec -OpId $opFid -Expected (New-ExpectedBlock -Generation 1 -Core $stP.core -Index $stP.index -Archive $stP.archive) -Ops @(New-AddOpX -Subject 'ct rec' -Summary 'ct rec sum'))
    $r = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', $plainMem, '-WorkspaceRoot', (Join-Path $plainRoot 'workspace'), '-ScratchpadRoot', (Join-Path $plainRoot 'scratchpad'), '-Spec', $spF.path, '-TestMode', '-FaultAt', 'FAULT_BEFORE_CURRENT_SWITCH')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('FAULT_SEAM_DENIED') -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('fault seam: ' + ($f -join ' | ')) }
    Remove-FixtureRoot -Root $plainRoot
}

function Test-AMT006U {
    param([string]$Root)
    $id = 'AM-T-006.u'
    $prodMem = Join-Path $script:Ws 'memory'
    $prodWs = $script:Ws
    $prodExisted = Test-Path -LiteralPath $prodMem
    $r = Invoke-Tool -Args @('-Mode', 'Validate', '-MemoryRoot', $prodMem, '-WorkspaceRoot', $prodWs, '-TestMode', '-FaultAt', 'FAULT_BEFORE_CURRENT_SWITCH')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @('FAULT_SEAM_DENIED') -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('production fault: ' + ($f -join ' | ')) }
    $prodExistedAfter = Test-Path -LiteralPath $prodMem
    if ($prodExistedAfter -ne $prodExisted) { Set-CaseFailure -Id $id @('production memory root existence changed') }
}

function Test-AMT006V {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-006.v'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'cv base' -Summary 'cv base sum' -Provenance 'USER_STATED' -Note 'CV NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opNew = New-Uuid
    $spN = New-CommitSpecX -Root $Root -Name 'draft_bam_cv.json' -Gen 2 -St $st -OpId $opNew -Ops @(New-AddOpX -Subject 'cv rec' -Summary 'cv rec sum')
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spN.path); 'TestMode' = $true })
    if ($r.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('stdout not one line'); return }
    $j = Parse-JsonLine -Line $r.stdout_lines[0]
    if ($null -eq $j) { Set-CaseFailure -Id $id @('not valid JSON'); return }
    if ($j.status -cne 'FAILED') { Set-CaseFailure -Id $id @(('status ' + $j.status + ' != FAILED')) }
    if ($j.operation -cne 'commit') { Set-CaseFailure -Id $id @(('operation ' + $j.operation + ' != commit')) }
    $recs = @($j.records)
    if ($recs.Count -ne 0) { Set-CaseFailure -Id $id @('records not empty') }
    if ($null -eq $j.state_id) { Set-CaseFailure -Id $id @('state_id missing') }
    $diags = @($j.diagnostics)
    if ($diags -notcontains 'USAGE_ERROR') { Set-CaseFailure -Id $id @('diagnostics missing USAGE_ERROR') }
    if ($r.exit -ne 2) { Set-CaseFailure -Id $id @(('exit ' + $r.exit + ' != 2')) }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('state change: ' + ($diff -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Group L - Forbidden-field commit (parent AM-T-020): 020.a
# ---------------------------------------------------------------------------
function Test-AMT020A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-020.a'
    $tokens = @('GO_STATE', 'AUTHORIZED', 'EXECUTION_AUTHORIZATION', 'VALID_GO', 'APPROVED_TO_EXECUTE')
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'ca base' -Summary 'ca base sum' -Provenance 'USER_STATED' -Note 'CA NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $i = 0
    foreach ($tok in $tokens) {
        $i++
        $st = Get-ActiveStateHashes -MemRoot $a.mem
        $spN = New-CommitSpecX -Root $Root -Name ('draft_bam_ca_' + $i + '.json') -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject ('x ' + $tok + ' x') -Summary 'ca sum')
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spN.path) })
        $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
        if ($f.Count -gt 0) { Set-CaseFailure -Id $id @((($tok + ': ') + ($f -join ' | '))) }
    }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('manifest changed: ' + ($diff -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Group F - FilterDeepOut (parent AM-T-018): 018.a..018.i
# ---------------------------------------------------------------------------
function Test-AMT018A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.a'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fa base' -Summary 'fa base sum' -Provenance 'USER_STATED' -Note 'FA NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $faText = 'CAND:mem_0001|2026-10-07|subject here|evidence fact one|src.md' + "`n" + 'CAND:mem_0002|2026-10-07|another subject|evidence fact two|src2.md' + "`n"
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fa_out.txt' -Text $faText
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'HIT' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
    $candFiles = @(Get-ChildItem -LiteralPath $a.sp -File -Force | Where-Object { $_.Name -like 'draft_bam_deep_candidates_*' })
    if ($candFiles.Count -ne 1) { Set-CaseFailure -Id $id @(('candidate file count ' + $candFiles.Count + ' != 1')); return }
    $candText = [System.IO.File]::ReadAllText($candFiles[0].FullName, $script:Utf8NoBom)
    $candLines = @($candText -split "`n" | Where-Object { $_ -ne '' })
    if ($candLines.Count -ne 2) { Set-CaseFailure -Id $id @(('candidate lines ' + $candLines.Count + ' != 2')) }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('memory changed: ' + ($diff -join ' | ')) }
}

function Test-AMT018B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.b'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fb base' -Summary 'fb base sum' -Provenance 'USER_STATED' -Note 'FB NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le 7; $i++) { $null = $sb.Append('CAND:mem_000' + $i + '|2026-10-07|subject num ' + $i + '|evidence fact num ' + $i + '|src' + $i + '.md' + "`n") }
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fb_out.txt' -Text $sb.ToString()
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'HIT' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
    $candFiles = @(Get-ChildItem -LiteralPath $a.sp -File -Force | Where-Object { $_.Name -like 'draft_bam_deep_candidates_*' })
    if ($candFiles.Count -ne 1) { Set-CaseFailure -Id $id @('candidate file count wrong'); return }
    $candText = [System.IO.File]::ReadAllText($candFiles[0].FullName, $script:Utf8NoBom)
    $candLines = @($candText -split "`n" | Where-Object { $_ -ne '' })
    if ($candLines.Count -ne 3) { Set-CaseFailure -Id $id @(('candidate lines ' + $candLines.Count + ' != 3')); return }
    if ($candLines[0] -cne 'CAND:mem_0001|2026-10-07|subject num 1|evidence fact num 1|src1.md') { Set-CaseFailure -Id $id @('first line mismatch') }
    if ($candLines[1] -cne 'CAND:mem_0002|2026-10-07|subject num 2|evidence fact num 2|src2.md') { Set-CaseFailure -Id $id @('second line mismatch') }
    if ($candLines[2] -cne 'CAND:mem_0003|2026-10-07|subject num 3|evidence fact num 3|src3.md') { Set-CaseFailure -Id $id @('third line mismatch (must be first 3)') }
}

function Test-AMT018C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fc base' -Summary 'fc base sum' -Provenance 'USER_STATED' -Note 'FC NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $bad6 = 'CAND:mem_0001|2026-10-07|subject|evidence|extra|field' + "`n"
    $good1 = 'CAND:mem_0002|2026-10-07|good subject one|evidence fact one|src.md' + "`n"
    $good2 = 'CAND:mem_0003|2026-10-07|good subject two|evidence fact two|src2.md' + "`n"
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fc_out.txt' -Text ($bad6 + $good1 + $good2)
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'HIT' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
    $candFiles = @(Get-ChildItem -LiteralPath $a.sp -File -Force | Where-Object { $_.Name -like 'draft_bam_deep_candidates_*' })
    if ($candFiles.Count -ne 1) { Set-CaseFailure -Id $id @('candidate file count wrong'); return }
    $candText = [System.IO.File]::ReadAllText($candFiles[0].FullName, $script:Utf8NoBom)
    $candLines = @($candText -split "`n" | Where-Object { $_ -ne '' })
    if ($candLines.Count -ne 2) { Set-CaseFailure -Id $id @(('kept lines ' + $candLines.Count + ' != 2')) }
}

function Test-AMT018D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.d'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fd base' -Summary 'fd base sum' -Provenance 'USER_STATED' -Note 'FD NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $bad7 = 'CAND:mem_0001|2026-10-07|s|e|a|b|c' + "`n"
    $good = 'CAND:mem_0002|2026-10-07|good subject|evidence fact ok|src.md' + "`n"
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fd_out.txt' -Text ($bad7 + $good)
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'HIT' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
    $candFiles = @(Get-ChildItem -LiteralPath $a.sp -File -Force | Where-Object { $_.Name -like 'draft_bam_deep_candidates_*' })
    if ($candFiles.Count -ne 1) { Set-CaseFailure -Id $id @('candidate file count wrong'); return }
    $candText = [System.IO.File]::ReadAllText($candFiles[0].FullName, $script:Utf8NoBom)
    $candLines = @($candText -split "`n" | Where-Object { $_ -ne '' })
    if ($candLines.Count -ne 1) { Set-CaseFailure -Id $id @(('kept lines ' + $candLines.Count + ' != 1')) }
}

function Test-AMT018E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.e'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fe base' -Summary 'fe base sum' -Provenance 'USER_STATED' -Note 'FE NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fe_out.txt' -Text 'NO_MATCH' + "`n"
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'MISS' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
}

function Test-AMT018F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.f'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'ff base' -Summary 'ff base sum' -Provenance 'USER_STATED' -Note 'FF NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $nonExistent = Join-Path $a.sp 'draft_bam_ff_nonexistent_out.txt'
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($nonExistent) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
}

function Test-AMT018G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.g'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fg base' -Summary 'fg base sum' -Provenance 'USER_STATED' -Note 'FG NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $bigLine = 'CAND:mem_0001|2026-10-07|' + ('x' * 270000) + '|evidence fact one|src.md'
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fg_out.txt' -Text ($bigLine + "`n")
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'FAILED' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @('out_exceeds_bound') -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
}

function Test-AMT018H {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.h'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fh base' -Summary 'fh base sum' -Provenance 'USER_STATED' -Note 'FH NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fh_out.txt' -Text 'CAND:mem_0001|2026-10-07|subject here|evidence fact one|src.md' + "`n"
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    if ($r1.exit -ne 0) { Set-CaseFailure -Id $id @('first FilterDeepOut failed'); return }
    $m1 = Get-Manifest -Root $a.mem
    $diff1 = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff1.Count -gt 0) { Set-CaseFailure -Id $id @('memory changed after FilterDeepOut: ' + ($diff1 -join ' | ')) }
}

function Test-AMT018I {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.i'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fi base' -Summary 'fi base sum' -Provenance 'USER_STATED' -Note 'FI NOTE BASE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $marker = 'RAW_OUT_MARKER_XYZ789'
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fi_out.txt' -Text ('CAND:mem_0001|2026-10-07|subject here|evidence ' + $marker + '|src.md' + "`n")
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    if ($r.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('not one line'); return }
    $jsonLine = $r.stdout_lines[0]
    if ($jsonLine.IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0) { Set-CaseFailure -Id $id @('raw OUT marker found in JSON (exposure)') }
    $j = Parse-JsonLine -Line $jsonLine
    if ($null -eq $j) { Set-CaseFailure -Id $id @('invalid JSON'); return }
    if ($j.status -cne 'HIT') { Set-CaseFailure -Id $id @(('status ' + $j.status + ' != HIT')) }
    if (-not ($j.PSObject.Properties.Name -contains 'candidate_file')) { Set-CaseFailure -Id $id @('JSON missing candidate_file field') }
}

# ---------------------------------------------------------------------------
# Machine-half hosts for live behavioral parents
# ---------------------------------------------------------------------------
function Test-AMT018Host {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-018.MACHINE_HALF'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'fhost base' -Summary 'fhost base sum' -Provenance 'USER_STATED' -Note 'FHOST NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $sb = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le 3; $i++) { $null = $sb.Append('CAND:mem_000' + $i + '|2026-10-07|host subject ' + $i + '|host evidence ' + $i + '|src' + $i + '.md' + "`n") }
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_fhost_out.txt' -Text $sb.ToString()
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'FilterDeepOut' -Extra @{ sp = $true; 'Out' = @($out) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'HIT' -ExpectedOp 'filterdeepout' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @('contract: ' + ($f -join ' | ')) }
    $candFiles = @(Get-ChildItem -LiteralPath $a.sp -File -Force | Where-Object { $_.Name -like 'draft_bam_deep_candidates_*' })
    if ($candFiles.Count -ne 1) { Set-CaseFailure -Id $id @('candidate file not found'); return }
    $candLines = @([System.IO.File]::ReadAllText($candFiles[0].FullName, $script:Utf8NoBom) -split "`n" | Where-Object { $_ -ne '' })
    if ($candLines.Count -ne 3) { Set-CaseFailure -Id $id @(('candidate lines ' + $candLines.Count + ' != 3')) }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('memory changed: ' + ($diff -join ' | ')) }
}

function Test-AMT020Host {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-020.MACHINE_HALF'
    $tokens = @('GO_STATE', 'AUTHORIZED', 'EXECUTION_AUTHORIZATION', 'VALID_GO', 'APPROVED_TO_EXECUTE')
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'lhost base' -Summary 'lhost base sum' -Provenance 'USER_STATED' -Note 'LHOST NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $m0 = Get-Manifest -Root $a.mem
    $fields = @('subject', 'summary')
    $i = 0
    foreach ($tok in $tokens) {
        foreach ($fld in $fields) {
            $i++
            $st = Get-ActiveStateHashes -MemRoot $a.mem
            $subj = 'lh subject ' + $i
            $summ = 'lh sum ' + $i
            if ($fld -eq 'subject') { $subj = 'x ' + $tok + ' x' }
            if ($fld -eq 'summary') { $summ = 'x ' + $tok + ' x' }
            $op = New-AddOp -Subject $subj -Summary $summ -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
            $spN = New-CommitSpecX -Root $Root -Name ('draft_bam_lh_' + $i + '.json') -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @($op)
            $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spN.path) })
            $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
            if ($f.Count -gt 0) { Set-CaseFailure -Id $id @((($tok + '/' + $fld + ': ') + ($f -join ' | '))) }
        }
    }
    $m1 = Get-Manifest -Root $a.mem
    $diff = @(Compare-Manifests -Before $m0 -After $m1)
    if ($diff.Count -gt 0) { Set-CaseFailure -Id $id @('manifest changed: ' + ($diff -join ' | ')) }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-026 note byte bound
# ---------------------------------------------------------------------------
function Test-AMT026 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-026'
    $init = Build-InitializedFixture -Root $Root
    if ($init.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $note32768 = (New-NoteFiller -Bytes 32768)
    $op1 = New-Uuid
    $sp1 = New-CommitSpecX -Root $Root -Name 'draft_bam_026a.json' -Gen 1 -St $st -OpId $op1 -Ops @(New-AddOp -Subject '026 max' -Summary '026 max sum' -Provenance 'USER_STATED' -Tags $null -Note $note32768 -Evidence $null -Pin $null -Supersedes $null)
    $r1 = Retry-Spec -Root $Root -Sp $sp1
    $f1 = @(Check-JsonContract -R $r1 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0001') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f1.Count -gt 0) { Set-CaseFailure -Id $id @('(1) 32768: ' + ($f1 -join ' | ')) }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $note32769 = (New-NoteFiller -Bytes 32769)
    $op2 = New-Uuid
    $sp2 = New-CommitSpecX -Root $Root -Name 'draft_bam_026b.json' -Gen 2 -St $st2 -OpId $op2 -Ops @(New-AddOp -Subject '026 over' -Summary '026 over sum' -Provenance 'USER_STATED' -Tags $null -Note $note32769 -Evidence $null -Pin $null -Supersedes $null)
    $r2 = Retry-Spec -Root $Root -Sp $sp2
    $f2 = @(Check-JsonContract -R $r2 -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f2.Count -gt 0) { Set-CaseFailure -Id $id @('(2) 32769: ' + ($f2 -join ' | ')) }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $note32768b = (New-NoteFiller -Bytes 32768)
    $op3 = New-Uuid
    $sp3 = New-CommitSpecX -Root $Root -Name 'draft_bam_026c.json' -Gen 2 -St $st3 -OpId $op3 -Ops @(New-AddOp -Subject '026 max2' -Summary '026 max2 sum' -Provenance 'USER_STATED' -Tags $null -Note $note32768b -Evidence $null -Pin $null -Supersedes $null)
    $r3 = Retry-Spec -Root $Root -Sp $sp3
    $f3 = @(Check-JsonContract -R $r3 -ExpectedStatus 'PASS' -ExpectedOp 'commit' -ExpectedRecords @('mem_0002') -ExpectedDiagContains @() -ExpectedExit 0)
    if ($f3.Count -gt 0) { Set-CaseFailure -Id $id @('(3) second 32768: ' + ($f3 -join ' | ')) }
    $gen3 = Get-GenDirOf -MemRoot $a.mem -Gen 3
    $noteDir = Join-Path $gen3 'notes'
    $noteFiles = @(Get-ChildItem -LiteralPath $noteDir -File -Force -ErrorAction SilentlyContinue)
    if ($noteFiles.Count -lt 2) { Set-CaseFailure -Id $id @('expected 2 note files in gen3, got ' + $noteFiles.Count) }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-027 P95 performance (frozen 04 max-size fixture: probe36 Part C)
# ---------------------------------------------------------------------------
function Test-AMT027 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-027'
    $init = Build-InitializedFixture -Root $Root
    if ($init.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $note27 = New-NoteFiller -Bytes 32768
    # G30: 30 pinned records, one note each, in a single spec
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opsG30 = @()
    for ($i = 1; $i -le 30; $i++) {
        if ($i -le 10) { $subj = 'perf27-' + ('a' * 48) } else { $subj = 'pad027-' + ('b' * 48) }
        if ($i -eq 5) { $sumG = ('s' * 146) } else { $sumG = ('s' * 10) }
        $opsG30 += New-AddOp -Subject $subj -Summary $sumG -Provenance 'USER_STATED' -Tags @('p27') -Note $note27 -Evidence $null -Pin 'true' -Supersedes $null
    }
    $stG30 = Commit-BoundedMultiSpec -Id $id -Root $Root -Ops $opsG30
    if ($null -eq $stG30) { return }
    if ($stG30.gen -ne 3) { Set-CaseFailure -Id $id @(('G30 gen ' + $stG30.gen + ' != 3')); return }
    $g2dir = Get-GenDirOf -MemRoot $a.mem -Gen 3
    $cbG30 = Get-ContentBytesAfterHeader -Path (Join-Path $g2dir 'core.md')
    $ibG30 = Get-ContentBytesAfterHeader -Path (Join-Path $g2dir 'index.md')
    if ($cbG30 -ne 4096) { Set-CaseFailure -Id $id @(('G30 core bytes after header ' + $cbG30 + ' != 4096')); return }
    if ($ibG30 -ne 4096) { Set-CaseFailure -Id $id @(('G30 index bytes after header ' + $ibG30 + ' != 4096')); return }
    $coreLinesG30 = @(([System.IO.File]::ReadAllText((Join-Path $g2dir 'core.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })
    if ($coreLinesG30.Count -ne 31) { Set-CaseFailure -Id $id @(('G30 core non-empty lines ' + $coreLinesG30.Count + ' != 31')); return }
    # I100: 100 plain records in a single spec
    $opsI100 = @()
    for ($i = 1; $i -le 100; $i++) {
        $opsI100 += New-AddOp -Subject ('idx027-' + ('c' * 48)) -Summary ('u' * 256) -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null
    }
    $stI100 = Commit-BoundedMultiSpec -Id $id -Root $Root -Ops $opsI100 -Base 30
    if ($null -eq $stI100) { return }
    if ($stI100.gen -ne 10) { Set-CaseFailure -Id $id @(('I100 gen ' + $stI100.gen + ' != 10')); return }
    $g3dir = Get-GenDirOf -MemRoot $a.mem -Gen 10
    if ((Get-ContentBytesAfterHeader -Path (Join-Path $g3dir 'core.md')) -ne 4096) { Set-CaseFailure -Id $id @('I100 core bytes after header != 4096'); return }
    if ((Get-ContentBytesAfterHeader -Path (Join-Path $g3dir 'index.md')) -ne 29226) { Set-CaseFailure -Id $id @('I100 index bytes after header != 29226'); return }
    $idxLinesI100 = @(([System.IO.File]::ReadAllText((Join-Path $g3dir 'index.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })
    if ($idxLinesI100.Count -ne 101) { Set-CaseFailure -Id $id @(('I100 index non-empty lines ' + $idxLinesI100.Count + ' != 101')); return }
    $evictedI100 = @(([System.IO.File]::ReadAllText((Join-Path $g3dir 'archive.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { ($_ -ne '') -and ($_ -notmatch '^#') -and ($_ -match '\|evicted\|') })
    if ($evictedI100.Count -ne 30) { Set-CaseFailure -Id $id @(('I100 evicted lines ' + $evictedI100.Count + ' != 30')); return }
    # R70: 70 CJK-fill records in a single spec (normative fixture, 04-compliant).
    # No evidence files and no long paths: source_pointer '-' for every row, so
    # the case no longer depends on per-PC long-path limits (LongPathsEnabled).
    # Byte budget (measured on probe027_new gen15): row = 63 B fixed + 192 B
    # subject (64 x U+4E00 at 3 B/char) + 621 B summary (207 x U+4E01) + 0/1 tag
    # byte = 877 B (rows 1-50, tag 'a') / 876 B (rows 51-70). 50x877 + 20x876
    # + G30 4066 + 100 LF = 65536 after-header; index file = 17 + 1 + 65536
    # = 65554 B. A pure-ASCII max row (514 B) cannot reach 65536 (70x514 + 4066
    # + 100 = 40146), so multi-byte fill is mandatory. Source stays ASCII-only:
    # CJK is constructed via [char]0xNNNN.
    $subjR70 = ([string][char]0x4E00) * 64
    $summR70 = ([string][char]0x4E01) * 207
    if ($subjR70.Length -ne 64) { Set-CaseFailure -Id $id @('subjR70 char len ' + $subjR70.Length + ' != 64'); return }
    if ($summR70.Length -ne 207) { Set-CaseFailure -Id $id @('summR70 char len ' + $summR70.Length + ' != 207'); return }
    $opsR70 = @()
    for ($i = 1; $i -le 70; $i++) {
        if ($i -le 50) { $tagsR70 = @('a') } else { $tagsR70 = $null }
        $opsR70 += New-AddOp -Subject $subjR70 -Summary $summR70 -Provenance 'USER_STATED' -Tags $tagsR70 -Note $note27 -Evidence $null -Pin $null -Supersedes $null
    }
    $stR70 = Commit-BoundedMultiSpec -Id $id -Root $Root -Ops $opsR70 -Base 130
    if ($null -eq $stR70) { return }
    if ($stR70.gen -ne 15) { Set-CaseFailure -Id $id @(('R70 gen ' + $stR70.gen + ' != 15')); return }
    $g4dir = Get-GenDirOf -MemRoot $a.mem -Gen 15
    if ((Get-ContentBytesAfterHeader -Path (Join-Path $g4dir 'core.md')) -ne 4096) { Set-CaseFailure -Id $id @('R70 core bytes after header != 4096'); return }
    if ((Get-ContentBytesAfterHeader -Path (Join-Path $g4dir 'index.md')) -ne 65536) { Set-CaseFailure -Id $id @('R70 index bytes after header != 65536'); return }
    $idxLinesR70 = @(([System.IO.File]::ReadAllText((Join-Path $g4dir 'index.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { $_ -ne '' })
    if ($idxLinesR70.Count -ne 101) { Set-CaseFailure -Id $id @(('R70 index non-empty lines ' + $idxLinesR70.Count + ' != 101')); return }
    $evictedR70 = @(([System.IO.File]::ReadAllText((Join-Path $g4dir 'archive.md'), $script:Utf8NoBom)) -split "`n" | Where-Object { ($_ -ne '') -and ($_ -notmatch '^#') -and ($_ -match '\|evicted\|') })
    if ($evictedR70.Count -ne 100) { Set-CaseFailure -Id $id @(('R70 evicted lines ' + $evictedR70.Count + ' != 100')); return }
    $noteFilesR70 = @(Get-ChildItem -LiteralPath (Join-Path $g4dir 'notes') -File -Force)
    if ($noteFilesR70.Count -ne 100) { Set-CaseFailure -Id $id @(('R70 note files ' + $noteFilesR70.Count + ' != 100')); return }
    # Recall series: 5 warmup + 50 measured
    $m0 = Get-Manifest -Root $a.mem
    $query27 = 'perf27-'
    $warmup27 = @()
    for ($i = 1; $i -le 5; $i++) {
        $rw = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @($query27); 'Max' = @(10) })
        if ($rw.exit -ne 0) { Set-CaseFailure -Id $id @(('warmup ' + $i + ' failed exit=' + $rw.exit)); return }
        $warmup27 += $rw.ms
    }
    $measured27 = @()
    $firstRaw27 = $null
    for ($i = 1; $i -le 50; $i++) {
        $rm = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @($query27); 'Max' = @(10) })
        if ($rm.exit -ne 0) { Set-CaseFailure -Id $id @(('measured run ' + $i + ' failed exit=' + $rm.exit)) }
        elseif ($rm.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @(('measured run ' + $i + ' not one line')) }
        else {
            $jm = Parse-JsonLine -Line $rm.stdout_lines[0]
            if ($null -eq $jm -or $jm.status -cne 'HIT') { Set-CaseFailure -Id $id @(('measured run ' + $i + ' not HIT')) }
            else {
                Assert-Candidates -Id $id -J $jm -ExpectedIds @('mem_0001','mem_0002','mem_0003','mem_0004','mem_0005','mem_0006','mem_0007','mem_0008','mem_0009','mem_0010')
                if ($null -eq $firstRaw27) { $firstRaw27 = $rm.stdout_lines[0] }
                elseif ([string]$rm.stdout_lines[0] -cne $firstRaw27) { Set-CaseFailure -Id $id @(('measured run ' + $i + ' raw stdout not byte-identical to run 1')) }
            }
            $measured27 += $rm.ms
        }
    }
    $sorted27 = @($measured27 | Sort-Object)
    $p9527 = $sorted27[47]
    if ($p9527 -gt 2000) { Set-CaseFailure -Id $id @(('P95 ' + $p9527 + ' ms > 2000 ms (HARD FAIL)')) }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
    $null = Write-DeepOut -Root $Root -Name 'bam_t027_series.txt' -Text ('WARMUP:' + ($warmup27 -join ',') + "`nMEASURED:" + ($measured27 -join ',') + "`nSORTED:" + ($sorted27 -join ',') + "`nP95:" + $p9527 + "`nCMD: <ps> -NoLogo -NoProfile -NonInteractive -File <tool> -Mode Recall -MemoryRoot <mem> -WorkspaceRoot <ws> -Query perf27- -Max 10" + "`nHOST: " + ([string]$PSVersionTable.PSVersion) + ' ' + $env:COMPUTERNAME + "`nGEN4_INDEX_SHA256=" + (Get-Sha256File -Path (Join-Path $g4dir 'index.md')) + "`nGEN4_CORE_SHA256=" + (Get-Sha256File -Path (Join-Path $g4dir 'core.md')) + "`n")
    # old artifact assertions
    $oldArtifacts = @(Get-ChildItem -LiteralPath $a.sp -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*bam_t027_raw_series*' })
    if ($oldArtifacts.Count -gt 0) { Set-CaseFailure -Id $id @('old raw series artifact still present') }
    $idxTextG4 = [System.IO.File]::ReadAllText((Join-Path $g4dir 'index.md'), $script:Utf8NoBom)
    if ($idxTextG4.IndexOf('perf10-', [System.StringComparison]::Ordinal) -ge 0) { Set-CaseFailure -Id $id @('legacy perf10- marker in final index') }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-028 archive invisible + retention + metrics
# ---------------------------------------------------------------------------
function Test-AMT028 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-028'
    $rootA = (Join-Path $Root 'va')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootA 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootA 'scratchpad')) | Out-Null
    $initA = Build-InitializedFixture -Root $rootA
    if ($initA.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture A init failed'); return }
    $memA = Join-Path (Join-Path $rootA 'workspace') 'memory'
    $stA = Get-ActiveStateHashes -MemRoot $memA
    $kw = 'archtest'
    $opA1 = New-Uuid
    $spA1 = New-CommitSpecX -Root $rootA -Name 'draft_bam_028a1.json' -Gen 1 -St $stA -OpId $opA1 -Ops @(New-AddOp -Subject ($kw + ' one') -Summary '028a s1' -Provenance 'USER_STATED' -Tags $null -Note '028a note' -Evidence $null -Pin $false -Supersedes $null)
    $null = Retry-Spec -Root $rootA -Sp $spA1
    $stA2 = Get-ActiveStateHashes -MemRoot $memA
    $opA2 = New-Uuid
    $spA2 = New-CommitSpecX -Root $rootA -Name 'draft_bam_028a2.json' -Gen 2 -St $stA2 -OpId $opA2 -Ops @(New-AddOp -Subject 'other rec' -Summary '028a s2' -Provenance 'USER_STATED' -Tags $null -Note '028a note2' -Evidence $null -Pin $false -Supersedes $null)
    $null = Retry-Spec -Root $rootA -Sp $spA2
    $rJA = Invoke-Tool -Args @('-Mode', 'Recall', '-MemoryRoot', $memA, '-WorkspaceRoot', (Join-Path $rootA 'workspace'), '-Query', $kw, '-Max', '10')
    if ($rJA.exit -ne 0 -or $rJA.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('fixture A recall failed'); return }
    $jaJson = $rJA.stdout_lines[0]
    $rootB = (Join-Path $Root 'vb')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $initB = Build-InitializedFixture -Root $rootB
    if ($initB.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture B init failed'); return }
    $memB = Join-Path (Join-Path $rootB 'workspace') 'memory'
    $stB = Get-ActiveStateHashes -MemRoot $memB
    $opB1 = New-Uuid
    $spB1 = New-CommitSpecX -Root $rootB -Name 'draft_bam_028b1.json' -Gen 1 -St $stB -OpId $opB1 -Ops @(New-AddOp -Subject ($kw + ' one') -Summary '028b s1' -Provenance 'USER_STATED' -Tags $null -Note '028b note' -Evidence $null -Pin $false -Supersedes $null)
    $null = Retry-Spec -Root $rootB -Sp $spB1
    $stB2 = Get-ActiveStateHashes -MemRoot $memB
    $opB2 = New-Uuid
    $spB2 = New-CommitSpecX -Root $rootB -Name 'draft_bam_028b2.json' -Gen 2 -St $stB2 -OpId $opB2 -Ops @(New-AddOp -Subject 'other rec' -Summary '028b s2' -Provenance 'USER_STATED' -Tags $null -Note '028b note2' -Evidence $null -Pin $false -Supersedes $null)
    $null = Retry-Spec -Root $rootB -Sp $spB2
    for ($i = 3; $i -le 20; $i++) {
        $stBx = Get-ActiveStateHashes -MemRoot $memB
        $opBx = New-Uuid
        $spBx = New-CommitSpecX -Root $rootB -Name ('draft_bam_028bx' + $i + '.json') -Gen $stBx.gen -St $stBx -OpId $opBx -Ops @(New-AddOp -Subject ('filler ' + $i) -Summary ('filler sum ' + $i) -Provenance 'USER_STATED' -Tags $null -Note 'filler note body content here' -Evidence $null -Pin $false -Supersedes $null)
        $null = Retry-Spec -Root $rootB -Sp $spBx
    }
    $stBf = Get-ActiveStateHashes -MemRoot $memB
    for ($i = 3; $i -le 20; $i++) {
        $stBx = Get-ActiveStateHashes -MemRoot $memB
        $opBx = New-Uuid
        $spBx = New-CommitSpecX -Root $rootB -Name ('draft_bam_028bx' + $i + '.json') -Gen $stBx.gen -St $stBx -OpId $opBx -Ops @([pscustomobject]@{ op = 'forget'; record_id = ('mem_' + ('{0:0000}' -f $i) ) })
        $null = Retry-Spec -Root $rootB -Sp $spBx
    }
    $rJB = Invoke-Tool -Args @('-Mode', 'Recall', '-MemoryRoot', $memB, '-WorkspaceRoot', (Join-Path $rootB 'workspace'), '-Query', $kw, '-Max', '10')
    if ($rJB.exit -ne 0 -or $rJB.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('fixture B recall failed'); return }
    $jbJson = $rJB.stdout_lines[0]
    $jA = Parse-JsonLine -Line $jaJson
    $jB = Parse-JsonLine -Line $jbJson
    $recA = @($jA.records)
    $recB = @($jB.records)
    if ($recA.Count -ne $recB.Count) { Set-CaseFailure -Id $id @('JA/JB record count differ (archive influenced recall)') }
    # Retention: 5 successive commits on the main fixture
    $g2m = Build-Gen2Fixture -Root $Root -Subject '028m base' -Summary '028m sum' -Provenance 'USER_STATED' -Note '028M NOTE' -Evidence $null
    if ($g2m.r.exit -ne 0) { Set-CaseFailure -Id $id @('main fixture build failed'); return }
    $stM = Get-ActiveStateHashes -MemRoot $a.mem
    for ($i = 3; $i -le 6; $i++) {
        $stMx = Get-ActiveStateHashes -MemRoot $a.mem
        $opM = New-Uuid
        $spM = New-CommitSpecX -Root $Root -Name ('draft_bam_028m' + $i + '.json') -Gen $stMx.gen -St $stMx -OpId $opM -Ops @(New-AddOpX -Subject ('028m rec' + $i) -Summary ('028m sum' + $i))
        $null = Retry-Spec -Root $Root -Sp $spM
    }
    $gens = @(Get-GenList -MemRoot $a.mem)
    if ($gens.Count -lt 6) { Set-CaseFailure -Id $id @(('gen count ' + $gens.Count + ' < 6 (auto-deletion)')) }
    $rStat = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Status')
    if ($rStat.exit -ne 0 -or $rStat.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('Status failed'); return }
    $jStat = Parse-JsonLine -Line $rStat.stdout_lines[0]
    if ($null -eq $jStat -or $jStat.status -cne 'PASS') { Set-CaseFailure -Id $id @('Status not PASS'); return }
    $indep = Measure-StatusMetricsIndependent -MemRoot $a.mem
    foreach ($k in @('generation_count', 'completed_bytes_total', 'active_generation_bytes', 'largest_generation_bytes', 'noncanonical_bytes', 'receipt_count', 'receipt_bytes_total')) {
        $jv = $null
        if ($jStat.PSObject.Properties.Name -contains $k) { $jv = $jStat.$k }
        $iv = $indep.$k
        if ("$jv" -cne "$iv") { Set-CaseFailure -Id $id @(('metric ' + $k + ': tool=' + $jv + ' indep=' + $iv)) }
    }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-029 no log + vocab + no network
# ---------------------------------------------------------------------------
function Test-AMT029 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-029'
    $decoy = 'DECOY_SECRET_TOKEN_7f3a9c'
    $init = Build-InitializedFixture -Root $Root
    if ($init.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op1 = New-Uuid
    $sp1 = New-CommitSpecX -Root $Root -Name 'draft_bam_029a.json' -Gen 1 -St $st -OpId $op1 -Ops @(New-AddOp -Subject '029 decoy' -Summary ('029 sum with ' + $decoy) -Provenance 'USER_STATED' -Tags $null -Note $decoy -Evidence $null -Pin $false -Supersedes $null)
    $r1 = Retry-Spec -Root $Root -Sp $sp1
    if ($r1.exit -ne 0) { Set-CaseFailure -Id $id @('add decoy failed'); return }
    $tree0 = Get-Manifest -Root $Root
    $out = Write-DeepOut -Root $Root -Name 'draft_bam_029_out.txt' -Text 'CAND:mem_0001|2026-10-07|029 subject|029 evidence ok|src.md' + "`n"
    $modes = @('Validate', 'Status', 'Recall', 'Commit', 'Forget', 'Restore', 'AbortPending', 'FilterDeepOut')
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opF = New-Uuid
    $spF = New-CommitSpecX -Root $Root -Name 'draft_bam_029f.json' -Gen $st2.gen -St $st2 -OpId $opF -Ops @(New-AddOpX -Subject '029 forgetme' -Summary '029 fm sum')
    $rForgetData = Retry-Spec -Root $Root -Sp $spF
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $opRest = New-Uuid
    $spRest = New-CommitSpecX -Root $Root -Name 'draft_bam_029r.json' -Gen $st3.gen -St $st3 -OpId $opRest -Ops @([pscustomobject]@{ op = 'restore'; record_id = 'mem_0002' })
    foreach ($mode in $modes) {
        $extra = @{}
        switch ($mode) {
            'Validate' { }
            'Status' { }
            'Recall' { $extra = @{ 'Query' = @('decoy'); 'Max' = @(5) } }
            'Commit' { $extra = @{ sp = $true; 'Spec' = @((New-CommitSpecX -Root $Root -Name ('draft_bam_029c_' + (New-Uuid).Substring(0,8) + '.json') -Gen (Get-ActiveStateHashes -MemRoot $a.mem).gen -St (Get-ActiveStateHashes -MemRoot $a.mem) -OpId (New-Uuid) -Ops @(New-AddOpX -Subject '029 mode c' -Summary '029 mc sum')).path) } }
            # RUNNER BUG FIX (resume session): the frozen 04 tool interface (line 141-144) is spec-driven for Forget (-Mode Forget -Spec <spec>); there is no -RecordId parameter. Passing -RecordId caused a PowerShell parameter-binding error (0 stdout, exit 1). The record is specified inside the spec (New-ForgetSpec -RecordId). Removed the undefined tool arg.
            'Forget' { $extra = @{ sp = $true; 'Spec' = @((Write-SpecFile -Root $Root -Name ('draft_bam_029fg_' + (New-Uuid).Substring(0,8) + '.json') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0002' -Expected (New-ExpectedBlock -Generation (Get-ActiveStateHashes -MemRoot $a.mem).gen -Core (Get-ActiveStateHashes -MemRoot $a.mem).core -Index (Get-ActiveStateHashes -MemRoot $a.mem).index -Archive (Get-ActiveStateHashes -MemRoot $a.mem).archive))).path) } }
            'Restore' { $extra = @{ sp = $true; 'Spec' = @((Write-SpecFile -Root $Root -Name ('draft_bam_029rs_' + (New-Uuid).Substring(0,8) + '.json') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0002' -Expected (New-ExpectedBlock -Generation (Get-ActiveStateHashes -MemRoot $a.mem).gen -Core (Get-ActiveStateHashes -MemRoot $a.mem).core -Index (Get-ActiveStateHashes -MemRoot $a.mem).index -Archive (Get-ActiveStateHashes -MemRoot $a.mem).archive))).path) } }
            'AbortPending' { }
            'FilterDeepOut' { $extra = @{ sp = $true; 'Out' = @($out) } }
        }
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode $mode -Extra $extra)
        if ($r.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @($mode + ' not one line'); continue }
        $j = Parse-JsonLine -Line $r.stdout_lines[0]
        if ($null -eq $j) { Set-CaseFailure -Id $id @($mode + ' invalid JSON'); continue }
        $diags = @()
        if ($null -ne $j.diagnostics) { $diags = @($j.diagnostics) }
        if (-not (Test-DiagVocabulary -Diags $diags)) { Set-CaseFailure -Id $id @($mode + ' diagnostics outside vocabulary') }
        if ($j.status -notin $script:StatusSet) { Set-CaseFailure -Id $id @($mode + ' status outside 8-set') }
    }
    $tree1 = Get-Manifest -Root $Root
    $newFiles = @()
    foreach ($k in $tree1.Keys) {
        if (-not $tree0.Contains($k)) { $newFiles += $k }
    }
    foreach ($nf in $newFiles) {
        $nl = $nf.ToLowerInvariant()
        if ($nl -like '*.log' -or $nl -like '*debug*' -or $nl -like '*trace*') {
            Set-CaseFailure -Id $id @('log file appeared: ' + $nf)
        }
    }
    $toolSrc = [System.IO.File]::ReadAllText($script:Tool, $script:Utf8NoBom)
    foreach ($bad in @('Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net.Http', 'Net.WebClient', 'Start-BitsTransfer')) {
        if ($toolSrc.IndexOf($bad, [System.StringComparison]::Ordinal) -ge 0) {
            Set-CaseFailure -Id $id @('network primitive in source: ' + $bad)
        }
    }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-033 PS 5.1 + no daemon + no DB
# ---------------------------------------------------------------------------
function Test-AMT033 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-033'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "($PSVersionTable.PSVersion.Major)"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $psVer = $p.StandardOutput.ReadToEnd().Trim()
    $null = $p.WaitForExit()
    if ($psVer -cne '5') { Set-CaseFailure -Id $id @(('PS major ' + $psVer + ' != 5')) }
    $init = Build-InitializedFixture -Root $Root
    if ($init.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $op1 = New-Uuid
    $sp1 = New-CommitSpecX -Root $Root -Name 'draft_bam_033.json' -Gen 1 -St $st -OpId $op1 -Ops @(New-AddOpX -Subject '033 test' -Summary '033 sum')
    $r1 = Retry-Spec -Root $Root -Sp $sp1
    if ($r1.exit -ne 0) { Set-CaseFailure -Id $id @('add failed'); return }
    $rRec = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('033'); 'Max' = @(5) })
    if ($rRec.exit -ne 0 -or $rRec.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('recall failed'); return }
    $jRec = Parse-JsonLine -Line $rRec.stdout_lines[0]
    if ($null -eq $jRec -or $jRec.status -cne 'HIT') { Set-CaseFailure -Id $id @('recall not HIT'); return }
    $rStat = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Status')
    if ($rStat.exit -ne 0 -or $rStat.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('status failed'); return }
    $jStat = Parse-JsonLine -Line $rStat.stdout_lines[0]
    if ($null -eq $jStat -or $jStat.status -cne 'PASS') { Set-CaseFailure -Id $id @('status not PASS'); return }
    $dbFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object { $_.Extension -in @('.db', '.sqlite', '.mdb') })
    if ($dbFiles.Count -gt 0) { Set-CaseFailure -Id $id @(('database file found: ' + $dbFiles[0].Name)) }
}

# ---------------------------------------------------------------------------
# Parent: AM-T-041 8 statuses + structured output (folds Group G)
# ---------------------------------------------------------------------------
function Test-AMT041 {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041'
    # (a) PASS: clean Validate
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41 base' -Summary '41 sum' -Provenance 'USER_STATED' -Note '41 NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $ra = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fa = @(Check-JsonContract -R $ra -ExpectedStatus 'PASS' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fa.Count -gt 0) { Set-CaseFailure -Id $id @('(a) ' + ($fa -join ' | ')) }
    # (b) HIT: Recall matching
    $rb = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('41'); 'Max' = @(5) })
    $fb = @(Check-JsonContract -R $rb -ExpectedStatus 'HIT' -ExpectedOp 'recall' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fb.Count -gt 0) { Set-CaseFailure -Id $id @('(b) ' + ($fb -join ' | ')) }
    # (c) MISS: Recall non-matching
    $rc = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('zzznonexistent'); 'Max' = @(5) })
    $fc = @(Check-JsonContract -R $rc -ExpectedStatus 'MISS' -ExpectedOp 'recall' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fc.Count -gt 0) { Set-CaseFailure -Id $id @('(c) ' + ($fc -join ' | ')) }
    # (d) INVALID: 65-char subject
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $longSubj = 'x' * 65
    $opD = New-Uuid
    $spD = New-CommitSpecX -Root $Root -Name 'draft_bam_41d.json' -Gen $st.gen -St $st -OpId $opD -Ops @(New-AddOp -Subject $longSubj -Summary '41 d sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
    $rd = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spD.path) })
    $fd = @(Check-JsonContract -R $rd -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fd.Count -gt 0) { Set-CaseFailure -Id $id @('(d) ' + ($fd -join ' | ')) }
    # (e) STALE: wrong expected generation
    $opE = New-Uuid
    $spE = New-CommitSpecX -Root $Root -Name 'draft_bam_41e.json' -Gen 99 -St $st -OpId $opE -Ops @(New-AddOpX -Subject '41 e rec' -Summary '41 e sum')
    $re = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spE.path) })
    $fe = @(Check-JsonContract -R $re -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fe.Count -gt 0) { Set-CaseFailure -Id $id @('(e) ' + ($fe -join ' | ')) }
    # (f) UNVERIFIED: corrupt a note byte
    $gen2dir = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $noteDir = Join-Path $gen2dir 'notes'
    $noteFiles = @(Get-ChildItem -LiteralPath $noteDir -File -Force -ErrorAction SilentlyContinue)
    if ($noteFiles.Count -gt 0) {
        $nf = $noteFiles[0].FullName
        $nb = Read-FileBytes -Path $nf
        if ($nb.Length -gt 0) { $nb[0] = ($nb[0] -bxor 0xFF) }
        Write-FileBytes -Path $nf -Bytes $nb
    }
    $rf = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $ff = @(Check-JsonContract -R $rf -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($ff.Count -gt 0) { Set-CaseFailure -Id $id @('(f) ' + ($ff -join ' | ')) }
    # Rebuild fixture for (g) and (h)
    $rootB = (Join-Path $Root 'alt41')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $g2b = Build-Gen2Fixture -Root $rootB -Subject '41b base' -Summary '41b sum' -Provenance 'USER_STATED' -Note '41B NOTE' -Evidence $null
    if ($g2b.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture B build failed'); return }
    $ab = Get-CaseRootArgs -Root $rootB
    # (g) BLOCKED: -MemoryRoot outside allowed roots
    $rG = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', (Join-Path $Root 'memory-elsewhere'), '-WorkspaceRoot', (Join-Path $rootB 'workspace'), '-ScratchpadRoot', (Join-Path $rootB 'scratchpad'), '-Spec', (Join-Path (Join-Path $rootB 'scratchpad') 'draft_bam_41g.json'))
    # Write a valid spec first for the blocked test
    $stb = Get-ActiveStateHashes -MemRoot $ab.mem
    $opG = New-Uuid
    $spG = New-CommitSpecX -Root $rootB -Name 'draft_bam_41g.json' -Gen $stb.gen -St $stb -OpId $opG -Ops @(New-AddOpX -Subject '41 g rec' -Summary '41 g sum')
    $rG2 = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', (Join-Path $Root 'memory-elsewhere'), '-WorkspaceRoot', (Join-Path $rootB 'workspace'), '-ScratchpadRoot', (Join-Path $rootB 'scratchpad'), '-Spec', $spG.path)
    $fg = @(Check-JsonContract -R $rG2 -ExpectedStatus 'BLOCKED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($fg.Count -gt 0) { Set-CaseFailure -Id $id @('(g) ' + ($fg -join ' | ')) }
    # (h) FAILED: fault before CURRENT switch
    $stb2 = Get-ActiveStateHashes -MemRoot $ab.mem
    $opH = New-Uuid
    $spH = New-CommitSpecX -Root $rootB -Name 'draft_bam_41h.json' -Gen $stb2.gen -St $stb2 -OpId $opH -Ops @(New-AddOpX -Subject '41 h rec' -Summary '41 h sum')
    $rh = Fault-Commit -Root $rootB -Sp $spH -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    $fh = @(Check-JsonContract -R $rh -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('staged_verify_failed') -ExpectedExit 1)
    if ($fh.Count -gt 0) { Set-CaseFailure -Id $id @('(h) ' + ($fh -join ' | ')) }
    # (041.b) one-line JSON verified by Check-JsonContract above
    # (041.f) exit mapping verified above
    # (041.g) decoy scan
    $rootC = (Join-Path $Root 'alt41c')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootC 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootC 'scratchpad')) | Out-Null
    $decoy = 'DECOY_SECRET_TOKEN_7f3a9c'
    $g2c = Build-Gen2Fixture -Root $rootC -Subject '41c base' -Summary '41c sum' -Provenance 'USER_STATED' -Note $decoy -Evidence $null
    if ($g2c.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture C build failed'); return }
    $ac = Get-CaseRootArgs -Root $rootC
    $modes41 = @('Validate', 'Status', 'Recall')
    foreach ($mode in $modes41) {
        $extra = @{}
        if ($mode -eq 'Recall') { $extra = @{ 'Query' = @('41c'); 'Max' = @(5) } }
        $r41 = Invoke-Tool -Args (Tool-Args -Root $rootC -Mode $mode -Extra $extra)
        if ($r41.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(g) ' + $mode + ' not one line'); continue }
        $j41 = Parse-JsonLine -Line $r41.stdout_lines[0]
        if ($null -eq $j41) { continue }
        $diags41 = @()
        if ($null -ne $j41.diagnostics) { $diags41 = @($j41.diagnostics) }
        foreach ($d in $diags41) {
            if ([string]$d -like '*DECOY*' -or [string]$d -like '*7f3a9c*') { Set-CaseFailure -Id $id @('(g) decoy in diagnostics: ' + $d) }
        }
    }
}


# ---------------------------------------------------------------------------
# Sub-cases (frozen 04): AM-T-002.a-i, AM-T-003.a-g, AM-T-005.a-g, AM-T-028.a-c, AM-T-041.a-g
# ---------------------------------------------------------------------------
function Test-AMT002A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.a'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002a base' -Summary '002a base sum' -Provenance 'USER_STATED' -Note '002A NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    Flip-ByteAt -Path (Join-Path $gen2 'core.md') -Idx ([math]::Min(20, (Read-FileBytes -Path (Join-Path $gen2 'core.md')).Length - 1)) -Val 65
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.b'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002b base' -Summary '002b base sum' -Provenance 'USER_STATED' -Note '002B NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $ib = Read-FileBytes -Path (Join-Path $gen2 'index.md')
    Flip-ByteAt -Path (Join-Path $gen2 'index.md') -Idx ([math]::Min(24, $ib.Length - 1)) -Val 65
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002c base' -Summary '002c base sum' -Provenance 'USER_STATED' -Note '002C NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $ab = Read-FileBytes -Path (Join-Path $gen2 'archive.md')
    Flip-ByteAt -Path (Join-Path $gen2 'archive.md') -Idx ([math]::Min(20, $ab.Length - 1)) -Val 65
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.d'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002d base' -Summary '002d base sum' -Provenance 'USER_STATED' -Note '002D NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    Flip-ByteAt -Path (Join-Path (Join-Path $gen2 'notes') 'mem_0001.md') -Idx 0 -Val 65
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.e'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002e base' -Summary '002e base sum' -Provenance 'USER_STATED' -Note '002E NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    Write-FileUtf8 -Path (Join-Path (Join-Path $gen2 'notes') 'mem_9999.md') -Text 'UNLISTED NOTE FILE body'
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.f'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002f base' -Summary '002f base sum' -Provenance 'USER_STATED' -Note '002F NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    [System.IO.File]::Delete((Join-Path (Join-Path $gen2 'notes') 'mem_0001.md'))
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.g'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002g base' -Summary '002g base sum' -Provenance 'USER_STATED' -Note '002G NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $cp = Join-Path $gen2 'core.md'
    $cb = Read-FileBytes -Path $cp
    $cb2 = New-Object byte[] ($cb.Length + 1)
    $insPos = [Math]::Min(1, $cb.Length - 1); if ($insPos -lt 0) { $insPos = 0 }
    [Array]::Copy($cb, 0, $cb2, 0, $insPos)
    $cb2[$insPos] = 0xFF
    [Array]::Copy($cb, $insPos, $cb2, ($insPos + 1), ($cb.Length - $insPos))
    Write-FileBytes -Path $cp -Bytes $cb2
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002H {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.h'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '002h base' -Summary '002h base sum' -Provenance 'USER_STATED' -Note '002H NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $gen2 = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $ip = Join-Path $gen2 'index.md'
    $ib = Read-FileBytes -Path $ip
    $ib2 = New-Object byte[] ($ib.Length + 3)
    $ib2[0] = 0xEF; $ib2[1] = 0xBB; $ib2[2] = 0xBF
    [Array]::Copy($ib, 0, $ib2, 3, $ib.Length)
    Write-FileBytes -Path $ip -Bytes $ib2
    $m0 = Get-Manifest -Root $a.mem
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'UNVERIFIED' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT002I {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-002.i'
    $g2 = Build-Gen2Fixture -Root $Root -Subject 'gei base' -Summary 'gei base sum' -Provenance 'USER_STATED' -Note '002I NOTE BODY' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $res = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 2 -Core (Get-ActiveStateHashes -MemRoot $a.mem).core -Index (Get-ActiveStateHashes -MemRoot $a.mem).index -Archive (Get-ActiveStateHashes -MemRoot $a.mem).archive) -Ops @(New-AddOp -Subject 'gei second' -Summary 'gei second sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)) -ExpGen 3 -ExpRecords @('mem_0002')
    if (-not $res.ok) { return }
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'gei' -ExpStatus 'HIT' -ExpMax 0
    if ($null -ne $rr.j) { Assert-Candidates -Id $id -J $rr.j -ExpectedIds @('mem_0001', 'mem_0002') }
}

function Test-AMT003A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.a'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    Write-FileUtf8 -Path (Join-Path $Root 'outside.md') -Text 'OUTSIDE EVIDENCE for AM-T-003a'
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'workspace\..\outside.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003a.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.b'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $tgt = Join-Path $Root 'tgt'
    [System.IO.Directory]::CreateDirectory($tgt) | Out-Null
    Write-FileUtf8 -Path (Join-Path $tgt 'target.md') -Text 'JUNCTION TARGET for AM-T-003b'
    $hBefore = (Get-FileHash -LiteralPath (Join-Path $tgt 'target.md') -Algorithm SHA256).Hash
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = ('/c mklink /J "{0}" "{1}"' -f (Join-Path $a.ws 'evj'), $tgt)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $jp = New-Object System.Diagnostics.Process; $jp.StartInfo = $psi; $null = $jp.Start(); $null = $jp.WaitForExit(10000)
    if (-not (Test-Path -LiteralPath (Join-Path $a.ws 'evj'))) { Set-CaseFailure -Id $id @('junction creation failed'); return }
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'evj\target.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003b.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    $hAfter = (Get-FileHash -LiteralPath (Join-Path $tgt 'target.md') -Algorithm SHA256).Hash
    if ($hAfter -cne $hBefore) { Set-CaseFailure -Id $id @('junction target modified') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.c'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'C:\bamtest\outside.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003c.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.d'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    [System.IO.Directory]::CreateDirectory((Join-Path $a.ws 'sub')) | Out-Null
    Write-FileUtf8 -Path (Join-Path $Root 'outside2.md') -Text 'OUTSIDE EVIDENCE for AM-T-003d'
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'sub\..\..\outside2.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003d.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.e'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'D:\bamtest\ev.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003e.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-003.f'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $m0 = Get-Manifest -Root $a.mem
    $midout = Join-Path $Root 'midout'
    [System.IO.Directory]::CreateDirectory((Join-Path $midout 'sub')) | Out-Null
    Write-FileUtf8 -Path (Join-Path (Join-Path $midout 'sub') 'real.md') -Text 'JUNCTION MID TARGET for AM-T-003f'
    $hBefore = (Get-FileHash -LiteralPath (Join-Path (Join-Path $midout 'sub') 'real.md') -Algorithm SHA256).Hash
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = ('/c mklink /J "{0}" "{1}"' -f (Join-Path $a.ws 'midj'), $midout)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $jp = New-Object System.Diagnostics.Process; $jp.StartInfo = $psi; $null = $jp.Start(); $null = $jp.WaitForExit(10000)
    if (-not (Test-Path -LiteralPath (Join-Path $a.ws 'midj'))) { Set-CaseFailure -Id $id @('junction creation failed'); return }
    $op = New-AddOp -Subject 'esc subj' -Summary 'esc sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'midj\sub\real.md' -Pin $null -Supersedes $null
    $spec = New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation 1 -Core $st.core -Index $st.index -Archive $st.archive) -Ops @($op)
    $sp = Write-SpecFile -Root $Root -Name 'draft_bam_spec_003f.json' -SpecObj $spec
    $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path) })
    $f = @(Check-JsonContract -R $r -ExpectedStatus 'INVALID' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    $hAfter = (Get-FileHash -LiteralPath (Join-Path (Join-Path $midout 'sub') 'real.md') -Algorithm SHA256).Hash
    if ($hAfter -cne $hBefore) { Set-CaseFailure -Id $id @('junction target modified') }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT003G {
    param([string]$Root)
    $id = 'AM-T-003.g'
    # 003.g = documentation-correspondence test (04 Group H, 2026-10-12 amendment).
    # It verifies that canonical 01 carries the user-accepted residual-risk
    # statements (D2.8 addendum) AND that 003.f actually executed and PASSed.
    # 003.g run alone must still secure 003.f evidence, so it executes 003.f
    # internally. A self-generated constant is never used as evidence, and
    # 003.g is NOT evidence that dynamic TOCTOU races are prevented.
    Register-Case -Id 'AM-T-003.f'
    Test-AMT003F -Root $Root
    $fRes = $script:Results['AM-T-003.f']
    if ($fRes.status -eq 'NOT_RUN') { $fRes.status = 'PASS' }
    if ($fRes.status -ne 'PASS') {
        Set-CaseFailure -Id $id @('003.f did not PASS; documentation cannot substitute for 003.f evidence')
        return
    }
    $docPath = Join-Path $script:DraftDir '01_CANONICAL_NORMATIVE_SPECIFICATION.md'
    if (-not (Test-Path -LiteralPath $docPath)) { Set-CaseFailure -Id $id @('01 authority absent'); return }
    $docSha = (Get-FileHash -LiteralPath $docPath -Algorithm SHA256).Hash
    $docTxt = [System.IO.File]::ReadAllText($docPath, $script:Utf8NoBom)
    $markers = @(
        'Path-safety guarantee scope and accepted residual risk',
        'NO guarantee of complete prevention of check-then-use replacement races',
        'trusted single-user local environment',
        'permits no omission, weakening, or bypass',
        'NOT a safety proof'
    )
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($mk in $markers) {
        if ($docTxt.IndexOf($mk, [System.StringComparison]::Ordinal) -lt 0) { $missing.Add($mk) }
    }
    if ($missing.Count -gt 0) { Set-CaseFailure -Id $id @('01 missing required statement: ' + ($missing -join ' ;; ')) }
    $ev = 'doc_path=' + $docPath + "`n"
    $ev += 'doc_sha256=' + $docSha + "`n"
    $ev += '003_f_executed=yes' + "`n"
    $ev += '003_f_status=PASS' + "`n"
    $ev += 'scope=003.g verifies the 01 documentation and the 003.f component check; NOT evidence of dynamic race prevention'
    $null = Write-DeepOut -Root $Root -Name 'bam_t003g_doccheck.txt' -Text $ev
    [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'bam_t003g_doccheck_latest.txt'), $ev, $script:Utf8NoBom)
}

function Test-AMT005A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.a'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $rr = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rr.j) { Set-CaseFailure -Id $id @('recall no json'); return }
    $cands = @($rr.j.candidates)
    if ($cands.Count -ne 1) { Set-CaseFailure -Id $id @('candidate count != 1'); return }
    if ([string]$cands[0].record_id -cne 'mem_0001') { Set-CaseFailure -Id $id @('candidate is not mem_0001') }
    if ([string]$cands[0].evidence_status -cne 'ok') { Set-CaseFailure -Id $id @('evidence_status != ok') }
}

function Test-AMT005B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.b'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $stNow = Get-ActiveStateHashes -MemRoot $a.mem
    $mD = Get-Manifest -Root $a.mem
    $opD = New-AddOp -Subject 'mv missing ev' -Summary 'mv missing ev sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'evidence/absent-file.md' -Pin $null -Supersedes $null
    $null = Commit-ExpectInvalid -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive) -Ops @($opD)) -DiagContains @()
    Assert-ManifestUnchanged -Id $id -Before $mD -After (Get-Manifest -Root $a.mem)
}

function Test-AMT005C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.c'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $stNow = Get-ActiveStateHashes -MemRoot $a.mem
    $resD1 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stNow.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive))
    if (-not $resD1.ok) { return }
    $stD1 = Get-ActiveStateHashes -MemRoot $a.mem
    $resD2 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Restore' -ExpGen ($stD1.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stD1.gen -Core $stD1.core -Index $stD1.index -Archive $stD1.archive))
    if (-not $resD2.ok) { return }
    $lineD = ''
    foreach ($lnD in @(Get-ArchiveLines -MemRoot $a.mem -Gen $stD1.gen)) {
        $pD = @($lnD -split '\|', 3)
        if ($pD.Count -eq 3 -and $pD[2].StartsWith('mem_0001|')) { $lineD = $pD[2]; break }
    }
    if ($lineD -eq '') { Set-CaseFailure -Id $id @('forgotten line not found in archive'); return }
    $lineD2 = Get-RecordLineOf -MemRoot $a.mem -Gen ($stD1.gen + 1) -Id 'mem_0001'
    $fd1 = Get-RecordLineFields -Line $lineD
    $fd2 = Get-RecordLineFields -Line $lineD2
    if ($null -eq $fd1 -or $null -eq $fd2) { Set-CaseFailure -Id $id @('record line unparseable'); return }
    if ($fd1[0] -cne $fd2[0] -or $fd1[1] -cne $fd2[1]) { Set-CaseFailure -Id $id @('identity changed on restore') }
    $nbD = Get-GenNoteBytes -MemRoot $a.mem -Gen ($stD1.gen + 1) -Id 'mem_0001'
    if ($null -eq $nbD -or (Get-Sha256Hex -Bytes $nbD) -cne (Get-TextSha256Hex -Text 'NOTE BODY alpha deterministic content N1')) { Set-CaseFailure -Id $id @('note not intact after restore') }
}

function Test-AMT005D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.d'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $evDir = Join-Path $a.ws 'evidence'
    $stNow = Get-ActiveStateHashes -MemRoot $a.mem
    $resD1 = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stNow.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive))
    if (-not $resD1.ok) { return }
    [System.IO.File]::Delete((Join-Path $evDir 'fact1.md'))
    $stD3 = Get-ActiveStateHashes -MemRoot $a.mem
    $mD3 = Get-Manifest -Root $a.mem
    $null = ForgetRestore-ExpectInvalid -Id $id -Root $Root -Mode 'Restore' -DiagContains @('restore_source_missing') -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stD3.gen -Core $stD3.core -Index $stD3.index -Archive $stD3.archive))
    Assert-ManifestUnchanged -Id $id -Before $mD3 -After (Get-Manifest -Root $a.mem)
    $lineD = ''
    foreach ($lnD in @(Get-ArchiveLines -MemRoot $a.mem -Gen ($stNow.gen + 1))) {
        $pD = @($lnD -split '\|', 3)
        if ($pD.Count -eq 3 -and $pD[2].StartsWith('mem_0001|')) { $lineD = $pD[2]; break }
    }
    if ($lineD -eq '') { Set-CaseFailure -Id $id @('archive line not found after forget') }
}

function Test-AMT005E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.e'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $evDir = Join-Path $a.ws 'evidence'
    [System.IO.File]::Delete((Join-Path $evDir 'fact1.md'))
    $mD5 = Get-Manifest -Root $a.mem
    $rrE = Invoke-RecallExpect -Id $id -Root $Root -Query 'alpha' -ExpStatus 'HIT' -ExpMax 0
    if ($null -eq $rrE.j) { Set-CaseFailure -Id $id @('recall no json'); return }
    $cE = @($rrE.j.candidates)
    if ($cE.Count -ne 1 -or [string]$cE[0].record_id -cne 'mem_0001') { Set-CaseFailure -Id $id @('recall candidate set wrong') }
    if ([string]$cE[0].evidence_status -cne 'dangling') { Set-CaseFailure -Id $id @('evidence_status != dangling') }
    $diagsE = @($rrE.j.diagnostics)
    if ($diagsE -notcontains 'dangling_evidence') { Set-CaseFailure -Id $id @('diagnostics missing dangling_evidence') }
    Assert-ManifestUnchanged -Id $id -Before $mD5 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT005F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.f'
    $g2 = Build-Gen2EvidenceFixture -Root $Root
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $evDir = Join-Path $a.ws 'evidence'
    [System.IO.File]::Delete((Join-Path $evDir 'fact1.md'))
    $stNow = Get-ActiveStateHashes -MemRoot $a.mem
    $resFx = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-PinSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stNow.gen -Core $stNow.core -Index $stNow.index -Archive $stNow.archive) -OpType 'pin') -ExpGen ($stNow.gen + 1) -ExpRecords @('mem_0001')
    if (-not $resFx.ok) { return }
    $stF1 = Get-ActiveStateHashes -MemRoot $a.mem
    $resFx = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-PinSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stF1.gen -Core $stF1.core -Index $stF1.index -Archive $stF1.archive) -OpType 'unpin') -ExpGen ($stF1.gen + 1) -ExpRecords @('mem_0001')
    if (-not $resFx.ok) { return }
    $stF2 = Get-ActiveStateHashes -MemRoot $a.mem
    $resFx = ForgetRestore-ExpectPass -Id $id -Root $Root -Mode 'Forget' -ExpGen ($stF2.gen + 1) -ExpRecords @('mem_0001') -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $stF2.gen -Core $stF2.core -Index $stF2.index -Archive $stF2.archive))
    if (-not $resFx.ok) { return }
    $stF3 = Get-ActiveStateHashes -MemRoot $a.mem
    $resFx = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stF3.gen -Core $stF3.core -Index $stF3.index -Archive $stF3.archive) -Ops @(New-AddOp -Subject 'unrelated new' -Summary 'unrelated new sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)) -ExpGen ($stF3.gen + 1) -ExpRecords @('mem_0002')
    if (-not $resFx.ok) { return }
}

function Test-AMT005G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-005.g'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $evDir = Join-Path $a.ws 'evidence'
    [System.IO.Directory]::CreateDirectory($evDir) | Out-Null
    Write-FileUtf8 -Path (Join-Path $evDir 'fact3.md') -Text 'DETERMINISTIC EVIDENCE FACT 3'
    $stG = Get-ActiveStateHashes -MemRoot $a.mem
    $opG1 = New-AddOp -Subject 'tri both pointers' -Summary 'tri both pointers sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note 'TRI NOTE BODY one' -Evidence 'evidence/fact3.md' -Pin $null -Supersedes $null
    $opG2 = New-AddOp -Subject 'tri note only' -Summary 'tri note only sum' -Provenance 'USER_STATED' -Tags $null -Note 'TRI NOTE BODY two' -Evidence $null -Pin $null -Supersedes $null
    $opG3 = New-AddOp -Subject 'tri source only' -Summary 'tri source only sum' -Provenance 'MACHINE_VERIFIED' -Tags $null -Note $null -Evidence 'evidence/fact3.md' -Pin $null -Supersedes $null
    $resG = Commit-ExpectPass -Id $id -Root $Root -SpecObj (New-CommitSpec -OpId (New-Uuid) -Expected (New-ExpectedBlock -Generation $stG.gen -Core $stG.core -Index $stG.index -Archive $stG.archive) -Ops @($opG1, $opG2, $opG3)) -ExpGen 2 -ExpRecords @('mem_0001', 'mem_0002', 'mem_0003')
    if (-not $resG.ok) { return }
    $flG1 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0001')
    $flG2 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0002')
    $flG3 = Get-RecordLineFields -Line (Get-RecordLineOf -MemRoot $a.mem -Gen 2 -Id 'mem_0003')
    if ($null -eq $flG1 -or $null -eq $flG2 -or $null -eq $flG3) { Set-CaseFailure -Id $id @('record line unparseable'); return }
    if ($flG1[5] -cne 'evidence/fact3.md' -or $flG1[6] -cne 'notes/mem_0001.md') { Set-CaseFailure -Id $id @('record 1 pointers wrong') }
    if ($flG2[5] -cne '-' -or $flG2[6] -cne 'notes/mem_0002.md') { Set-CaseFailure -Id $id @('record 2 pointers wrong') }
    if ($flG3[5] -cne 'evidence/fact3.md' -or $flG3[6] -cne '-') { Set-CaseFailure -Id $id @('record 3 pointers wrong') }
    $stateG = Get-StateTextOf -MemRoot $a.mem -Gen 2
    if ($stateG -notmatch 'NOTE_SHA256=mem_0001:') { Set-CaseFailure -Id $id @('STATE missing note line for record 1') }
    if ($stateG -notmatch 'NOTE_SHA256=mem_0002:') { Set-CaseFailure -Id $id @('STATE missing note line for record 2') }
    if ($stateG -match 'NOTE_SHA256=mem_0003:') { Set-CaseFailure -Id $id @('STATE lists note for record 3') }
}

function Test-AMT028A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-028.a'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    for ($i = 1; $i -le 5; $i++) {
        $st = Get-ActiveStateHashes -MemRoot $a.mem
        $sp = New-CommitSpecX -Root $Root -Name ('draft_bam_028a' + $i + '.json') -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject ('028a rec' + $i) -Summary ('028a sum' + $i))
        $r = Retry-Spec -Root $Root -Sp $sp
        if ($r.exit -ne 0) { Set-CaseFailure -Id $id @(('commit ' + $i + ' failed exit=' + $r.exit)); return }
    }
    $gens = @(Get-GenList -MemRoot $a.mem)
    if ($gens.Count -ne 6) { Set-CaseFailure -Id $id @(('gen count ' + $gens.Count + ' != 6')); return }
    for ($i = 1; $i -le 6; $i++) {
        $gn = ('{0:000000}' -f $i)
        if ($gens -notcontains $gn) { Set-CaseFailure -Id $id @(('gen dir missing: ' + $gn)) }
    }
}

# AM-T-028.b Plan C (2026-10-12 amendment): seeded synthetic archive fixture.
# Build-SeededArchiveGen1 rewrites generation 1 archive.md with N seeded
# 'evicted' record lines (a documented fixture-seed amendment, NOT a tool
# commit), creates genuine evidence files for every MACHINE_VERIFIED
# source_pointer, and re-derives gen1 STATE (ARCHIVE_SHA256/ARCHIVE_BYTES),
# ACTIVE and CURRENT (STATE_SHA256) from the actually written bytes.
# SYNTHETIC FIXTURE: the seeded state is NOT evidence of real commit history.
function Pad-To {
    param([string]$Base, [int]$Len)
    if ($Base.Length -ge $Len) { return $Base.Substring(0, $Len) }
    return ($Base + ('a' * ($Len - $Base.Length)))
}

function Build-SeededArchiveGen1 {
    param([string]$Root, [int]$Count = 9700)
    $mem = Join-Path (Join-Path $Root 'workspace') 'memory'
    $g1 = Join-Path (Join-Path $mem '.gen') '000001'
    $archivePath = Join-Path $g1 'archive.md'
    $statePath = Join-Path $g1 'STATE'
    $activePath = Join-Path $mem 'ACTIVE'
    $currentPath = Join-Path $mem 'CURRENT'
    foreach ($p in @($archivePath, $statePath, $activePath, $currentPath)) {
        if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; err = @('seed: missing ' + $p) } }
    }
    # 1) genuine evidence files (one per seeded record; MACHINE_VERIFIED rule)
    $evDir = Join-Path (Join-Path $Root 'workspace') 'evidence\seed'
    [System.IO.Directory]::CreateDirectory($evDir) | Out-Null
    for ($i = 1; $i -le $Count; $i++) {
        $evName = ('f{0:000000}.md' -f $i)
        Write-FileUtf8 -Path (Join-Path $evDir $evName) -Text (('SEED EVIDENCE {0:000000} (synthetic fixture content)' -f $i) + "`n")
    }
    # 2) archive.md: header + Count seeded evicted lines; every field at/within
    #    01 legal limits (subject 64, tags 4x32, summary 256, provenance 16,
    #    source 24, date 10; no padding beyond legal caps). 546 bytes per line.
    $date = '2026-10-12'
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('# memory-archive v1' + "`n")
    for ($i = 1; $i -le $Count; $i++) {
        $recId = ('mem_{0:0000}' -f $i)
        $subj = Pad-To -Base ('028b seeded archive record subject ' + $i) -Len 64
        $tag1 = Pad-To -Base ('seed-tag-a-{0:000000}' -f $i) -Len 32
        $tag2 = Pad-To -Base ('seed-tag-b-{0:000000}' -f $i) -Len 32
        $tag3 = Pad-To -Base ('seed-tag-c-{0:000000}' -f $i) -Len 32
        $tag4 = Pad-To -Base ('seed-tag-d-{0:000000}' -f $i) -Len 32
        $src = ('evidence/seed/f{0:000000}.md' -f $i)
        $summ = Pad-To -Base ('028b seeded archive record summary filler ' + $i + ' deterministic synthetic content') -Len 256
        $null = $sb.Append($date + '|evicted|' + $recId + '|' + $date + '|' + $subj + '|' + $tag1 + ';' + $tag2 + ';' + $tag3 + ';' + $tag4 + '|MACHINE_VERIFIED|' + $src + '|-|active|-|' + $summ + "`n")
    }
    $archiveBytes = $script:Utf8NoBom.GetBytes($sb.ToString())
    Write-FileBytes -Path $archivePath -Bytes $archiveBytes
    # 3) re-derive gen1 STATE from written bytes (swap ARCHIVE_SHA256/ARCHIVE_BYTES only)
    $stateText = [System.IO.File]::ReadAllText($statePath, $script:Utf8NoBom)
    $stateLines = @($stateText -split "`n")
    $swapped = 0
    for ($li = 0; $li -lt $stateLines.Count; $li++) {
        if ($stateLines[$li] -like 'ARCHIVE_SHA256=*') { $stateLines[$li] = 'ARCHIVE_SHA256=' + (Get-Sha256Hex -Bytes $archiveBytes); $swapped++ }
        elseif ($stateLines[$li] -like 'ARCHIVE_BYTES=*') { $stateLines[$li] = 'ARCHIVE_BYTES=' + $archiveBytes.Length; $swapped++ }
    }
    if ($swapped -ne 2) { return @{ ok = $false; err = @('seed: STATE swap count ' + $swapped) } }
    $newStateText = ($stateLines -join "`n")
    $newStateSha = Get-TextSha256Hex -Text $newStateText
    Write-FileUtf8 -Path $statePath -Text $newStateText
    # 4) ACTIVE (7-line receipt) + CURRENT (4-line writer): STATE_SHA256 line only
    $ptrSpecs = @(@{ p = $activePath; want = 7 }, @{ p = $currentPath; want = 4 })
    foreach ($ptr in $ptrSpecs) {
        $txt = [System.IO.File]::ReadAllText($ptr.p, $script:Utf8NoBom)
        $lines = @($txt -split "`n")
        if ($lines.Count -ge 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
        if ($lines.Count -ne $ptr.want) { return @{ ok = $false; err = @('seed: line count ' + $lines.Count + ' for ' + $ptr.p) } }
        $done = $false
        for ($li = 0; $li -lt $lines.Count; $li++) {
            if ($lines[$li] -like 'STATE_SHA256=*') { $lines[$li] = 'STATE_SHA256=' + $newStateSha; $done = $true }
        }
        if (-not $done) { return @{ ok = $false; err = @('seed: STATE_SHA256 line missing in ' + $ptr.p) } }
        Write-FileUtf8 -Path $ptr.p -Text (($lines -join "`n") + "`n")
    }
    # receipts\ left as-is (empty after initialize); the next normal commit
    # archives the seeded gen1 ACTIVE receipt via the normal step-16 path.
    return @{ ok = $true; archiveBytes = $archiveBytes.Length; archiveSha = (Get-Sha256Hex -Bytes $archiveBytes); stateSha = $newStateSha }
}

function Test-AMT028B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-028.b'
    # Plan C (2026-10-12 amendment): synthetic seeded archive (~5 MiB) + 4 normal
    # 16-op commits with 32 KB notes (final-gen notes ~2 MiB). Pre-committed size
    # bands (07, recorded before probe): final-gen notes [1.8,2.2] MiB, final-gen
    # archive [4.5,5.5] MiB (04 'about' concretized as +/-10%).
    # SYNTHETIC FIXTURE: seeded archive state is not real commit-history evidence.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    $seed = Build-SeededArchiveGen1 -Root $Root
    if (-not $seed.ok) { Set-CaseFailure -Id $id @('seed: ' + ($seed.err -join ' | ')); return }
    $rV = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    $fV = @(Check-JsonContract -R $rV -ExpectedStatus 'PASS' -ExpectedOp 'validate' -ExpectedRecords @() -ExpectedDiagContains @() -ExpectedExit 0)
    if ($fV.Count -gt 0) { Set-CaseFailure -Id $id @('post-seed Validate: ' + ($fV -join ' | ')); return }
    $noteBig = New-NoteFiller -Bytes 32768
    for ($s = 1; $s -le 4; $s++) {
        $stS = Get-ActiveStateHashes -MemRoot $a.mem
        $opsS = @()
        for ($i = 1; $i -le 16; $i++) {
            $opsS += New-AddOp -Subject ('028b n' + $s + '-' + $i) -Summary ('028b sum n' + $s + '-' + $i) -Provenance 'USER_STATED' -Tags $null -Note $noteBig -Evidence $null -Pin $null -Supersedes $null
        }
        $spS = New-CommitSpecX -Root $Root -Name ('draft_bam_028b_' + $s + '.json') -Gen $stS.gen -St $stS -OpId (New-Uuid) -Ops $opsS
        $rS = Retry-Spec -Root $Root -Sp $spS
        if ($rS.exit -ne 0) { Set-CaseFailure -Id $id @(('commit ' + $s + ' failed exit=' + $rS.exit)); return }
    }
    $stF = Get-ActiveStateHashes -MemRoot $a.mem
    if ($stF.gen -ne 5) { Set-CaseFailure -Id $id @(('gen ' + $stF.gen + ' != 5')); return }
    # seeded IDs honored by allocation: real adds are mem_9701..mem_9764
    if ((Get-RecordLineOf -MemRoot $a.mem -Gen 5 -Id 'mem_9701') -eq '') { Set-CaseFailure -Id $id @('mem_9701 missing in gen5 (seeded ID allocation not honored)') }
    if ((Get-RecordLineOf -MemRoot $a.mem -Gen 5 -Id 'mem_9764') -eq '') { Set-CaseFailure -Id $id @('mem_9764 missing in gen5 (64 adds not all present)') }
    $rStat = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Status')
    if ($rStat.exit -ne 0 -or $rStat.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('Status failed'); return }
    $jStat = Parse-JsonLine -Line $rStat.stdout_lines[0]
    if ($null -eq $jStat -or $jStat.status -cne 'PASS') { Set-CaseFailure -Id $id @('Status not PASS'); return }
    $indep = Measure-StatusMetricsIndependent -MemRoot $a.mem
    foreach ($k in @('generation_count', 'completed_bytes_total', 'active_generation_bytes', 'largest_generation_bytes', 'noncanonical_bytes', 'receipt_count', 'receipt_bytes_total')) {
        $jv = $null
        if ($jStat.PSObject.Properties.Name -contains $k) { $jv = $jStat.$k }
        $iv = $indep.$k
        if ("$jv" -cne "$iv") { Set-CaseFailure -Id $id @(('metric ' + $k + ': tool=' + $jv + ' indep=' + $iv)) }
    }
    $gen5 = Get-GenDirOf -MemRoot $a.mem -Gen 5
    $notesBytes = Get-DirBytes -Path (Join-Path $gen5 'notes')
    $archiveBytes = (Read-FileBytes -Path (Join-Path $gen5 'archive.md')).Length
    $notesMiB = [double]$notesBytes / 1048576
    $archiveMiB = [double]$archiveBytes / 1048576
    if ($notesMiB -lt 1.8 -or $notesMiB -gt 2.2) { Set-CaseFailure -Id $id @(('final-gen notes ' + [math]::Round($notesMiB, 4) + ' MiB outside pre-committed band [1.8,2.2] MiB')) }
    if ($archiveMiB -lt 4.5 -or $archiveMiB -gt 5.5) { Set-CaseFailure -Id $id @(('final-gen archive ' + [math]::Round($archiveMiB, 4) + ' MiB outside pre-committed band [4.5,5.5] MiB')) }
    $sw.Stop()
    $null = Write-DeepOut -Root $Root -Name 'bam_t028b_sizes.txt' -Text ('fixture=synthetic_seeded_archive' + "`n" + 'active_gen=5' + "`n" + 'notes_bytes=' + $notesBytes + "`n" + 'archive_bytes=' + $archiveBytes + "`n" + 'notes_mib=' + [math]::Round($notesMiB, 6) + "`n" + 'archive_mib=' + [math]::Round($archiveMiB, 6) + "`n" + 'completed_bytes_total=' + $indep.completed_bytes_total + "`n" + 'case_wall_ms=' + $sw.ElapsedMilliseconds + "`n")
}

function Test-AMT028C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-028.c'
    $base = Build-InitializedFixture -Root $Root
    if ($base.r.exit -ne 0) { Set-CaseFailure -Id $id @('init failed'); return }
    for ($i = 1; $i -le 3; $i++) {
        $st = Get-ActiveStateHashes -MemRoot $a.mem
        $sp = New-CommitSpecX -Root $Root -Name ('draft_bam_028c' + $i + '.json') -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject ('028c rec' + $i) -Summary ('028c sum' + $i))
        $r = Retry-Spec -Root $Root -Sp $sp
        if ($r.exit -ne 0) { Set-CaseFailure -Id $id @(('commit ' + $i + ' failed exit=' + $r.exit)); return }
    }
    $stC = Get-ActiveStateHashes -MemRoot $a.mem
    if ($stC.gen -ne 4) { Set-CaseFailure -Id $id @(('gen ' + $stC.gen + ' != 4')); return }
    $vals = @{}
    foreach ($ln in @((Get-StateTextOf -MemRoot $a.mem -Gen 2) -split "`n")) {
        if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
        $kv = @($ln -split '=', 2)
        if ($kv.Count -eq 2) { $vals[$kv[0]] = $kv[1] }
    }
    $fileMap = @{ 'CORE_SHA256' = 'core.md'; 'INDEX_SHA256' = 'index.md'; 'ARCHIVE_SHA256' = 'archive.md' }
    $g2dir = Get-GenDirOf -MemRoot $a.mem -Gen 2
    foreach ($key in @('CORE_SHA256', 'INDEX_SHA256', 'ARCHIVE_SHA256')) {
        if (-not $vals.ContainsKey($key)) { Set-CaseFailure -Id $id @(('STATE 2 missing key ' + $key)); continue }
        $actual = (Get-FileHash -LiteralPath (Join-Path $g2dir $fileMap[$key]) -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals([string]$vals[$key], $actual, [System.StringComparison]::OrdinalIgnoreCase)) { Set-CaseFailure -Id $id @(('STATE 2 ' + $key + ' mismatch')) }
    }
    for ($i = 4; $i -le 6; $i++) {
        $st = Get-ActiveStateHashes -MemRoot $a.mem
        $sp = New-CommitSpecX -Root $Root -Name ('draft_bam_028c' + $i + '.json') -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject ('028c rec' + $i) -Summary ('028c sum' + $i))
        $r = Retry-Spec -Root $Root -Sp $sp
        if ($r.exit -ne 0) { Set-CaseFailure -Id $id @(('commit ' + $i + ' failed exit=' + $r.exit)); return }
    }
    foreach ($key in @('CORE_SHA256', 'INDEX_SHA256', 'ARCHIVE_SHA256')) {
        $fp = Join-Path $g2dir $fileMap[$key]
        if (-not (Test-Path -LiteralPath $fp)) { Set-CaseFailure -Id $id @(('gen2 file missing after later commits: ' + $fp)); continue }
        $actual = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals([string]$vals[$key], $actual, [System.StringComparison]::OrdinalIgnoreCase)) { Set-CaseFailure -Id $id @(('gen2 file changed after later commits: ' + $fileMap[$key])) }
    }
}

function Test-AMT041A {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.a'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41a base' -Summary '41a sum' -Provenance 'USER_STATED' -Note '41A NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opId = New-Uuid
    $sp = New-CommitSpecX -Root $Root -Name 'draft_bam_41a.json' -Gen $st.gen -St $st -OpId $opId -Ops @(New-AddOpX -Subject '41a fault' -Summary '41a fault sum')
    $rf = Fault-Commit -Root $Root -Sp $sp -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    $f = @(Check-JsonContract -R $rf -ExpectedStatus 'FAILED' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('staged_verify_failed') -ExpectedExit 1)
    if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    $stateSha = Get-TextSha256Hex -Text (Get-StateTextOf -MemRoot $a.mem -Gen 2)
    $receiptText = Build-ReceiptText -Generation 3 -OperationId $opId -SpecSha $sp.sha -StateSha $stateSha -Action 'add' -AffectedIds 'mem_0002'
    $null = PrePlace-Receipt -MemRoot $a.mem -OpId $opId -Text $receiptText
    $rStat = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Status')
    if ($rStat.exit -ne 0 -or $rStat.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('Status failed'); return }
    $jStat = Parse-JsonLine -Line $rStat.stdout_lines[0]
    if ($null -eq $jStat -or $jStat.status -cne 'PASS') { Set-CaseFailure -Id $id @('Status not PASS'); return }
    $indep = Measure-StatusMetricsIndependent -MemRoot $a.mem
    foreach ($k in @('generation_count', 'completed_bytes_total', 'active_generation_bytes', 'largest_generation_bytes', 'noncanonical_bytes', 'receipt_count', 'receipt_bytes_total')) {
        $jv = $null
        if ($jStat.PSObject.Properties.Name -contains $k) { $jv = $jStat.$k }
        $iv = $indep.$k
        if ("$jv" -cne "$iv") { Set-CaseFailure -Id $id @(('metric ' + $k + ': tool=' + $jv + ' indep=' + $iv)) }
    }
    if ($indep.noncanonical_bytes -le 0) { Set-CaseFailure -Id $id @('noncanonical_bytes <= 0') }
    if ("$($indep.receipt_count)" -cne '2') { Set-CaseFailure -Id $id @('receipt_count != 2 (init receipt + pre-placed fault receipt)') }
}

function Test-AMT041B {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.b'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41b base' -Summary '41b sum' -Provenance 'USER_STATED' -Note '41B NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $r1 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    if ($r1.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(1) not one line') }
    else { $j1 = Parse-JsonLine -Line $r1.stdout_lines[0]; if ($null -eq $j1 -or [string]$j1.status -cne 'PASS') { Set-CaseFailure -Id $id @('(1) status != PASS') } }
    $r2 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Status')
    if ($r2.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(2) not one line') }
    else { $j2 = Parse-JsonLine -Line $r2.stdout_lines[0]; if ($null -eq $j2 -or [string]$j2.status -cne 'PASS') { Set-CaseFailure -Id $id @('(2) status != PASS') } }
    $r3 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('41b'); 'Max' = @(10) })
    if ($r3.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(3) not one line') }
    else { $j3 = Parse-JsonLine -Line $r3.stdout_lines[0]; if ($null -eq $j3 -or [string]$j3.status -cne 'HIT') { Set-CaseFailure -Id $id @('(3) status != HIT') } }
    $r4 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('zzznonexistent'); 'Max' = @(10) })
    if ($r4.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(4) not one line') }
    else { $j4 = Parse-JsonLine -Line $r4.stdout_lines[0]; if ($null -eq $j4 -or [string]$j4.status -cne 'MISS') { Set-CaseFailure -Id $id @('(4) status != MISS') } }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opC = New-Uuid
    $spC = New-CommitSpecX -Root $Root -Name 'draft_bam_41bc.json' -Gen $st.gen -St $st -OpId $opC -Ops @(New-AddOp -Subject ('x' * 65) -Summary '41b c sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
    $r5 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spC.path) })
    if ($r5.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(5) not one line') }
    else { $j5 = Parse-JsonLine -Line $r5.stdout_lines[0]; if ($null -eq $j5 -or [string]$j5.status -cne 'INVALID') { Set-CaseFailure -Id $id @('(5) status != INVALID') } }
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $opF = New-Uuid
    $spF = Write-SpecFile -Root $Root -Name 'draft_bam_41bf.json' -SpecObj (New-ForgetSpec -OpId $opF -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive))
    $r6 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Forget' -Extra @{ sp = $true; 'Spec' = @($spF.path) })
    if ($r6.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(6) not one line') }
    else { $j6 = Parse-JsonLine -Line $r6.stdout_lines[0]; if ($null -eq $j6 -or [string]$j6.status -cne 'PASS') { Set-CaseFailure -Id $id @('(6) status != PASS') } }
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $opR = New-Uuid
    $spR = Write-SpecFile -Root $Root -Name 'draft_bam_41br.json' -SpecObj (New-RestoreSpec -OpId $opR -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $st3.gen -Core $st3.core -Index $st3.index -Archive $st3.archive))
    $r7 = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Restore' -Extra @{ sp = $true; 'Spec' = @($spR.path) })
    if ($r7.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('(7) not one line') }
    else { $j7 = Parse-JsonLine -Line $r7.stdout_lines[0]; if ($null -eq $j7 -or [string]$j7.status -cne 'PASS') { Set-CaseFailure -Id $id @('(7) status != PASS') } }
}

function Test-AMT041C {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41c base' -Summary '41c sum' -Provenance 'USER_STATED' -Note '41C NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $lockPath = Join-Path $a.mem '.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { Write-FileBytes -Path $lockPath -Bytes ([byte[]]@()) }
    $lockFs = [System.IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
    try {
        $st = Get-ActiveStateHashes -MemRoot $a.mem
        $sp = New-CommitSpecX -Root $Root -Name 'draft_bam_41c.json' -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject '41c lock' -Summary '41c lock sum')
        $m0 = Get-Manifest -Root $a.mem
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($sp.path); 'LockTimeoutSeconds' = @(2) })
        $f = @(Check-JsonContract -R $r -ExpectedStatus 'STALE' -ExpectedOp 'commit' -ExpectedRecords @() -ExpectedDiagContains @('writer_active') -ExpectedExit 1)
        if ($f.Count -gt 0) { Set-CaseFailure -Id $id @($f -join ' | ') }
    }
    finally {
        $lockFs.Dispose()
    }
    Assert-ManifestUnchanged -Id $id -Before $m0 -After (Get-Manifest -Root $a.mem)
}

function Test-AMT041D {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.d'
    $statuses = @()
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41d base' -Summary '41d sum' -Provenance 'USER_STATED' -Note '41D NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $ra = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    if ($ra.stdout_lines.Count -eq 1) { $ja = Parse-JsonLine -Line $ra.stdout_lines[0]; if ($null -eq $ja) { Set-CaseFailure -Id $id @('(a) no JSON') } elseif ([string]$ja.status -cne 'PASS') { Set-CaseFailure -Id $id @('(a) status != PASS') } else { $statuses += [string]$ja.status } } else { Set-CaseFailure -Id $id @('(a) not one line') }
    $rb = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('41d'); 'Max' = @(5) })
    if ($rb.stdout_lines.Count -eq 1) { $jb = Parse-JsonLine -Line $rb.stdout_lines[0]; if ($null -eq $jb) { Set-CaseFailure -Id $id @('(b) no JSON') } elseif ([string]$jb.status -cne 'HIT') { Set-CaseFailure -Id $id @('(b) status != HIT') } else { $statuses += [string]$jb.status } } else { Set-CaseFailure -Id $id @('(b) not one line') }
    $rc = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('zzznonexistent'); 'Max' = @(5) })
    if ($rc.stdout_lines.Count -eq 1) { $jc = Parse-JsonLine -Line $rc.stdout_lines[0]; if ($null -eq $jc) { Set-CaseFailure -Id $id @('(c) no JSON') } elseif ([string]$jc.status -cne 'MISS') { Set-CaseFailure -Id $id @('(c) status != MISS') } else { $statuses += [string]$jc.status } } else { Set-CaseFailure -Id $id @('(c) not one line') }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opC = New-Uuid
    $spC = New-CommitSpecX -Root $Root -Name 'draft_bam_41dc.json' -Gen $st.gen -St $st -OpId $opC -Ops @(New-AddOp -Subject ('x' * 65) -Summary '41d c sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
    $rd = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spC.path) })
    if ($rd.stdout_lines.Count -eq 1) { $jd = Parse-JsonLine -Line $rd.stdout_lines[0]; if ($null -eq $jd) { Set-CaseFailure -Id $id @('(d) no JSON') } elseif ([string]$jd.status -cne 'INVALID') { Set-CaseFailure -Id $id @('(d) status != INVALID') } else { $statuses += [string]$jd.status } } else { Set-CaseFailure -Id $id @('(d) not one line') }
    $opE = New-Uuid
    $spE = New-CommitSpecX -Root $Root -Name 'draft_bam_41de.json' -Gen 99 -St $st -OpId $opE -Ops @(New-AddOpX -Subject '41d e rec' -Summary '41d e sum')
    $re = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spE.path) })
    if ($re.stdout_lines.Count -eq 1) { $je = Parse-JsonLine -Line $re.stdout_lines[0]; if ($null -eq $je) { Set-CaseFailure -Id $id @('(e) no JSON') } elseif ([string]$je.status -cne 'STALE') { Set-CaseFailure -Id $id @('(e) status != STALE') } else { $statuses += [string]$je.status } } else { Set-CaseFailure -Id $id @('(e) not one line') }
    $gen2dir = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $noteDir = Join-Path $gen2dir 'notes'
    $noteFiles = @(Get-ChildItem -LiteralPath $noteDir -File -Force -ErrorAction SilentlyContinue)
    if ($noteFiles.Count -gt 0) {
        $nf = $noteFiles[0].FullName
        $nb = Read-FileBytes -Path $nf
        if ($nb.Length -gt 0) { $nb[0] = ($nb[0] -bxor 0xFF) }
        Write-FileBytes -Path $nf -Bytes $nb
    }
    $rf = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    if ($rf.stdout_lines.Count -eq 1) { $jf2 = Parse-JsonLine -Line $rf.stdout_lines[0]; if ($null -eq $jf2) { Set-CaseFailure -Id $id @('(f) no JSON') } elseif ([string]$jf2.status -cne 'UNVERIFIED') { Set-CaseFailure -Id $id @('(f) status != UNVERIFIED') } else { $statuses += [string]$jf2.status } } else { Set-CaseFailure -Id $id @('(f) not one line') }
    $rootB = (Join-Path $Root 'alt41d')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $g2b = Build-Gen2Fixture -Root $rootB -Subject '41d b base' -Summary '41d b sum' -Provenance 'USER_STATED' -Note '41D B NOTE' -Evidence $null
    if ($g2b.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture B build failed'); return }
    $ab = Get-CaseRootArgs -Root $rootB
    $stb = Get-ActiveStateHashes -MemRoot $ab.mem
    $opG = New-Uuid
    $spG = New-CommitSpecX -Root $rootB -Name 'draft_bam_41dg.json' -Gen $stb.gen -St $stb -OpId $opG -Ops @(New-AddOpX -Subject '41d g rec' -Summary '41d g sum')
    $rg = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', (Join-Path $Root 'memory-elsewhere'), '-WorkspaceRoot', (Join-Path $rootB 'workspace'), '-ScratchpadRoot', (Join-Path $rootB 'scratchpad'), '-Spec', $spG.path)
    if ($rg.stdout_lines.Count -eq 1) { $jg = Parse-JsonLine -Line $rg.stdout_lines[0]; if ($null -eq $jg) { Set-CaseFailure -Id $id @('(g) no JSON') } elseif ([string]$jg.status -cne 'BLOCKED') { Set-CaseFailure -Id $id @('(g) status != BLOCKED') } else { $statuses += [string]$jg.status } } else { Set-CaseFailure -Id $id @('(g) not one line') }
    $stb2 = Get-ActiveStateHashes -MemRoot $ab.mem
    $opH = New-Uuid
    $spH = New-CommitSpecX -Root $rootB -Name 'draft_bam_41dh.json' -Gen $stb2.gen -St $stb2 -OpId $opH -Ops @(New-AddOpX -Subject '41d h rec' -Summary '41d h sum')
    $rh = Fault-Commit -Root $rootB -Sp $spH -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    if ($rh.stdout_lines.Count -eq 1) { $jh = Parse-JsonLine -Line $rh.stdout_lines[0]; if ($null -eq $jh) { Set-CaseFailure -Id $id @('(h) no JSON') } elseif ([string]$jh.status -cne 'FAILED') { Set-CaseFailure -Id $id @('(h) status != FAILED') } else { $statuses += [string]$jh.status } } else { Set-CaseFailure -Id $id @('(h) not one line') }
    if ($statuses.Count -ne 8) { Set-CaseFailure -Id $id @(('status count ' + $statuses.Count + ' != 8')) }
    foreach ($sv in @('PASS', 'HIT', 'MISS', 'INVALID', 'STALE', 'UNVERIFIED', 'BLOCKED', 'FAILED')) {
        $n = @($statuses | Where-Object { $_ -ceq $sv }).Count
        if ($n -ne 1) { Set-CaseFailure -Id $id @(('status ' + $sv + ' count ' + $n + ' != 1')) }
    }
}

function Test-AMT041E {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.e'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41e base' -Summary '41e sum' -Provenance 'USER_STATED' -Note '41E NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opId = New-Uuid
    $sp = New-CommitSpecX -Root $Root -Name 'draft_bam_41e.json' -Gen $st.gen -St $st -OpId $opId -Ops @(New-AddOpX -Subject '41e fault' -Summary '41e fault sum')
    $rf = Fault-Commit -Root $Root -Sp $sp -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    if ($rf.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('fault commit not one line'); return }
    $jf = Parse-JsonLine -Line $rf.stdout_lines[0]
    if ($null -eq $jf) { Set-CaseFailure -Id $id @('fault commit no JSON'); return }
    if ([string]$jf.status -cne 'FAILED') { Set-CaseFailure -Id $id @(('fault commit status ' + $jf.status + ' != FAILED')) }
    $diags = @()
    if ($null -ne $jf.diagnostics) { $diags = @($jf.diagnostics) }
    if ($diags -notcontains 'staged_verify_failed') { Set-CaseFailure -Id $id @('diagnostics missing staged_verify_failed') }
    if (-not (Test-DiagVocabulary -Diags $diags)) { Set-CaseFailure -Id $id @('diagnostics outside vocabulary') }
    if ([string]$jf.status -notin $script:StatusSet) { Set-CaseFailure -Id $id @('status outside 8-set') }
    $rr = Retry-Spec -Root $Root -Sp $sp
    if ($rr.exit -ne 0) { Set-CaseFailure -Id $id @(('retry exit ' + $rr.exit)); return }
    if ($rr.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('retry not one line'); return }
    $jr = Parse-JsonLine -Line $rr.stdout_lines[0]
    if ($null -eq $jr) { Set-CaseFailure -Id $id @('retry no JSON'); return }
    if ([string]$jr.status -cne 'PASS') { Set-CaseFailure -Id $id @(('retry status ' + $jr.status + ' != PASS')) }
    $recs = @($jr.records)
    if ($recs.Count -lt 1) { Set-CaseFailure -Id $id @('retry committed no records') }
    $diagsR = @()
    if ($null -ne $jr.diagnostics) { $diagsR = @($jr.diagnostics) }
    if (-not (Test-DiagVocabulary -Diags $diagsR)) { Set-CaseFailure -Id $id @('retry diagnostics outside vocabulary') }
    if ([string]$jr.status -notin $script:StatusSet) { Set-CaseFailure -Id $id @('retry status outside 8-set') }
}

function Test-AMT041F {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.f'
    $statuses = @()
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41f base' -Summary '41f sum' -Provenance 'USER_STATED' -Note '41F NOTE' -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $ra = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    if ($ra.exit -ne 0) { Set-CaseFailure -Id $id @('(a) exit != 0') }
    elseif ($ra.stdout_lines.Count -eq 1) { $ja = Parse-JsonLine -Line $ra.stdout_lines[0]; if ($null -ne $ja) { $statuses += [string]$ja.status } }
    $rb = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('41f'); 'Max' = @(5) })
    if ($rb.exit -ne 0) { Set-CaseFailure -Id $id @('(b) exit != 0') }
    elseif ($rb.stdout_lines.Count -eq 1) { $jb = Parse-JsonLine -Line $rb.stdout_lines[0]; if ($null -ne $jb) { $statuses += [string]$jb.status } }
    $rc = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Recall' -Extra @{ 'Query' = @('zzznonexistent'); 'Max' = @(5) })
    if ($rc.exit -ne 0) { Set-CaseFailure -Id $id @('(c) exit != 0') }
    elseif ($rc.stdout_lines.Count -eq 1) { $jc = Parse-JsonLine -Line $rc.stdout_lines[0]; if ($null -ne $jc) { $statuses += [string]$jc.status } }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $opC = New-Uuid
    $spC = New-CommitSpecX -Root $Root -Name 'draft_bam_41fc.json' -Gen $st.gen -St $st -OpId $opC -Ops @(New-AddOp -Subject ('x' * 65) -Summary '41f c sum' -Provenance 'USER_STATED' -Tags $null -Note $null -Evidence $null -Pin $null -Supersedes $null)
    $rd = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spC.path) })
    if ($rd.exit -ne 1) { Set-CaseFailure -Id $id @('(d) exit != 1') }
    elseif ($rd.stdout_lines.Count -eq 1) { $jd = Parse-JsonLine -Line $rd.stdout_lines[0]; if ($null -ne $jd) { $statuses += [string]$jd.status } }
    $opE = New-Uuid
    $spE = New-CommitSpecX -Root $Root -Name 'draft_bam_41fe.json' -Gen 99 -St $st -OpId $opE -Ops @(New-AddOpX -Subject '41f e rec' -Summary '41f e sum')
    $re = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spE.path) })
    if ($re.exit -ne 1) { Set-CaseFailure -Id $id @('(e) exit != 1') }
    elseif ($re.stdout_lines.Count -eq 1) { $je = Parse-JsonLine -Line $re.stdout_lines[0]; if ($null -ne $je) { $statuses += [string]$je.status } }
    $gen2dir = Get-GenDirOf -MemRoot $a.mem -Gen 2
    $noteDir = Join-Path $gen2dir 'notes'
    $noteFiles = @(Get-ChildItem -LiteralPath $noteDir -File -Force -ErrorAction SilentlyContinue)
    if ($noteFiles.Count -gt 0) {
        $nf = $noteFiles[0].FullName
        $nb = Read-FileBytes -Path $nf
        if ($nb.Length -gt 0) { $nb[0] = ($nb[0] -bxor 0xFF) }
        Write-FileBytes -Path $nf -Bytes $nb
    }
    $rf = Invoke-Tool -Args (Tool-Args -Root $Root -Mode 'Validate')
    if ($rf.exit -ne 1) { Set-CaseFailure -Id $id @('(f) exit != 1') }
    elseif ($rf.stdout_lines.Count -eq 1) { $jf2 = Parse-JsonLine -Line $rf.stdout_lines[0]; if ($null -ne $jf2) { $statuses += [string]$jf2.status } }
    $rootB = (Join-Path $Root 'alt41f')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootB 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootB 'scratchpad')) | Out-Null
    $g2b = Build-Gen2Fixture -Root $rootB -Subject '41f b base' -Summary '41f b sum' -Provenance 'USER_STATED' -Note '41F B NOTE' -Evidence $null
    if ($g2b.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture B build failed'); return }
    $ab = Get-CaseRootArgs -Root $rootB
    $stb = Get-ActiveStateHashes -MemRoot $ab.mem
    $opG = New-Uuid
    $spG = New-CommitSpecX -Root $rootB -Name 'draft_bam_41fg.json' -Gen $stb.gen -St $stb -OpId $opG -Ops @(New-AddOpX -Subject '41f g rec' -Summary '41f g sum')
    $rg = Invoke-Tool -Args @('-Mode', 'Commit', '-MemoryRoot', (Join-Path $Root 'memory-elsewhere'), '-WorkspaceRoot', (Join-Path $rootB 'workspace'), '-ScratchpadRoot', (Join-Path $rootB 'scratchpad'), '-Spec', $spG.path)
    if ($rg.exit -ne 1) { Set-CaseFailure -Id $id @('(g) exit != 1') }
    elseif ($rg.stdout_lines.Count -eq 1) { $jg = Parse-JsonLine -Line $rg.stdout_lines[0]; if ($null -ne $jg) { $statuses += [string]$jg.status } }
    $stb2 = Get-ActiveStateHashes -MemRoot $ab.mem
    $opH = New-Uuid
    $spH = New-CommitSpecX -Root $rootB -Name 'draft_bam_41fh.json' -Gen $stb2.gen -St $stb2 -OpId $opH -Ops @(New-AddOpX -Subject '41f h rec' -Summary '41f h sum')
    $rh = Fault-Commit -Root $rootB -Sp $spH -Point 'FAULT_BEFORE_CURRENT_SWITCH'
    if ($rh.exit -ne 1) { Set-CaseFailure -Id $id @('(h) exit != 1') }
    elseif ($rh.stdout_lines.Count -eq 1) { $jh = Parse-JsonLine -Line $rh.stdout_lines[0]; if ($null -ne $jh) { $statuses += [string]$jh.status } }
    if ($statuses.Count -ne 8) { Set-CaseFailure -Id $id @(('status count ' + $statuses.Count + ' != 8')) }
    foreach ($sv in @('PASS', 'HIT', 'MISS', 'INVALID', 'STALE', 'UNVERIFIED', 'BLOCKED', 'FAILED')) {
        $n = @($statuses | Where-Object { $_ -ceq $sv }).Count
        if ($n -ne 1) { Set-CaseFailure -Id $id @(('status ' + $sv + ' count ' + $n + ' != 1')) }
    }
    foreach ($sv in $statuses) { if ($sv -notin $script:StatusSet) { Set-CaseFailure -Id $id @(('status ' + $sv + ' outside 8-set')) } }
    $rootU = (Join-Path $Root 'alt41fu')
    [System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $rootU 'workspace') 'memory')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $rootU 'scratchpad')) | Out-Null
    $g2u = Build-Gen2Fixture -Root $rootU -Subject '41f u base' -Summary '41f u sum' -Provenance 'USER_STATED' -Note '41F U NOTE' -Evidence $null
    if ($g2u.r.exit -ne 0) { Set-CaseFailure -Id $id @('fixture U build failed'); return }
    $au = Get-CaseRootArgs -Root $rootU
    $stU = Get-ActiveStateHashes -MemRoot $au.mem
    $opU = New-Uuid
    $spU = New-CommitSpecX -Root $rootU -Name 'draft_bam_41fu.json' -Gen $stU.gen -St $stU -OpId $opU -Ops @(New-AddOpX -Subject '41f u rec' -Summary '41f u sum')
    $mU0 = Get-Manifest -Root $au.mem
    $ru = Invoke-Tool -Args (Tool-Args -Root $rootU -Mode 'Commit' -Extra @{ sp = $true; 'Spec' = @($spU.path); 'TestMode' = $true })
    if ($ru.exit -ne 2) { Set-CaseFailure -Id $id @(('usage error exit ' + $ru.exit + ' != 2')) }
    if ($ru.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @('usage error not one line') }
    $ju = Parse-JsonLine -Line $ru.stdout_lines[0]
    if ($null -eq $ju) { Set-CaseFailure -Id $id @('usage error no JSON') }
    else {
        if ([string]$ju.status -cne 'FAILED') { Set-CaseFailure -Id $id @('usage error status != FAILED') }
        $diagsU = @()
        if ($null -ne $ju.diagnostics) { $diagsU = @($ju.diagnostics) }
        if ($diagsU -notcontains 'USAGE_ERROR') { Set-CaseFailure -Id $id @('usage error diag missing USAGE_ERROR') }
    }
    Assert-ManifestUnchanged -Id $id -Before $mU0 -After (Get-Manifest -Root $au.mem)
}

function Test-AMT041G {
    param([string]$Root)
    $a = Get-CaseRootArgs -Root $Root
    $id = 'AM-T-041.g'
    $decoy = 'DECOY_SECRET_TOKEN_7f3a9c'
    $g2 = Build-Gen2Fixture -Root $Root -Subject '41g base' -Summary '41g sum' -Provenance 'USER_STATED' -Note $decoy -Evidence $null
    if ($g2.r.exit -ne 0) { Set-CaseFailure -Id $id @('gen2 build failed'); return }
    $st = Get-ActiveStateHashes -MemRoot $a.mem
    $spC = New-CommitSpecX -Root $Root -Name 'draft_bam_41gc.json' -Gen $st.gen -St $st -OpId (New-Uuid) -Ops @(New-AddOpX -Subject '41g new' -Summary '41g new sum')
    $st2 = Get-ActiveStateHashes -MemRoot $a.mem
    $spF = Write-SpecFile -Root $Root -Name 'draft_bam_41gf.json' -SpecObj (New-ForgetSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $st2.gen -Core $st2.core -Index $st2.index -Archive $st2.archive))
    $st3 = Get-ActiveStateHashes -MemRoot $a.mem
    $spR = Write-SpecFile -Root $Root -Name 'draft_bam_41gr.json' -SpecObj (New-RestoreSpec -OpId (New-Uuid) -RecordId 'mem_0001' -Expected (New-ExpectedBlock -Generation $st3.gen -Core $st3.core -Index $st3.index -Archive $st3.archive))
    $calls = @(
        @{ mode = 'Validate'; extra = @{} },
        @{ mode = 'Status'; extra = @{} },
        @{ mode = 'Recall'; extra = @{ 'Query' = @('41g'); 'Max' = @(5) } },
        @{ mode = 'Commit'; extra = @{ sp = $true; 'Spec' = @($spC.path) } },
        @{ mode = 'Forget'; extra = @{ sp = $true; 'Spec' = @($spF.path) } },
        @{ mode = 'Restore'; extra = @{ sp = $true; 'Spec' = @($spR.path) } }
    )
    foreach ($c in $calls) {
        $r = Invoke-Tool -Args (Tool-Args -Root $Root -Mode $c.mode -Extra $c.extra)
        if ($r.stdout_lines.Count -ne 1) { Set-CaseFailure -Id $id @($c.mode + ' not one line'); continue }
        $j = Parse-JsonLine -Line $r.stdout_lines[0]
        if ($null -eq $j) { continue }
        $diags = @()
        if ($null -ne $j.diagnostics) { $diags = @($j.diagnostics) }
        foreach ($d in $diags) {
            if ([string]$d -like '*DECOY*' -or [string]$d -like '*7f3a9c*') { Set-CaseFailure -Id $id @('decoy in diagnostics: ' + $d) }
        }
    }
}

# ---------------------------------------------------------------------------
# Dispatch tail: authority preflight, case table, selection, execution, summary
# ---------------------------------------------------------------------------
function Invoke-AuthorityPreflight {
    $f = New-Object System.Collections.Generic.List[string]
    $checks = @(
        @{ path = $script:ReqPath; key = 'REQ' },
        @{ path = (Join-Path $script:DraftDir '01_CANONICAL_NORMATIVE_SPECIFICATION.md'); key = '01' },
        @{ path = (Join-Path $script:DraftDir '02_HUMAN_GUIDANCE.md'); key = '02' },
        @{ path = (Join-Path $script:DraftDir '03_SCOPE_FREEZE_RECORD.md'); key = '03' },
        @{ path = (Join-Path $script:DraftDir '04_TEST_FIRST_SPECIFICATION.md'); key = '04' },
        @{ path = (Join-Path $script:DraftDir '05_TEST_SPEC_FREEZE_RECORD.md'); key = '05' }
    )
    foreach ($c in $checks) {
        if (-not (Test-Path -LiteralPath $c.path)) { $f.Add($c.key + ' ABSENT'); continue }
        $actual = (Get-FileHash -LiteralPath $c.path -Algorithm SHA256).Hash
        $expected = $script:AuthoritySha[$c.key]
        if ($actual -cne $expected) { $f.Add($c.key + ' HASH_MISMATCH actual=' + $actual + ' expected=' + $expected) }
    }
    return $f
}

$script:CaseTable = @(
    @{ id = 'AM-T-001'; fn = 'Test-AMT001' },
    @{ id = 'AM-T-002'; fn = 'Test-AMT002' },
    @{ id = 'AM-T-002.a'; fn = 'Test-AMT002A' },
    @{ id = 'AM-T-002.b'; fn = 'Test-AMT002B' },
    @{ id = 'AM-T-002.c'; fn = 'Test-AMT002C' },
    @{ id = 'AM-T-002.d'; fn = 'Test-AMT002D' },
    @{ id = 'AM-T-002.e'; fn = 'Test-AMT002E' },
    @{ id = 'AM-T-002.f'; fn = 'Test-AMT002F' },
    @{ id = 'AM-T-002.g'; fn = 'Test-AMT002G' },
    @{ id = 'AM-T-002.h'; fn = 'Test-AMT002H' },
    @{ id = 'AM-T-002.i'; fn = 'Test-AMT002I' },
    @{ id = 'AM-T-003'; fn = 'Test-AMT003' },
    @{ id = 'AM-T-003.a'; fn = 'Test-AMT003A' },
    @{ id = 'AM-T-003.b'; fn = 'Test-AMT003B' },
    @{ id = 'AM-T-003.c'; fn = 'Test-AMT003C' },
    @{ id = 'AM-T-003.d'; fn = 'Test-AMT003D' },
    @{ id = 'AM-T-003.e'; fn = 'Test-AMT003E' },
    @{ id = 'AM-T-003.f'; fn = 'Test-AMT003F' },
    @{ id = 'AM-T-003.g'; fn = 'Test-AMT003G' },
    @{ id = 'AM-T-004'; fn = 'Test-AMT004' },
    @{ id = 'AM-T-005'; fn = 'Test-AMT005' },
    @{ id = 'AM-T-005.a'; fn = 'Test-AMT005A' },
    @{ id = 'AM-T-005.b'; fn = 'Test-AMT005B' },
    @{ id = 'AM-T-005.c'; fn = 'Test-AMT005C' },
    @{ id = 'AM-T-005.d'; fn = 'Test-AMT005D' },
    @{ id = 'AM-T-005.e'; fn = 'Test-AMT005E' },
    @{ id = 'AM-T-005.f'; fn = 'Test-AMT005F' },
    @{ id = 'AM-T-005.g'; fn = 'Test-AMT005G' },
    @{ id = 'AM-T-006'; fn = 'Test-AMT006' },
    @{ id = 'AM-T-006.a'; fn = 'Test-AMT006A' },
    @{ id = 'AM-T-006.b'; fn = 'Test-AMT006B' },
    @{ id = 'AM-T-006.c'; fn = 'Test-AMT006C' },
    @{ id = 'AM-T-006.d'; fn = 'Test-AMT006D' },
    @{ id = 'AM-T-006.e'; fn = 'Test-AMT006E' },
    @{ id = 'AM-T-006.f'; fn = 'Test-AMT006F' },
    @{ id = 'AM-T-006.g'; fn = 'Test-AMT006G' },
    @{ id = 'AM-T-006.h'; fn = 'Test-AMT006H' },
    @{ id = 'AM-T-006.i'; fn = 'Test-AMT006I' },
    @{ id = 'AM-T-006.j'; fn = 'Test-AMT006J' },
    @{ id = 'AM-T-006.k'; fn = 'Test-AMT006K' },
    @{ id = 'AM-T-006.l'; fn = 'Test-AMT006L' },
    @{ id = 'AM-T-006.m'; fn = 'Test-AMT006M' },
    @{ id = 'AM-T-006.n'; fn = 'Test-AMT006N' },
    @{ id = 'AM-T-006.o'; fn = 'Test-AMT006O' },
    @{ id = 'AM-T-006.p'; fn = 'Test-AMT006P' },
    @{ id = 'AM-T-006.q'; fn = 'Test-AMT006Q' },
    @{ id = 'AM-T-006.r'; fn = 'Test-AMT006R' },
    @{ id = 'AM-T-006.s'; fn = 'Test-AMT006S' },
    @{ id = 'AM-T-006.t'; fn = 'Test-AMT006T' },
    @{ id = 'AM-T-006.u'; fn = 'Test-AMT006U' },
    @{ id = 'AM-T-006.v'; fn = 'Test-AMT006V' },
    @{ id = 'AM-T-007'; fn = 'Test-AMT007' },
    @{ id = 'AM-T-007.a'; fn = 'Test-AMT007A' },
    @{ id = 'AM-T-007.b'; fn = 'Test-AMT007B' },
    @{ id = 'AM-T-007.c'; fn = 'Test-AMT007C' },
    @{ id = 'AM-T-007.d'; fn = 'Test-AMT007D' },
    @{ id = 'AM-T-007.e'; fn = 'Test-AMT007E' },
    @{ id = 'AM-T-007.f'; fn = 'Test-AMT007F' },
    @{ id = 'AM-T-007.g'; fn = 'Test-AMT007G' },
    @{ id = 'AM-T-007.h'; fn = 'Test-AMT007H' },
    @{ id = 'AM-T-008'; fn = 'Test-AMT008' },
    @{ id = 'AM-T-009'; fn = 'Test-AMT009' },
    @{ id = 'AM-T-010'; fn = 'Test-AMT010' },
    @{ id = 'AM-T-011'; fn = 'Test-AMT011' },
    @{ id = 'AM-T-012'; fn = 'Test-AMT012' },
    @{ id = 'AM-T-013'; fn = 'Test-AMT013' },
    @{ id = 'AM-T-044'; fn = 'Test-AMT044' },
    @{ id = 'AM-T-018.a'; fn = 'Test-AMT018A' },
    @{ id = 'AM-T-018.b'; fn = 'Test-AMT018B' },
    @{ id = 'AM-T-018.c'; fn = 'Test-AMT018C' },
    @{ id = 'AM-T-018.d'; fn = 'Test-AMT018D' },
    @{ id = 'AM-T-018.e'; fn = 'Test-AMT018E' },
    @{ id = 'AM-T-018.f'; fn = 'Test-AMT018F' },
    @{ id = 'AM-T-018.g'; fn = 'Test-AMT018G' },
    @{ id = 'AM-T-018.h'; fn = 'Test-AMT018H' },
    @{ id = 'AM-T-018.i'; fn = 'Test-AMT018I' },
    @{ id = 'AM-T-018.MACHINE_HALF'; fn = 'Test-AMT018Host' },
    @{ id = 'AM-T-020.a'; fn = 'Test-AMT020A' },
    @{ id = 'AM-T-020.MACHINE_HALF'; fn = 'Test-AMT020Host' },
    @{ id = 'AM-T-026'; fn = 'Test-AMT026' },
    @{ id = 'AM-T-027'; fn = 'Test-AMT027' },
    @{ id = 'AM-T-028'; fn = 'Test-AMT028' },
    @{ id = 'AM-T-028.a'; fn = 'Test-AMT028A' },
    @{ id = 'AM-T-028.b'; fn = 'Test-AMT028B' },
    @{ id = 'AM-T-028.c'; fn = 'Test-AMT028C' },
    @{ id = 'AM-T-029'; fn = 'Test-AMT029' },
    @{ id = 'AM-T-033'; fn = 'Test-AMT033' },
    @{ id = 'AM-T-041'; fn = 'Test-AMT041' },
    @{ id = 'AM-T-041.a'; fn = 'Test-AMT041A' },
    @{ id = 'AM-T-041.b'; fn = 'Test-AMT041B' },
    @{ id = 'AM-T-041.c'; fn = 'Test-AMT041C' },
    @{ id = 'AM-T-041.d'; fn = 'Test-AMT041D' },
    @{ id = 'AM-T-041.e'; fn = 'Test-AMT041E' },
    @{ id = 'AM-T-041.f'; fn = 'Test-AMT041F' },
    @{ id = 'AM-T-041.g'; fn = 'Test-AMT041G' }
)

function Select-Cases {
    if ($All) { return $script:CaseTable }
    if ($Case -ne '') {
        $sel = @($script:CaseTable | Where-Object { $_.id -eq $Case })
        if ($sel.Count -eq 0) { return $null }
        return ,$sel
    }
    return $null
}

$sel = Select-Cases
if ($null -eq $sel) {
    $errJson = '{"error":"RUNNER_USAGE","detail":"use -All or -Case <ID>"}'
    Write-Output $errJson
    exit 2
}

$authFails = @(Invoke-AuthorityPreflight)
if ($authFails.Count -gt 0) {
    Write-Output ('{"error":"STALE_INPUT","detail":' + ($authFails | ForEach-Object { '"' + $_ + '"' }) -join ',' + '}')
    exit 1
}

[Console]::Error.WriteLine(('Running ' + $sel.Count + ' cases...'))
$exitCode = 0
foreach ($entry in $sel) {
    $cid = $entry.id
    $fnName = $entry.fn
    [Console]::Error.WriteLine(('  ' + $cid + ' ...'))
    $sb = { param($r) & (Get-Command $fnName) $r }
    Run-Case -Id $cid -Block $sb
    $st = $script:Results[$cid].status
    if ($st -eq 'FAIL') { $exitCode = 1 }
    [Console]::Error.WriteLine(('    ' + $st))
}

$totalCases = $sel.Count
$passCases = 0
$failCases = 0
$failingIds = @()
$perCase = @{}
$keptFixtures = @()
foreach ($entry in $sel) {
    $cid = $entry.id
    $res = $script:Results[$cid]
    $perCase[$cid] = $res.status
    if ($res.status -eq 'PASS') { $passCases++ } else {
        $failCases++
        $failingIds += $cid
        if ($null -ne $res.fixture -and (Test-Path -LiteralPath $res.fixture)) { $keptFixtures += $res.fixture }
    }
}

$failingReasons = [ordered]@{}
foreach ($cid in $failingIds) {
    $fr = [string]($script:Results[$cid].failures -join ' | ')
    if ($fr.Length -gt 2000) { $fr = $fr.Substring(0, 2000) }
    $failingReasons[$cid] = $fr
}
$summary = [ordered]@{
    total_cases = $totalCases
    pass_cases = $passCases
    fail_cases = $failCases
    failing_case_ids = $failingIds
    failing_reasons = $failingReasons
    per_case_status = $perCase
    kept_fixtures = $keptFixtures
}
$summaryJson = $summary | ConvertTo-Json -Depth 4 -Compress
Write-Output $summaryJson
exit $exitCode


#AMT_APPEND_CHUNK6


# memory-tool.ps1 - Bionic Auxiliary Memory (BAM) machine tool
# Bundle: BIONIC_AUX_MEM v0.5
# Authority: BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3 (frozen), 01_CANONICAL_NORMATIVE_SPECIFICATION.md (frozen design),
#            04_TEST_FIRST_SPECIFICATION.md (frozen test spec).
# Platform: Windows PowerShell 5.1. No network. No transcript access. No runtime dependencies. No daemon.
# Output: exactly one JSON line on stdout. No log files.
# Exit: 0 = PASS/HIT/MISS. 1 = INVALID/STALE/UNVERIFIED/BLOCKED/FAILED (operational).
#       2 = pre-operation usage error (status FAILED + diagnostics USAGE_ERROR).
# Test-only parameters: -TestMode and -FaultAt exist in this script as a test-only pair.
# They are accepted only as a complete pair and only when all three fault-seam gates hold.
# No claim is made that this tool can identify the caller as AI client or selftest.
# NOTE: ASCII-only source file (no non-ASCII bytes).

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Validate', 'Status', 'Recall', 'Commit', 'Forget', 'Restore', 'AbortPending', 'FilterDeepOut')]
    [string]$Mode,

    [Parameter(Mandatory = $true)][string]$MemoryRoot,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,

    [string]$ScratchpadRoot = '',
    [string]$Spec = '',
    [string]$PendingOperationId = '',
    [string]$Query = '',
    [int]$Max = 5,
    [string]$Out = '',
    [int]$LockTimeoutSeconds = 10,

    [switch]$TestMode,
    [string]$FaultAt = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TEMP DEBUG TRAP (env-gated; removed before final run)
trap {
    if ($env:BAM_DEBUG_ERROR -eq '1') {
        try {
            $ex = $_.Exception
            $ii = $_.InvocationInfo
            $rec = ($_ | Out-String)
            $stack = (Get-PSCallStack) | ForEach-Object { ('  {0}:{1} :: {2}' -f $_.ScriptName, $_.ScriptLineNumber, $_.Command) }
            $msg = 'BAM_DEBUG_ERROR' + "`n" +
                   'EX_TYPE=' + $ex.GetType().FullName + "`n" +
                   'EX_MSG=' + $ex.Message + "`n" +
                   'II_SCRIPT=' + $ii.ScriptName + "`n" +
                   'II_LINE=' + $ii.ScriptLineNumber + "`n" +
                   'II_LINECONTENT=' + $ii.Line + "`n" +
                   'II_POS=' + $ii.PositionMessage + "`n" +
                   'RECORD:' + "`n" + $rec + "`n" +
                   'STACK:' + "`n" + $stack
            [System.IO.File]::WriteAllText($env:BAM_DEBUG_ERROR_FILE, $msg, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    break
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
try {
    [Console]::OutputEncoding = $script:Utf8NoBom
    [Console]::InputEncoding = $script:Utf8NoBom
    $OutputEncoding = $script:Utf8NoBom
} catch { }

# ---------------------------------------------------------------------------
# Constants (frozen design values)
# ---------------------------------------------------------------------------
$script:ProdWorkspaceRoot = (Split-Path (Split-Path (Split-Path $PSCommandPath)))
$script:ProdMemoryRoot = $script:ProdWorkspaceRoot + '\memory'

$script:CoreRecMax = 30
$script:CoreByteMax = 4096
$script:IndexRecMax = 100
$script:IndexByteMax = 65536
$script:NoteByteMax = 32768
$script:SubjectMax = 64
$script:SummaryMax = 256
$script:TagsMax = 4
$script:TagPattern = '^[a-z0-9-]{1,32}$'
$script:UuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$script:Hex64Pattern = '^[0-9a-f]{64}$'
$script:MemIdPattern = '^mem_[0-9]{4}$'
$script:BamAtomic = $null
$script:DatePattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
$script:ProvenanceSet = @('USER_STATED', 'MACHINE_VERIFIED', 'AI_INFERRED', 'UNVERIFIED')
$script:ForbiddenTokens = @('GO_STATE', 'AUTHORIZED', 'EXECUTION_AUTHORIZATION', 'VALID_GO', 'APPROVED_TO_EXECUTE')
$script:FaultPoints = @(
    'FAULT_BEFORE_CURRENT_SWITCH',
    'FAULT_AFTER_CURRENT_SWITCH',
    'FAULT_BEFORE_RECEIPT_ARCHIVE',
    'FAULT_AFTER_RECEIPT_ARCHIVE',
    'FAULT_ACTIVE_TORN',
    'FAULT_BEFORE_STDOUT',
    'FAULT_POSTSWITCH_REVALIDATE'
)
$script:CoreHeader = '# memory-core v1'
$script:IndexHeader = '# memory-index v1'
$script:ArchiveHeader = '# memory-archive v1'
$script:OutMaxBytes = 262144

# Fault state (test-only; zero state change guarantees hold at every fault point)
$script:FaultArmed = $false
$script:FaultPoint = ''
$script:FaultActiveTorn = $false

# Runtime paths (filled during parameter validation)
$script:MemFull = ''
$script:WsFull = ''
$script:SpFull = ''
$script:GenRoot = ''
$script:ReceiptsDir = ''
$script:LockPath = ''

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------
function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TextSha256Hex {
    param([string]$Text)
    return Get-Sha256Hex -Bytes $script:Utf8NoBom.GetBytes($Text)
}

function Get-DirBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force)) { $sum += $f.Length }
    return $sum
}

function Test-PathInside {
    param([string]$Path, [string]$Root)
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    return ($p -ieq $r) -or $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathHasDotDotSegment {
    param([string]$Path)
    foreach ($seg in ($Path -split '[\\/]+')) { if ($seg -eq '..') { return $true } }
    return $false
}

function Test-PathComponentReparse {
    param([string]$Path)
    $p = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        if (Test-Path -LiteralPath $p) {
            try {
                $item = Get-Item -LiteralPath $p -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
            } catch { }
        }
        $parent = Split-Path -Parent $p
        if ([string]::IsNullOrEmpty($parent) -or $parent -ieq $p) { break }
        $p = $parent
    }
    return $false
}

function Read-StrictUtf8 {
    param([byte[]]$Bytes)
    # returns @{ ok; code; text; bytes }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return @{ ok = $false; code = 'BOM_PRESENT'; text = $null; bytes = $Bytes }
    }
    try {
        $text = $script:Utf8NoBom.GetString($Bytes)
        return @{ ok = $true; code = ''; text = $text; bytes = $Bytes }
    } catch {
        return @{ ok = $false; code = 'UTF8_INVALID'; text = $null; bytes = $Bytes }
    }
}

function Read-FileStrict {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return Read-StrictUtf8 -Bytes $Bytes
}

function Write-FileExact {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-FileBytesFlushed {
    param([string]$Path, [byte[]]$Bytes)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Write($Bytes, 0, $Bytes.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
}

function Get-GenDirName {
    param([int]$N)
    return $N.ToString('000000')
}

function Get-GenDir {
    param([int]$N)
    return (Join-Path $script:GenRoot (Get-GenDirName -N $N))
}

function Get-DateToday {
    return (Get-Date).ToString('yyyy-MM-dd')
}

function Test-ValidCalendarDate {
    param([string]$S)
    if ($S -notmatch $script:DatePattern) { return $false }
    $y = [int]$S.Substring(0, 4); $m = [int]$S.Substring(5, 2); $d = [int]$S.Substring(8, 2)
    try {
        $dt = New-Object System.DateTime($y, $m, $d)
        return ($dt.Year -eq $y -and $dt.Month -eq $m -and $dt.Day -eq $d)
    } catch { return $false }
}

function Test-ContainsForbiddenToken {
    param([string]$Text)
    foreach ($t in $script:ForbiddenTokens) {
        if ($Text -match ('(^|[^A-Za-z0-9_])' + [regex]::Escape($t) + '($|[^A-Za-z0-9_])')) { return $true }
    }
    return $false
}

# Lazy P/Invoke for atomic same-volume replace (MOVEFILE_REPLACE_EXISTING).
# File.Replace is unreliable in this runtime (throws "path is not of a legal form"
# on legal paths); the underlying MoveFileEx Win32 API works and is the atomic primitive.
function Initialize-AtomicReplaceApi {
    if ($null -ne $script:BamAtomic) { return }
    $sig = @'
using System;
using System.Runtime.InteropServices;
public class BamAtomic {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool MoveFileExW(string lpExistingFileName, string lpNewFileName, uint dwFlags);
}
'@
    Add-Type -TypeDefinition $sig -Language CSharp
    $script:BamAtomic = [BamAtomic]
}

# Atomic same-volume replace: temp write + flush + MoveFileEx(MOVEFILE_REPLACE_EXISTING)
# (existing target) or File.Move (first creation, no existing target).
function Set-PointerAtomic {
    param([string]$Target, [string]$Text, [string]$Tag)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $tmp = $Target + '.' + $Tag + '.tmp'
    Write-FileBytesFlushed -Path $tmp -Bytes $bytes
    if (Test-Path -LiteralPath $Target) {
        Initialize-AtomicReplaceApi
        $ok = $script:BamAtomic::MoveFileExW($tmp, $Target, 0x1)
        if (-not $ok) { throw (New-Object System.IO.IOException ('atomic_replace_failed win32=' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) }
    } else {
        [System.IO.File]::Move($tmp, $Target)
    }
}

function Remove-DirTree {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.Directory]::Delete($Path, $true)
    }
}

# ---------------------------------------------------------------------------
# Pointer (ACTIVE / CURRENT) parsing
# ---------------------------------------------------------------------------
function Parse-ActivePointer {
    param([string]$Path)
    # 7-line receipt. returns @{ ok; code; rec }
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $true; code = 'ABSENT'; rec = $null } }
    $rd = Read-FileStrict -Path $Path
    if (-not $rd.ok) { return @{ ok = $false; code = $rd.code; rec = $null } }
    $lines = $rd.text -split "`n"
    if ($lines.Count -lt 2 -and $lines.Count -eq 1 -and $lines[0] -eq '') { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    # tolerate trailing empty line from final newline
    if ($lines.Count -ge 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    if ($lines.Count -ne 7) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    $vals = @{}
    $want = @('GENERATION', 'OPERATION_ID', 'SPEC_SHA256', 'STATE_SHA256', 'ACTION', 'AFFECTED_IDS', 'RESULT')
    for ($i = 0; $i -lt 7; $i++) {
        $ln = $lines[$i]
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
        $k = $ln.Substring(0, $eq); $v = $ln.Substring($eq + 1)
        if ($k -ne $want[$i]) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
        $vals[$k] = $v
    }
    if ($vals['RESULT'] -ne 'PASS') { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['GENERATION'] -notmatch '^[1-9][0-9]*$') { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['OPERATION_ID'] -notmatch $script:UuidPattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['SPEC_SHA256'] -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['STATE_SHA256'] -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['ACTION'] -notin @('initialize', 'commit', 'forget', 'restore')) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['AFFECTED_IDS'] -ne '-' -and $vals['AFFECTED_IDS'] -notmatch '^(mem_[0-9]{4}(,mem_[0-9]{4})*)$') { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    $rec = @{
        generation = [int]$vals['GENERATION']
        operation_id = $vals['OPERATION_ID']
        spec_sha256 = $vals['SPEC_SHA256']
        state_sha256 = $vals['STATE_SHA256']
        action = $vals['ACTION']
        affected_ids = $vals['AFFECTED_IDS']
        text = $rd.text
    }
    return @{ ok = $true; code = 'PRESENT'; rec = $rec }
}

function Parse-CurrentPointer {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $true; code = 'ABSENT'; rec = $null } }
    $rd = Read-FileStrict -Path $Path
    if (-not $rd.ok) { return @{ ok = $false; code = $rd.code; rec = $null } }
    $lines = $rd.text -split "`n"
    if ($lines.Count -ge 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    if ($lines.Count -ne 4) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    $vals = @{}
    $want = @('GENERATION', 'OPERATION_ID', 'SPEC_SHA256', 'STATE_SHA256')
    for ($i = 0; $i -lt 4; $i++) {
        $ln = $lines[$i]
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
        $k = $ln.Substring(0, $eq); $v = $ln.Substring($eq + 1)
        if ($k -ne $want[$i]) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
        $vals[$k] = $v
    }
    if ($vals['GENERATION'] -notmatch '^[1-9][0-9]*$') { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['OPERATION_ID'] -notmatch $script:UuidPattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['SPEC_SHA256'] -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    if ($vals['STATE_SHA256'] -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'FORMAT'; rec = $null } }
    $rec = @{
        generation = [int]$vals['GENERATION']
        operation_id = $vals['OPERATION_ID']
        spec_sha256 = $vals['SPEC_SHA256']
        state_sha256 = $vals['STATE_SHA256']
    }
    return @{ ok = $true; code = 'PRESENT'; rec = $rec }
}

# ---------------------------------------------------------------------------
# Record line parsing / serialization (D2.1, 10 fields)
# ---------------------------------------------------------------------------
function Parse-RecordLine {
    param([string]$Line)
    # returns @{ ok; rec; code }
    $f = $Line -split '\|'
    if ($f.Count -ne 10) { return @{ ok = $false; code = 'FIELD_COUNT'; rec = $null } }
    $rec = @{
        id = $f[0]; recorded_at = $f[1]; subject = $f[2]; tags = $f[3]
        provenance = $f[4]; source_pointer = $f[5]; note_pointer = $f[6]
        lifecycle = $f[7]; supersedes_id = $f[8]; summary = $f[9]
    }
    if ($rec.id -notmatch $script:MemIdPattern) { return @{ ok = $false; code = 'MEMID'; rec = $null } }
    if ($rec.recorded_at -notmatch $script:DatePattern) { return @{ ok = $false; code = 'DATE'; rec = $null } }
    if ($rec.subject.Length -lt 1 -or $rec.subject.Length -gt $script:SubjectMax) { return @{ ok = $false; code = 'SUBJECT'; rec = $null } }
    if ($rec.summary.Length -lt 1 -or $rec.summary.Length -gt $script:SummaryMax) { return @{ ok = $false; code = 'SUMMARY'; rec = $null } }
    if ($rec.provenance -notin $script:ProvenanceSet) { return @{ ok = $false; code = 'PROVENANCE'; rec = $null } }
    if ($rec.lifecycle -notin @('pinned', 'active')) { return @{ ok = $false; code = 'LIFECYCLE'; rec = $null } }
    if ($rec.source_pointer -ne '-' -and $rec.source_pointer -notmatch '^[^\\|]+$') { return @{ ok = $false; code = 'SOURCE'; rec = $null } }
    if ($rec.source_pointer -eq '-' -and $rec.provenance -ne 'USER_STATED') { return @{ ok = $false; code = 'SOURCE_RULE'; rec = $null } }
    if ($rec.note_pointer -ne '-') {
        if ($rec.note_pointer -ne ('notes/' + $rec.id + '.md')) { return @{ ok = $false; code = 'NOTE_POINTER'; rec = $null } }
    }
    if ($rec.supersedes_id -ne '-' -and $rec.supersedes_id -notmatch $script:MemIdPattern) { return @{ ok = $false; code = 'SUPERSEDES'; rec = $null } }
    $tagArr = @()
    if ($rec.tags -ne '') {
        $tagArr = @($rec.tags -split ';')
        if ($tagArr.Count -gt $script:TagsMax) { return @{ ok = $false; code = 'TAGS'; rec = $null } }
        foreach ($t in $tagArr) { if ($t -cnotmatch $script:TagPattern) { return @{ ok = $false; code = 'TAGS'; rec = $null } } }
    }
    $rec.tag_list = $tagArr
    return @{ ok = $true; code = ''; rec = $rec }
}

function Get-RecordLine {
    param($Rec)
    $tags = ($Rec.tag_list -join ';')
    return ($Rec.id + '|' + $Rec.recorded_at + '|' + $Rec.subject + '|' + $tags + '|' + $Rec.provenance + '|' + $Rec.source_pointer + '|' + $Rec.note_pointer + '|' + $Rec.lifecycle + '|' + $Rec.supersedes_id + '|' + $Rec.summary)
}

function Test-PinTrue {
    param($Pin)
    if ($null -eq $Pin) { return $false }
    if ($Pin -is [bool]) { return $Pin }
    $s = "$($Pin)".Trim().ToLowerInvariant()
    return ($s -eq 'true' -or $s -eq '$true' -or $s -eq '1')
}

# ---------------------------------------------------------------------------
# Generation (directory) load / validation
# ---------------------------------------------------------------------------
function Load-Generation {
    param([string]$Dir, [int]$ExpectedGen)
    # returns @{ ok; code; state; core; index; archiveLines; notes; coreBytes; indexBytes; archiveBytes; stateBytes }
    # core/index = list of parsed records (ordered as on disk, header excluded)
    if (-not (Test-Path -LiteralPath $Dir)) { return @{ ok = $false; code = 'GEN_MISSING' } }
    $corePath = Join-Path $Dir 'core.md'
    $indexPath = Join-Path $Dir 'index.md'
    $archivePath = Join-Path $Dir 'archive.md'
    $statePath = Join-Path $Dir 'STATE'
    $notesDir = Join-Path $Dir 'notes'
    foreach ($p in @($corePath, $indexPath, $archivePath, $statePath)) {
        if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; code = 'FILE_MISSING' } }
    }
    $out = @{ ok = $true; code = '' }
    $files = @{ core = $corePath; index = $indexPath; archive = $archivePath; state = $statePath }
    $texts = @{}; $bytesMap = @{}
    foreach ($k in @('core', 'index', 'archive', 'state')) {
        $rd = Read-FileStrict -Path $files[$k]
        if (-not $rd.ok) { return @{ ok = $false; code = $rd.code } }
        $texts[$k] = $rd.text
        $bytesMap[$k] = $rd.bytes
    }
    $out.coreBytes = $bytesMap['core'].Length
    $out.indexBytes = $bytesMap['index'].Length
    $out.archiveBytes = $bytesMap['archive'].Length
    $out.stateBytes = $bytesMap['state'].Length

    # STATE parse (D2.5): 11-line head + NOTE_SHA256 lines
    $stateLines = $texts['state'] -split "`n"
    if ($stateLines.Count -ge 1 -and $stateLines[-1] -eq '') { $stateLines = $stateLines[0..($stateLines.Count - 2)] }
    if ($stateLines.Count -lt 11) { return @{ ok = $false; code = 'STATE_HEAD' } }
    $head = $stateLines[0..10]
    if ($stateLines.Count -gt 11) { $noteLines = @($stateLines[11..($stateLines.Count - 1)]) } else { $noteLines = @() }
    $wantKeys = @('GENERATION', 'OPERATION_ID', 'SPEC_SHA256', 'AFFECTED_IDS', 'ACTION', 'CORE_SHA256', 'CORE_BYTES', 'INDEX_SHA256', 'INDEX_BYTES', 'ARCHIVE_SHA256', 'ARCHIVE_BYTES')
    $hv = @{}
    for ($i = 0; $i -lt 11; $i++) {
        $ln = $head[$i]
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { return @{ ok = $false; code = 'STATE_HEAD' } }
        $k = $ln.Substring(0, $eq); $v = $ln.Substring($eq + 1)
        if ($k -ne $wantKeys[$i]) { return @{ ok = $false; code = 'STATE_HEAD' } }
        $hv[$k] = $v
    }
    if ($hv['GENERATION'] -ne ([string]$ExpectedGen)) { return @{ ok = $false; code = 'STATE_GEN' } }
    if ($hv['OPERATION_ID'] -notmatch $script:UuidPattern) { return @{ ok = $false; code = 'STATE_OP' } }
    if ($hv['SPEC_SHA256'] -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'STATE_SPEC' } }
    if ($hv['AFFECTED_IDS'] -ne '-' -and $hv['AFFECTED_IDS'] -notmatch '^(mem_[0-9]{4}(,mem_[0-9]{4})*)$') { return @{ ok = $false; code = 'STATE_AFFECTED' } }
    if ($hv['ACTION'] -notin @('initialize', 'commit', 'forget', 'restore')) { return @{ ok = $false; code = 'STATE_ACTION' } }
    $noteExpected = @{}
    foreach ($ln in $noteLines) {
        if ($ln -notmatch '^NOTE_SHA256=(mem_[0-9]{4}):([0-9a-f]{64}):([0-9]+)$') { return @{ ok = $false; code = 'STATE_NOTE_LINE' } }
        $noteExpected[$Matches[1]] = @{ sha = $Matches[2]; bytes = [int]$Matches[3] }
    }
    # sorted by memory_id check
    $ids = @($noteExpected.Keys | Sort-Object)
    $seen = @{}
    foreach ($ln in $noteLines) {
        $m2 = [regex]::Match($ln, '^NOTE_SHA256=(mem_[0-9]{4}):')
        if ($seen.ContainsKey($m2.Groups[1].Value)) { return @{ ok = $false; code = 'STATE_NOTE_DUP' } }
        $seen[$m2.Groups[1].Value] = $true
    }
    $out.state = @{
        generation = [int]$hv['GENERATION']
        operation_id = $hv['OPERATION_ID']
        spec_sha256 = $hv['SPEC_SHA256']
        affected_ids = $hv['AFFECTED_IDS']
        action = $hv['ACTION']
        core_sha256 = $hv['CORE_SHA256']; core_bytes = [int]$hv['CORE_BYTES']
        index_sha256 = $hv['INDEX_SHA256']; index_bytes = [int]$hv['INDEX_BYTES']
        archive_sha256 = $hv['ARCHIVE_SHA256']; archive_bytes = [int]$hv['ARCHIVE_BYTES']
        note_expected = $noteExpected
        text = $texts['state']
    }

    # hash / byte verification of core/index/archive
    foreach ($k in @('core', 'index', 'archive')) {
        $sha = Get-Sha256Hex -Bytes $bytesMap[$k]
        $key = ($k.ToUpperInvariant() + '_SHA256')
        if ($sha -cne $out.state[$key.ToLowerInvariant()]) { return @{ ok = $false; code = 'HASH_MISMATCH' } }
    }
    if ($out.coreBytes -ne $out.state.core_bytes) { return @{ ok = $false; code = 'BYTES_MISMATCH' } }
    if ($out.indexBytes -ne $out.state.index_bytes) { return @{ ok = $false; code = 'BYTES_MISMATCH' } }
    if ($out.archiveBytes -ne $out.state.archive_bytes) { return @{ ok = $false; code = 'BYTES_MISMATCH' } }

    # parse record lines
    $coreRecs = New-Object System.Collections.Generic.List[object]
    $indexRecs = New-Object System.Collections.Generic.List[object]
    $parseCore = $texts['core'] -split "`n"
    if ($parseCore.Count -ge 1 -and $parseCore[-1] -eq '') { $parseCore = $parseCore[0..($parseCore.Count - 2)] }
    if ($parseCore.Count -lt 1 -or $parseCore[0] -ne $script:CoreHeader) { return @{ ok = $false; code = 'HEADER' } }
    for ($i = 1; $i -lt $parseCore.Count; $i++) {
        if ($parseCore[$i] -eq '') { return @{ ok = $false; code = 'EMPTY_LINE' } }
        $pr = Parse-RecordLine -Line $parseCore[$i]
        if (-not $pr.ok) { return @{ ok = $false; code = $pr.code } }
        $coreRecs.Add($pr.rec)
    }
    $parseIndex = $texts['index'] -split "`n"
    if ($parseIndex.Count -ge 1 -and $parseIndex[-1] -eq '') { $parseIndex = $parseIndex[0..($parseIndex.Count - 2)] }
    if ($parseIndex.Count -lt 1 -or $parseIndex[0] -ne $script:IndexHeader) { return @{ ok = $false; code = 'HEADER' } }
    for ($i = 1; $i -lt $parseIndex.Count; $i++) {
        if ($parseIndex[$i] -eq '') { return @{ ok = $false; code = 'EMPTY_LINE' } }
        $pr = Parse-RecordLine -Line $parseIndex[$i]
        if (-not $pr.ok) { return @{ ok = $false; code = $pr.code } }
        $indexRecs.Add($pr.rec)
    }
    $archiveLines = New-Object System.Collections.Generic.List[string]
    $parseArchive = $texts['archive'] -split "`n"
    if ($parseArchive.Count -ge 1 -and $parseArchive[-1] -eq '') { $parseArchive = $parseArchive[0..($parseArchive.Count - 2)] }
    if ($parseArchive.Count -lt 1 -or $parseArchive[0] -ne $script:ArchiveHeader) { return @{ ok = $false; code = 'HEADER' } }
    for ($i = 1; $i -lt $parseArchive.Count; $i++) {
        $ln = $parseArchive[$i]
        if ($ln -eq '') { return @{ ok = $false; code = 'EMPTY_LINE' } }
        $pp = $ln.IndexOf('|')
        if ($pp -lt 1) { return @{ ok = $false; code = 'ARCHIVE_LINE' } }
        $archAt = $ln.Substring(0, $pp)
        $reason = $ln.Substring($pp + 1)
        $q = $reason.IndexOf('|')
        if ($q -lt 1) { return @{ ok = $false; code = 'ARCHIVE_LINE' } }
        $reasonVal = $reason.Substring(0, $q)
        $origLine = $reason.Substring($q + 1)
        if ($archAt -notmatch $script:DatePattern) { return @{ ok = $false; code = 'ARCHIVE_LINE' } }
        if ($reasonVal -notin @('superseded', 'evicted', 'forgotten')) { return @{ ok = $false; code = 'ARCHIVE_LINE' } }
        $pr2 = Parse-RecordLine -Line $origLine
        if (-not $pr2.ok) { return @{ ok = $false; code = 'ARCHIVE_LINE' } }
        $archiveLines.Add($ln)
    }

    # notes verification
    $notes = @{}
    if (Test-Path -LiteralPath $notesDir) {
        foreach ($nf in (Get-ChildItem -LiteralPath $notesDir -File -Force)) {
            if ($nf.Name -notmatch '^mem_[0-9]{4}\.md$') { return @{ ok = $false; code = 'NOTE_NAME' } }
            $mid = $nf.Name.Substring(0, 8)
            if (-not $noteExpected.ContainsKey($mid)) { return @{ ok = $false; code = 'NOTE_UNLISTED' } }
            $nb = [System.IO.File]::ReadAllBytes($nf.FullName)
            $nrd = Read-StrictUtf8 -Bytes $nb
            if (-not $nrd.ok) { return @{ ok = $false; code = $nrd.code } }
            $nsha = Get-Sha256Hex -Bytes $nb
            if ($nsha -cne $noteExpected[$mid].sha) { return @{ ok = $false; code = 'NOTE_HASH' } }
            if ($nb.Length -ne $noteExpected[$mid].bytes) { return @{ ok = $false; code = 'NOTE_BYTES' } }
            $notes[$mid] = $nrd.text
        }
    }
    foreach ($mid in $noteExpected.Keys) {
        if (-not $notes.ContainsKey($mid)) { return @{ ok = $false; code = 'NOTE_MISSING' } }
    }

    # bounds
    if ($coreRecs.Count -gt $script:CoreRecMax) { return @{ ok = $false; code = 'CORE_REC_BOUND' } }
    if ($coreRecs.Count -gt 0 -and $out.coreBytes -gt ($script:CoreHeader.Length + 1 + $script:CoreByteMax)) { return @{ ok = $false; code = 'CORE_BYTE_BOUND' } }
    if ($indexRecs.Count -gt $script:IndexRecMax) { return @{ ok = $false; code = 'INDEX_REC_BOUND' } }
    if ($indexRecs.Count -gt 0 -and $out.indexBytes -gt ($script:IndexHeader.Length + 1 + $script:IndexByteMax)) { return @{ ok = $false; code = 'INDEX_BYTE_BOUND' } }
    # CORE subseteq INDEX invariant
    foreach ($cr in $coreRecs) {
        $found = $false
        foreach ($ir in $indexRecs) {
            if ($ir.id -eq $cr.id) { $found = $true; break }
        }
        if (-not $found) { return @{ ok = $false; code = 'CORE_INDEX' } }
    }

    $out.core = $coreRecs
    $out.index = $indexRecs
    $out.archiveLines = $archiveLines
    $out.notes = $notes
    return $out
}

# ---------------------------------------------------------------------------
# Output (single JSON line)
# ---------------------------------------------------------------------------
$script:Exitted = $false
function Out-Result {
    param(
        [string]$Status,
        [string]$Operation,
        $Records,
        $StateId,
        $Diagnostics,
        $Extra
    )
    if ($script:Exitted) { return }
    $script:Exitted = $true
    $recs = @()
    if ($null -ne $Records) { $recs = @($Records) }
    $diags = @()
    if ($null -ne $Diagnostics) { $diags = @($Diagnostics) }
    $obj = [ordered]@{}
    $obj['status'] = $Status
    $obj['operation'] = $Operation
    $obj['records'] = $recs
    $obj['state_id'] = $StateId
    $obj['diagnostics'] = $diags
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    }
    $json = ($obj | ConvertTo-Json -Depth 12 -Compress)
    [Console]::Out.Write($json + "`n")
    [Console]::Out.Flush()
    $code = 1
    if ($Status -eq 'PASS' -or $Status -eq 'HIT' -or $Status -eq 'MISS') { $code = 0 }
    if ($code -eq 1 -and ($diags -contains 'USAGE_ERROR')) { $code = 2 }
    exit $code
}

function Get-EmptyStateId {
    $cur = [ordered]@{}
    $cur['generation'] = 0
    $cur['operation_id'] = 'INITIAL_EMPTY'
    $sid = [ordered]@{}
    $sid['generation'] = 0
    $sid['operation_id'] = 'INITIAL_EMPTY'
    $sid['spec_sha256'] = 'ABSENT'
    $sid['core_sha256'] = 'ABSENT'
    $sid['index_sha256'] = 'ABSENT'
    $sid['archive_sha256'] = 'ABSENT'
    $sid['current'] = $cur
    return $sid
}

function Get-StateIdFromActive {
    param($ActiveRec, $State, $CurrentRec)
    $sid = [ordered]@{}
    $sid['generation'] = $ActiveRec.generation
    $sid['operation_id'] = $ActiveRec.operation_id
    $sid['spec_sha256'] = $ActiveRec.spec_sha256
    $sid['core_sha256'] = $State.core_sha256
    $sid['index_sha256'] = $State.index_sha256
    $sid['archive_sha256'] = $State.archive_sha256
    $cur = [ordered]@{}
    if ($null -ne $CurrentRec) {
        $cur['generation'] = $CurrentRec.generation
        $cur['operation_id'] = $CurrentRec.operation_id
    } else {
        $cur['generation'] = $ActiveRec.generation
        $cur['operation_id'] = $ActiveRec.operation_id
    }
    $sid['current'] = $cur
    return $sid
}

# ---------------------------------------------------------------------------
# Fault seam (test-only)
# ---------------------------------------------------------------------------
function Get-FixtureRootOfMemoryRoot {
    param([string]$MemRootFull)
    $temp = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $needle = $temp + '\'
    if (-not $MemRootFull.StartsWith($needle, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $rel = $MemRootFull.Substring($needle.Length)
    $first = ($rel -split '\\')[0]
    if ($first -match '^bam-test-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        return ($temp + '\' + $first)
    }
    return $null
}

function Test-FaultGates {
    param([string]$MemRootFull)
    $fixtureRoot = Get-FixtureRootOfMemoryRoot -MemRootFull $MemRootFull
    if ($null -eq $fixtureRoot) { return $false }
    if (Test-PathInside -Path $MemRootFull -Root $script:ProdWorkspaceRoot) { return $false }
    return $true
}

function Invoke-Fault {
    param([string]$Point)
    if (-not $script:FaultArmed) { return }
    if ($script:FaultPoint -ne $Point) { return }
    switch ($Point) {
        'FAULT_ACTIVE_TORN' { $script:FaultActiveTorn = $true; break }
    }
    [Console]::Out.Flush()
    exit 1
}

# ---------------------------------------------------------------------------
# Base state resolution (lock-free read path helper)
# ---------------------------------------------------------------------------
function Resolve-BaseState {
    # returns @{ ok; code; active (rec or null); current (rec or null); genA (int, 0 if none) }
    $ap = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
    $cp = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
    if (-not $ap.ok) { return @{ ok = $false; code = $ap.code; active = $null; current = $null; genA = 0 } }
    if (-not $cp.ok) { return @{ ok = $false; code = $cp.code; active = $null; current = $null; genA = 0 } }
    $active = $ap.rec; $current = $cp.rec
    $genA = 0
    if ($null -ne $active) { $genA = $active.generation }
    if ($null -eq $active -and $null -eq $current) {
        return @{ ok = $true; code = 'EMPTY'; active = $null; current = $null; genA = 0 }
    }
    if ($null -ne $active -and $null -ne $current) {
        if ($current.generation -ne $active.generation -and $current.generation -ne ($active.generation + 1)) {
            return @{ ok = $false; code = 'POINTER_INCONSISTENT'; active = $active; current = $current; genA = $genA }
        }
        if ($current.generation -eq $active.generation) {
            if ($current.operation_id -cne $active.operation_id -or $current.spec_sha256 -cne $active.spec_sha256 -or $current.state_sha256 -cne $active.state_sha256) {
                return @{ ok = $false; code = 'POINTER_INCONSISTENT'; active = $active; current = $current; genA = $genA }
            }
        }
        return @{ ok = $true; code = 'OK'; active = $active; current = $current; genA = $genA }
    }
    if ($null -ne $active -and $null -eq $current) {
        return @{ ok = $false; code = 'CURRENT_MISSING'; active = $active; current = $null; genA = $genA }
    }
    if ($null -eq $active -and $null -ne $current) {
        if ($current.generation -ne 1) {
            return @{ ok = $false; code = 'FIRST_PENDING_INVALID'; active = $null; current = $current; genA = 0 }
        }
        return @{ ok = $true; code = 'FIRST_PENDING'; active = $null; current = $current; genA = 0 }
    }
    return @{ ok = $false; code = 'UNKNOWN'; active = $active; current = $current; genA = $genA }
}

function Get-BaseStateId {
    param($Base)
    if ($null -eq $Base.active) {
        $sid = Get-EmptyStateId
        if ($null -ne $Base.current) {
            $sid['current']['generation'] = $Base.current.generation
            $sid['current']['operation_id'] = $Base.current.operation_id
        }
        return $sid
    }
    $st = Load-Generation -Dir (Get-GenDir -N $Base.active.generation) -ExpectedGen $Base.active.generation
    if (-not $st.ok) {
        $sid = Get-EmptyStateId
        $sid['generation'] = $Base.active.generation
        $sid['operation_id'] = $Base.active.operation_id
        $sid['spec_sha256'] = $Base.active.spec_sha256
        if ($null -ne $Base.current) {
            $sid['current']['generation'] = $Base.current.generation
            $sid['current']['operation_id'] = $Base.current.operation_id
        }
        return $sid
    }
    return Get-StateIdFromActive -ActiveRec $Base.active -State $st.state -CurrentRec $Base.current
}

function Get-PreOpStateId {
    # Frozen 04 USAGE_ERROR_RESULT: state_id = the last validated ACTIVE identity
    # of the valid memory root provided as input. Lock-free; zero state change.
    # Any failure falls back to the empty identity.
    try {
        if (-not (Test-Path -LiteralPath $script:MemFull)) { return (Get-EmptyStateId) }
        $b = Resolve-BaseState
        if (-not $b.ok) { return (Get-EmptyStateId) }
        return (Get-BaseStateId -Base $b)
    } catch { return (Get-EmptyStateId) }
}

# ---------------------------------------------------------------------------
# Parameter validation (pre-operation; structured usage errors)
# ---------------------------------------------------------------------------
function Test-RawPathClean {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $false }
    if (Test-PathHasDotDotSegment -Path $Raw) { return $false }
    $full = [System.IO.Path]::GetFullPath($Raw)
    if (-not [System.IO.Path]::IsPathRooted($full)) { return $false }
    if (Test-PathComponentReparse -Path $full) { return $false }
    return $true
}

$script:UsageDiag = @('USAGE_ERROR')
try {
    $script:MemFull = [System.IO.Path]::GetFullPath($MemoryRoot).TrimEnd('\')
} catch {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics $script:UsageDiag
}
try { [void][System.IO.Path]::GetFullPath($WorkspaceRoot) } catch {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}

$script:WsFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
$script:GenRoot = (Join-Path $script:MemFull '.gen')
$script:ReceiptsDir = (Join-Path $script:MemFull 'receipts')
$script:LockPath = (Join-Path $script:MemFull '.lock')

# Mode-specific required parameters (script-returned structured usage errors)
$needScratch = ($Mode -eq 'Commit' -or $Mode -eq 'Forget' -or $Mode -eq 'Restore' -or $Mode -eq 'FilterDeepOut')
$needSpec = ($Mode -eq 'Commit' -or $Mode -eq 'Forget' -or $Mode -eq 'Restore')
$needOut = ($Mode -eq 'FilterDeepOut')
$needQuery = ($Mode -eq 'Recall')
$needPending = ($Mode -eq 'AbortPending')
if ($needScratch -and [string]::IsNullOrWhiteSpace($ScratchpadRoot)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if ($needSpec -and [string]::IsNullOrWhiteSpace($Spec)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if ($needOut -and [string]::IsNullOrWhiteSpace($Out)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if ($needQuery -and [string]::IsNullOrWhiteSpace($Query)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if ($needPending -and [string]::IsNullOrWhiteSpace($PendingOperationId)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if ($needScratch) {
    $script:SpFull = [System.IO.Path]::GetFullPath($ScratchpadRoot).TrimEnd('\')
}

# Root cleanliness
$rootClean = $true
foreach ($rp in @($MemoryRoot, $WorkspaceRoot)) {
    if (-not (Test-RawPathClean -Raw $rp)) { $rootClean = $false }
}
if ($needScratch -and -not (Test-RawPathClean -Raw $ScratchpadRoot)) { $rootClean = $false }
if (-not $rootClean) {
    Out-Result -Status 'BLOCKED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics @()
}

# Fault-seam pair validation and gating (pre-operation).
# Ordering: fault-seam gating runs BEFORE the allowed-root check so that
# fault-seam denials (frozen 006.s/t/u) are reported as INVALID
# FAULT_SEAM_DENIED rather than a root BLOCKED result.
if ($TestMode -and [string]::IsNullOrWhiteSpace($FaultAt)) {
    Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
}
if (-not $TestMode -and -not [string]::IsNullOrWhiteSpace($FaultAt)) {
    Out-Result -Status 'INVALID' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics @('FAULT_SEAM_DENIED')
}
if ($TestMode -and -not [string]::IsNullOrWhiteSpace($FaultAt)) {
    if ($FaultAt -notin $script:FaultPoints) {
        Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics $script:UsageDiag
    }
    if (-not (Test-FaultGates -MemRootFull $script:MemFull)) {
        Out-Result -Status 'INVALID' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics @('FAULT_SEAM_DENIED')
    }
    $script:FaultArmed = $true
    $script:FaultPoint = $FaultAt
}

# Allowed root rule: memory root must be <WorkspaceRoot>\memory
$allowedMem = ($script:WsFull + '\memory')
if ($script:MemFull -cne $allowedMem) {
    Out-Result -Status 'BLOCKED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-PreOpStateId) -Diagnostics @()
}

# ---------------------------------------------------------------------------
# Writer lock
# ---------------------------------------------------------------------------
function New-WriterLock {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $fs = $null
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return $fs
        } catch {
            if ((Get-Date) -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 50
        }
    }
}

# ---------------------------------------------------------------------------
# Receipt helpers
# ---------------------------------------------------------------------------
function Parse-HistoricalReceipt {
    param([string]$Path, [string]$ExpectedOpId)
    # returns @{ ok; code; text; bytes; rec }
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $true; code = 'ABSENT'; text = $null; bytes = $null; rec = $null } }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 1024) { return @{ ok = $false; code = 'TOO_LARGE'; text = $null; bytes = $bytes; rec = $null } }
    $rd = Read-StrictUtf8 -Bytes $bytes
    if (-not $rd.ok) { return @{ ok = $false; code = $rd.code; text = $null; bytes = $bytes; rec = $null } }
    $pp = Parse-ActivePointer -Path $Path
    if (-not $pp.ok) { return @{ ok = $false; code = $pp.code; text = $rd.text; bytes = $bytes; rec = $null } }
    if ($pp.rec.operation_id -cne $ExpectedOpId) { return @{ ok = $false; code = 'UUID_MISMATCH'; text = $rd.text; bytes = $bytes; rec = $pp.rec } }
    return @{ ok = $true; code = 'PRESENT'; text = $rd.text; bytes = $bytes; rec = $pp.rec }
}

function Get-ReceiptText {
    param([int]$Generation, [string]$OperationId, [string]$SpecSha, [string]$StateSha, [string]$Action, [string]$AffectedIds)
    return ('GENERATION=' + $Generation + "`n" +
            'OPERATION_ID=' + $OperationId + "`n" +
            'SPEC_SHA256=' + $SpecSha + "`n" +
            'STATE_SHA256=' + $StateSha + "`n" +
            'ACTION=' + $Action + "`n" +
            'AFFECTED_IDS=' + $AffectedIds + "`n" +
            'RESULT=PASS' + "`n")
}

function Get-CurrentText {
    param([int]$Generation, [string]$OperationId, [string]$SpecSha, [string]$StateSha)
    return ('GENERATION=' + $Generation + "`n" +
            'OPERATION_ID=' + $OperationId + "`n" +
            'SPEC_SHA256=' + $SpecSha + "`n" +
            'STATE_SHA256=' + $StateSha + "`n")
}

function Build-STATEText {
    param([int]$Generation, [string]$OperationId, [string]$SpecSha, [string]$AffectedIds, [string]$Action,
          [byte[]]$CoreBytes, [byte[]]$IndexBytes, [byte[]]$ArchiveBytes, $Notes)
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('GENERATION=' + $Generation); $null = $sb.Append("`n")
    $null = $sb.Append('OPERATION_ID=' + $OperationId); $null = $sb.Append("`n")
    $null = $sb.Append('SPEC_SHA256=' + $SpecSha); $null = $sb.Append("`n")
    $null = $sb.Append('AFFECTED_IDS=' + $AffectedIds); $null = $sb.Append("`n")
    $null = $sb.Append('ACTION=' + $Action); $null = $sb.Append("`n")
    $null = $sb.Append('CORE_SHA256=' + (Get-Sha256Hex -Bytes $CoreBytes)); $null = $sb.Append("`n")
    $null = $sb.Append('CORE_BYTES=' + $CoreBytes.Length); $null = $sb.Append("`n")
    $null = $sb.Append('INDEX_SHA256=' + (Get-Sha256Hex -Bytes $IndexBytes)); $null = $sb.Append("`n")
    $null = $sb.Append('INDEX_BYTES=' + $IndexBytes.Length); $null = $sb.Append("`n")
    $null = $sb.Append('ARCHIVE_SHA256=' + (Get-Sha256Hex -Bytes $ArchiveBytes)); $null = $sb.Append("`n")
    $null = $sb.Append('ARCHIVE_BYTES=' + $ArchiveBytes.Length); $null = $sb.Append("`n")
    $ids = @()
    if ($null -ne $Notes) { $ids = @($Notes.Keys | Sort-Object) }
    foreach ($mid in $ids) {
        if ($null -eq $Notes[$mid]) { throw 'NULL_NOTE_IN_STATE_BUILD' }
        $nb = $script:Utf8NoBom.GetBytes($Notes[$mid])
        $null = $sb.Append('NOTE_SHA256=' + $mid + ':' + (Get-Sha256Hex -Bytes $nb) + ':' + $nb.Length); $null = $sb.Append("`n")
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Spec parsing and validation
# ---------------------------------------------------------------------------
function Parse-Spec {
    param([string]$SpecPath, [string]$ModeName)
    # returns @{ ok; code; spec; specSha }
    if (-not (Test-Path -LiteralPath $SpecPath)) { return @{ ok = $false; code = 'SPEC_MISSING'; spec = $null; specSha = '' } }
    $bytes = [System.IO.File]::ReadAllBytes($SpecPath)
    $rd = Read-StrictUtf8 -Bytes $bytes
    if (-not $rd.ok) { return @{ ok = $false; code = 'SPEC_ENCODE'; spec = $null; specSha = '' } }
    $spec = $null
    try { $spec = $rd.text | ConvertFrom-Json } catch { return @{ ok = $false; code = 'SPEC_JSON'; spec = $null; specSha = '' } }
    $specSha = Get-Sha256Hex -Bytes $bytes

    if (-not ($spec -is [System.Management.Automation.PSObject])) { return @{ ok = $false; code = 'SPEC_SHAPE'; spec = $null; specSha = $specSha } }
    $opId = $spec.operation_id
    if ($null -eq $opId -or "$opId" -notmatch $script:UuidPattern) { return @{ ok = $false; code = 'SPEC_OPID'; spec = $null; specSha = $specSha } }
    $exp = $spec.expected
    if ($null -eq $exp) { return @{ ok = $false; code = 'SPEC_EXPECTED'; spec = $null; specSha = $specSha } }
    $genExp = $exp.generation
    if ($null -eq $genExp -or "$genExp" -notmatch '^[0-9]+$') { return @{ ok = $false; code = 'SPEC_GEN'; spec = $null; specSha = $specSha } }
    foreach ($h in @('core', 'index', 'archive')) {
        $hv = "$($exp.$h)"
        if ($hv -ne 'ABSENT' -and $hv -notmatch $script:Hex64Pattern) { return @{ ok = $false; code = 'SPEC_HASH'; spec = $null; specSha = $specSha } }
    }
    $ops = $spec.operations
    if ($null -eq $ops -or -not ($ops -is [System.Collections.IEnumerable]) -or ($ops -is [string])) { return @{ ok = $false; code = 'SPEC_OPS'; spec = $null; specSha = $specSha } }
    $opList = @($ops)
    # Normalize optional op fields to be null-safe under Set-StrictMode -Version Latest.
    # JSON deserialization omits absent keys; reading an absent property throws
    # PropertyNotFoundStrict. Absent optional fields are treated as $null by the existing
    # -ne $null guards, so this changes no semantics; absent mandatory fields now yield the
    # intended SPEC_* error instead of a crash.
    $opFieldSet = @('op','subject','summary','provenance','pin','tags','note','evidence','supersedes','record_id')
    foreach ($o in $opList) {
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $have = @($o.PSObject.Properties.Name)
            foreach ($fn in $opFieldSet) {
                if ($have -notcontains $fn) { $o | Add-Member -MemberType NoteProperty -Name $fn -Value $null }
            }
        }
    }
    # 01 D3.4: Commit accepts 1-16 operations (re-confirmed by the 2026-10-12
    # amendment; larger fixtures are split into multiple <=16-operation commits:
    # 04 AM-T-010/011/027/044).
    if ($ModeName -eq 'Commit') {
        if ($opList.Count -lt 1 -or $opList.Count -gt 16) { return @{ ok = $false; code = 'SPEC_OP_COUNT'; spec = $null; specSha = $specSha } }
    } else {
        if ($opList.Count -ne 1) { return @{ ok = $false; code = 'SPEC_OP_COUNT'; spec = $null; specSha = $specSha } }
    }
    $initCount = 0
    foreach ($o in $opList) {
        $ot = "$($o.op)"
        if ($ModeName -eq 'Commit') {
            if ($ot -notin @('add', 'pin', 'unpin', 'initialize')) { return @{ ok = $false; code = 'SPEC_OP_TYPE'; spec = $null; specSha = $specSha } }
            if ($ot -eq 'initialize') {
                $initCount++
                continue
            }
            if ($ot -eq 'add') {
                $subj = "$($o.subject)"
                if ($subj.Length -lt 1 -or $subj.Length -gt $script:SubjectMax) { return @{ ok = $false; code = 'SPEC_SUBJECT'; spec = $null; specSha = $specSha } }
                if ($subj.IndexOf([char]124) -ge 0 -or $subj -match "`r|`n") { return @{ ok = $false; code = 'SPEC_SUBJECT'; spec = $null; specSha = $specSha } }
                $summ = "$($o.summary)"
                if ($summ.Length -lt 1 -or $summ.Length -gt $script:SummaryMax) { return @{ ok = $false; code = 'SPEC_SUMMARY'; spec = $null; specSha = $specSha } }
                if ($summ.IndexOf([char]124) -ge 0 -or $summ -match "`r|`n") { return @{ ok = $false; code = 'SPEC_SUMMARY'; spec = $null; specSha = $specSha } }
                if ($null -eq $o.provenance -or "$($o.provenance)" -notin $script:ProvenanceSet) { return @{ ok = $false; code = 'SPEC_PROV'; spec = $null; specSha = $specSha } }
                if ($null -ne $o.pin -and "$($o.pin)" -notin @('true', 'false', '$true', '$false')) { return @{ ok = $false; code = 'SPEC_PIN'; spec = $null; specSha = $specSha } }
                $tags = @()
                if ($null -ne $o.tags) {
                    if ($o.tags -is [string]) { return @{ ok = $false; code = 'SPEC_TAGS'; spec = $null; specSha = $specSha } }
                    $tags = @($o.tags)
                }
                if ($tags.Count -gt $script:TagsMax) { return @{ ok = $false; code = 'SPEC_TAGS'; spec = $null; specSha = $specSha } }
                foreach ($t in $tags) { if ("$t" -cnotmatch $script:TagPattern) { return @{ ok = $false; code = 'SPEC_TAGS'; spec = $null; specSha = $specSha } } }
                if ($null -ne $o.note) {
                    $nt = "$($o.note)"
                    $nb = $script:Utf8NoBom.GetBytes($nt)
                    if ($nb.Length -gt $script:NoteByteMax) { return @{ ok = $false; code = 'SPEC_NOTE_SIZE'; spec = $null; specSha = $specSha } }
                    if (Test-ContainsForbiddenToken -Text $nt) { return @{ ok = $false; code = 'SPEC_FORBIDDEN'; spec = $null; specSha = $specSha } }
                }
                $provS = "$($o.provenance)"
                if ($null -eq $o.evidence) {
                    if ($provS -ne 'USER_STATED') { return @{ ok = $false; code = 'SPEC_EVIDENCE_REQUIRED'; spec = $null; specSha = $specSha } }
                } else {
                    $ev = "$($o.evidence)"
                    if ([string]::IsNullOrWhiteSpace($ev)) { return @{ ok = $false; code = 'SPEC_EVIDENCE'; spec = $null; specSha = $specSha } }
                    if ($ev.IndexOf([char]58) -ge 0 -and $ev[1] -eq [char]92) { return @{ ok = $false; code = 'SPEC_EVIDENCE_ABS'; spec = $null; specSha = $specSha } }
                    if ($ev -match '^[A-Za-z]:[\\/]') { return @{ ok = $false; code = 'SPEC_EVIDENCE_ABS'; spec = $null; specSha = $specSha } }
                    if (Test-PathHasDotDotSegment -Path $ev) { return @{ ok = $false; code = 'SPEC_EVIDENCE_DOTDOT'; spec = $null; specSha = $specSha } }
                    if ($ev.IndexOf([char]124) -ge 0) { return @{ ok = $false; code = 'SPEC_EVIDENCE'; spec = $null; specSha = $specSha } }
                }
                if ($null -ne $o.supersedes -and "$($o.supersedes)" -notmatch $script:MemIdPattern) { return @{ ok = $false; code = 'SPEC_SUPERSEDES'; spec = $null; specSha = $specSha } }
                if (Test-ContainsForbiddenToken -Text $subj) { return @{ ok = $false; code = 'SPEC_FORBIDDEN'; spec = $null; specSha = $specSha } }
                if (Test-ContainsForbiddenToken -Text $summ) { return @{ ok = $false; code = 'SPEC_FORBIDDEN'; spec = $null; specSha = $specSha } }
                foreach ($t in $tags) { if (Test-ContainsForbiddenToken -Text "$t") { return @{ ok = $false; code = 'SPEC_FORBIDDEN'; spec = $null; specSha = $specSha } } }
            } else {
                if ($null -eq $o.record_id -or "$($o.record_id)" -notmatch $script:MemIdPattern) { return @{ ok = $false; code = 'SPEC_RECORD_ID'; spec = $null; specSha = $specSha } }
            }
        } else {
            if ($ModeName -eq 'Forget' -and $ot -ne 'forget') { return @{ ok = $false; code = 'SPEC_OP_TYPE'; spec = $null; specSha = $specSha } }
            if ($ModeName -eq 'Restore' -and $ot -ne 'restore') { return @{ ok = $false; code = 'SPEC_OP_TYPE'; spec = $null; specSha = $specSha } }
            if ($null -eq $o.record_id -or "$($o.record_id)" -notmatch $script:MemIdPattern) { return @{ ok = $false; code = 'SPEC_RECORD_ID'; spec = $null; specSha = $specSha } }
        }
    }
    if ($ModeName -eq 'Commit' -and $initCount -gt 1) { return @{ ok = $false; code = 'SPEC_INIT_MULTI'; spec = $null; specSha = $specSha } }
    return @{ ok = $true; code = ''; spec = $spec; specSha = $specSha }
}

# Transition compute (step 9-10)
# ---------------------------------------------------------------------------
function Compute-Transition {
    param($Base, $SpecParsed, [string]$ModeName, [string]$SpecSha, [string]$CommitDate)
    # returns @{ ok; code; proposed; affected }
    # proposed: @{ gen; core (list); index (list); archiveLines (list); notes (hashtable); action; affected (list) }
    $p = @{
        gen = $Base.genA + 1
        core = New-Object System.Collections.Generic.List[object]
        index = New-Object System.Collections.Generic.List[object]
        archiveLines = New-Object System.Collections.Generic.List[string]
        notes = @{}
        action = 'commit'
        affected = New-Object System.Collections.Generic.List[string]
    }
    # seed from base
    if ($Base.genA -gt 0) {
        $baseGen = Load-Generation -Dir (Get-GenDir -N $Base.genA) -ExpectedGen $Base.genA
        if (-not $baseGen.ok) { return @{ ok = $false; code = 'BASE_LOAD'; proposed = $null; affected = @() } }
        foreach ($r in $baseGen.core) { $p.core.Add($r) }
        foreach ($r in $baseGen.index) { $p.index.Add($r) }
        foreach ($ln in $baseGen.archiveLines) { $p.archiveLines.Add($ln) }
        foreach ($k in $baseGen.notes.Keys) { $p.notes[$k] = $baseGen.notes[$k] }
    }

    $ops = @($SpecParsed.spec.operations)
    if ($ModeName -eq 'Commit' -and $ops.Count -eq 1 -and "$($ops[0].op)" -eq 'initialize') {
        if ($Base.genA -ne 0) { return @{ ok = $false; code = 'INIT_NOT_EMPTY'; proposed = $null; affected = @() } }
        $p.action = 'initialize'
        return @{ ok = $true; code = ''; proposed = $p; affected = @() }
    }

    $indexById = @{}
    foreach ($r in $p.index) { $indexById[$r.id] = $r }

    foreach ($o in $ops) {
        $ot = "$($o.op)"
        if ($ModeName -eq 'Forget') {
            $rid = "$($o.record_id)"
            if (-not $indexById.ContainsKey($rid)) { return @{ ok = $false; code = 'FORGET_TARGET'; proposed = $null; affected = @() } }
            $rec = $indexById[$rid]
            $origLine = Get-RecordLine -Rec $rec
            $p.archiveLines.Add($CommitDate + '|forgotten|' + $origLine)
            $null = $p.index.Remove($rec)
            $cr = $null
            foreach ($r2 in $p.core) { if ($r2.id -eq $rid) { $cr = $r2; break } }
            if ($null -ne $cr) { $null = $p.core.Remove($cr) }
            # NOTE retention (01 D2.4/D2.5/D3.7): a forgotten record's note persists in
            # the generation (hash-listed in STATE) so a later Restore can carry it into
            # the proposed generation (frozen 04 AM-T-012 / AM-T-005.c require PASS).
            $null = $indexById.Remove($rid)
            $p.affected.Add($rid)
            continue
        }
        if ($ModeName -eq 'Restore') {
            $rid = "$($o.record_id)"
            $targetIdx = -1
            # archiveLines carries no header (Load-Generation strips it); index 0 is a valid record line
            for ($i = $p.archiveLines.Count - 1; $i -ge 0; $i--) {
                $ln = $p.archiveLines[$i]
                $parts = $ln -split '\|', 3
                if ($parts.Count -eq 3) {
                    $mid2 = ($parts[2] -split '\|')[0]
                    if ($mid2 -eq $rid) { $targetIdx = $i; break }
                }
            }
            if ($targetIdx -lt 0) { return @{ ok = $false; code = 'RESTORE_TARGET'; proposed = $null; affected = @() } }
            $ln = $p.archiveLines[$targetIdx]
            $parts = $ln -split '\|', 3
            $origLine = $parts[2]
            $pr = Parse-RecordLine -Line $origLine
            if (-not $pr.ok) { return @{ ok = $false; code = 'RESTORE_LINE'; proposed = $null; affected = @() } }
            $rec = $pr.rec
            $rec.lifecycle = 'active'
            if ($indexById.ContainsKey($rid)) { return @{ ok = $false; code = 'RESTORE_ACTIVE'; proposed = $null; affected = @() } }
            # transition-scoped checks
            if ($rec.provenance -ne 'USER_STATED') {
                if ($rec.source_pointer -eq '-') { return @{ ok = $false; code = 'RESTORE_SOURCE_MISSING'; proposed = $null; affected = @() } }
                $evFull = [System.IO.Path]::GetFullPath((Join-Path $script:WsFull $rec.source_pointer))
                if (-not (Test-PathInside -Path $evFull -Root $script:WsFull)) { return @{ ok = $false; code = 'RESTORE_SOURCE_MISSING'; proposed = $null; affected = @() } }
                if (Test-PathComponentReparse -Path $evFull) { return @{ ok = $false; code = 'RESTORE_SOURCE_MISSING'; proposed = $null; affected = @() } }
                if (-not (Test-Path -LiteralPath $evFull)) { return @{ ok = $false; code = 'RESTORE_SOURCE_MISSING'; proposed = $null; affected = @() } }
            }
            if ($rec.note_pointer -ne '-') {
                if (-not $p.notes.ContainsKey($rid)) {
                    # note must exist in base generation for restore (same-transition rule: machine writes notes only in add)
                    $baseHasNote = $false
                    if ($Base.genA -gt 0) {
                        $bp = Join-Path (Get-GenDir -N $Base.genA) ('notes\mem_' + $rid.Substring(4) + '.md')
                        if (Test-Path -LiteralPath $bp) { $baseHasNote = $true }
                    }
                    if (-not $baseHasNote) { return @{ ok = $false; code = 'RESTORE_NOTE_MISSING'; proposed = $null; affected = @() } }
                    $p.notes[$rid] = $null  # placeholder: filled from base below
                }
            }
            $p.index.Add($rec)
            $null = $p.archiveLines.RemoveAt($targetIdx)
            $indexById[$rid] = $rec
            $p.affected.Add($rid)
            continue
        }
        # Commit ops
        if ($ot -eq 'add') {
            $provS = "$($o.provenance)"
            # evidence path safety (all adds, transition-scoped existence for non-USER_STATED)
            $evPtr = '-'
            if ($null -ne $o.evidence) {
                $ev = "$($o.evidence)"
                $evFull = [System.IO.Path]::GetFullPath((Join-Path $script:WsFull $ev))
                if (-not (Test-PathInside -Path $evFull -Root $script:WsFull)) { return @{ ok = $false; code = 'EVIDENCE_PATH'; proposed = $null; affected = @() } }
                if (Test-PathComponentReparse -Path $evFull) { return @{ ok = $false; code = 'EVIDENCE_REPARSE'; proposed = $null; affected = @() } }
                if ($provS -ne 'USER_STATED') {
                    if (-not (Test-Path -LiteralPath $evFull)) { return @{ ok = $false; code = 'EVIDENCE_MISSING'; proposed = $null; affected = @() } }
                }
                $evPtr = $ev
            }
            # supersedes target must exist and be active
            if ($null -ne $o.supersedes) {
                $stId = "$($o.supersedes)"
                if (-not $indexById.ContainsKey($stId)) { return @{ ok = $false; code = 'SUPERSEDES_TARGET'; proposed = $null; affected = @() } }
            }
            continue
        }
        if ($ot -eq 'pin' -or $ot -eq 'unpin') {
            $rid2 = "$($o.record_id)"
            if (-not $indexById.ContainsKey($rid2)) { return @{ ok = $false; code = 'PIN_TARGET'; proposed = $null; affected = @() } }
            continue
        }
    }

    # ---- apply adds (id assignment), pins, supersession in op order ----
    $nextIdNum = 0
    $allIds = New-Object System.Collections.Generic.List[string]
    foreach ($r in $p.index) { $allIds.Add($r.id) }
    foreach ($ln in $p.archiveLines) {
        $pp2 = $ln -split '\|', 3
        if ($pp2.Count -eq 3) { $allIds.Add(($pp2[2] -split '\|')[0]) }
    }
    foreach ($id in $allIds) {
        $n = [int]($id.Substring(4))
        if ($n -gt $nextIdNum) { $nextIdNum = $n }
    }

    $pendingAdds = New-Object System.Collections.Generic.List[object]
    foreach ($o in $ops) {
        $ot = "$($o.op)"
        if ($ModeName -ne 'Commit') { continue }
        if ($ot -eq 'add') { $pendingAdds.Add($o) }
    }
    foreach ($o in $pendingAdds) {
        $nextIdNum++
        $newId = 'mem_' + $nextIdNum.ToString('0000')
        $tags = @()
        if ($null -ne $o.tags) { $tags = @($o.tags) }
        $provS = "$($o.provenance)"
        $evPtr = '-'
        if ($null -ne $o.evidence) { $evPtr = "$($o.evidence)" }
        $notePtr = '-'
        if ($null -ne $o.note) { $notePtr = 'notes/' + $newId + '.md' }
        $supId = '-'
        if ($null -ne $o.supersedes) { $supId = "$($o.supersedes)" }
        $rec = @{
            id = $newId; recorded_at = $CommitDate; subject = "$($o.subject)"; tag_list = $tags
            provenance = $provS; source_pointer = $evPtr; note_pointer = $notePtr
            lifecycle = 'active'; supersedes_id = $supId; summary = "$($o.summary)"
        }
        $p.index.Add($rec)
        if ($null -ne $o.note) { $p.notes[$newId] = "$($o.note)" }
        if (Test-PinTrue -Pin $o.pin) {
            # add pin=true: core copy (lifecycle=pinned) + index copy (lifecycle=active),
            # field-identical except lifecycle (frozen 04 AM-T-005 generation-3 rule).
            $coreCopy = @{}
            foreach ($kk in $rec.Keys) { $coreCopy[$kk] = $rec[$kk] }
            $coreCopy['lifecycle'] = 'pinned'
            $p.core.Add($coreCopy)
        }
        $indexById[$newId] = $rec
        $p.affected.Add($newId)
        if ($null -ne $o.supersedes) {
            $stId = "$($o.supersedes)"
            $stRec = $indexById[$stId]
            $origLine = Get-RecordLine -Rec $stRec
            $p.archiveLines.Add($CommitDate + '|superseded|' + $origLine)
            $null = $p.index.Remove($stRec)
            $csr = $null
            foreach ($r3 in $p.core) { if ($r3.id -eq $stId) { $csr = $r3; break } }
            if ($null -ne $csr) { $null = $p.core.Remove($csr) }
            # NOTE retention (01 D2.4/D3.7): a superseded record's note persists so the
            # SUPERSEDED--restore-->ACTIVE transition (01 D4.1) stays reachable for
            # note-bearing records.
            $null = $indexById.Remove($stId)
            $p.affected.Add($stId)
        }
    }
    # ---- apply pins / unpins ----
    foreach ($o in $ops) {
        if ($ModeName -ne 'Commit') { continue }
        $ot = "$($o.op)"
        if ($ot -eq 'pin') {
            $rid3 = "$($o.record_id)"
            $rec2 = $null
            foreach ($r4 in $p.index) { if ($r4.id -eq $rid3) { $rec2 = $r4; break } }
            if ($null -eq $rec2) { return @{ ok = $false; code = 'PIN_TARGET'; proposed = $null; affected = @() } }
            $alreadyPinned = $false
            foreach ($r5 in $p.core) { if ($r5.id -eq $rid3) { $alreadyPinned = $true; break } }
            if (-not $alreadyPinned) {
                $coreCopy = @{}
                foreach ($kk in $rec2.Keys) { $coreCopy[$kk] = $rec2[$kk] }
                $coreCopy['lifecycle'] = 'pinned'
                $p.core.Add($coreCopy)
                $p.affected.Add($rid3)
            }
        }
        if ($ot -eq 'unpin') {
            $rid4 = "$($o.record_id)"
            $cr2 = $null
            foreach ($r6 in $p.core) { if ($r6.id -eq $rid4) { $cr2 = $r6; break } }
            if ($null -eq $cr2) { return @{ ok = $false; code = 'UNPIN_TARGET'; proposed = $null; affected = @() } }
            $null = $p.core.Remove($cr2)
            $p.affected.Add($rid4)
        }
    }

    # ---- ordering (recorded_at asc, id asc) ----
    # In-place sort that preserves the List[object] instance. Reassignment via a
    # function return is unrolled by PowerShell (empty -> $null, one -> scalar),
    # which breaks .Count/.Remove under strict mode.
    $sortedCore = @($p.core | Sort-Object -Property @{ Expression = { $_['recorded_at'] + '|' + $_['id'] } })
    $p.core.Clear()
    foreach ($r in $sortedCore) { $p.core.Add($r) }
    $sortedIndex = @($p.index | Sort-Object -Property @{ Expression = { $_['recorded_at'] + '|' + $_['id'] } })
    $p.index.Clear()
    foreach ($r in $sortedIndex) { $p.index.Add($r) }

    # ---- FIFO eviction on index (oldest eligible non-pinned) ----
    $coreIdSet = @{}
    foreach ($r in $p.core) { $coreIdSet[$r.id] = $true }
    $evicted = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $idxBytes = Measure-ContentBytes -Records $p.index -Header $script:IndexHeader
        $overRec = $p.index.Count -gt $script:IndexRecMax
        $overBytes = $idxBytes -gt ($script:IndexHeader.Length + 1 + $script:IndexByteMax)
        if (-not $overRec -and -not $overBytes) { break }
        $victim = $null
        foreach ($r in $p.index) {
            if (-not $coreIdSet.ContainsKey($r.id)) { $victim = $r; break }
        }
        if ($null -eq $victim) { return @{ ok = $false; code = 'FIFO_NO_VICTIM'; proposed = $null; affected = @() } }
        $origLine = Get-RecordLine -Rec $victim
        $p.archiveLines.Add($CommitDate + '|evicted|' + $origLine)
        $null = $p.index.Remove($victim)
        # NOTE retention (01 D2.4/D3.7): an evicted record's note persists so the
        # EVICTED--restore-->ACTIVE transition (01 D4.1) stays reachable.
        $evicted.Add($victim.id)
    }
    # ---- bounds validation (final) ----
    $coreBytes = Measure-ContentBytes -Records $p.core -Header $script:CoreHeader
    if ($p.core.Count -gt $script:CoreRecMax) { return @{ ok = $false; code = 'CORE_REC_BOUND'; proposed = $null; affected = @() } }
    if ($coreBytes -gt ($script:CoreHeader.Length + 1 + $script:CoreByteMax)) { return @{ ok = $false; code = 'CORE_BYTE_BOUND'; proposed = $null; affected = @() } }
    $idxBytes2 = Measure-ContentBytes -Records $p.index -Header $script:IndexHeader
    if ($p.index.Count -gt $script:IndexRecMax) { return @{ ok = $false; code = 'INDEX_REC_BOUND'; proposed = $null; affected = @() } }
    if ($idxBytes2 -gt ($script:IndexHeader.Length + 1 + $script:IndexByteMax)) { return @{ ok = $false; code = 'INDEX_BYTE_BOUND'; proposed = $null; affected = @() } }
    foreach ($k in $p.notes.Keys) {
        if ($null -ne $p.notes[$k]) {
            $nb2 = $script:Utf8NoBom.GetBytes($p.notes[$k])
            if ($nb2.Length -gt $script:NoteByteMax) { return @{ ok = $false; code = 'NOTE_BOUND'; proposed = $null; affected = @() } }
        }
    }
    # CORE subseteq INDEX final
    $indexIdSet = @{}
    foreach ($r in $p.index) { $indexIdSet[$r.id] = $true }
    foreach ($r in $p.core) {
        if (-not $indexIdSet.ContainsKey($r.id)) { return @{ ok = $false; code = 'CORE_INDEX'; proposed = $null; affected = @() } }
    }
    return @{ ok = $true; code = ''; proposed = $p; affected = @($p.affected) }
}

function Measure-ContentBytes {
    param($Records, [string]$Header)
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append($Header); $null = $sb.Append("`n")
    foreach ($r in $Records) {
        $null = $sb.Append((Get-RecordLine -Rec $r)); $null = $sb.Append("`n")
    }
    return $script:Utf8NoBom.GetBytes($sb.ToString()).Length
}

function Serialize-GenFiles {
    param($Proposed)
    # returns @{ core; index; archive; notes (hashtable id->text) }
    $coreSb = New-Object System.Text.StringBuilder
    $null = $coreSb.Append($script:CoreHeader); $null = $coreSb.Append("`n")
    foreach ($r in $Proposed.core) { $null = $coreSb.Append((Get-RecordLine -Rec $r)); $null = $coreSb.Append("`n") }
    $indexSb = New-Object System.Text.StringBuilder
    $null = $indexSb.Append($script:IndexHeader); $null = $indexSb.Append("`n")
    foreach ($r in $Proposed.index) { $null = $indexSb.Append((Get-RecordLine -Rec $r)); $null = $indexSb.Append("`n") }
    $archSb = New-Object System.Text.StringBuilder
    $null = $archSb.Append($script:ArchiveHeader); $null = $archSb.Append("`n")
    foreach ($ln in $Proposed.archiveLines) { $null = $archSb.Append($ln); $null = $archSb.Append("`n") }
    return @{ core = $coreSb.ToString(); index = $indexSb.ToString(); archive = $archSb.ToString(); notes = $Proposed.notes }
}

# ---------------------------------------------------------------------------
# Staging + staged verification
# ---------------------------------------------------------------------------
function Stage-Generation {
    param($Proposed, [string]$OperationId, [string]$SpecSha)
    $dir = Get-GenDir -N $Proposed.gen
    if (Test-Path -LiteralPath $dir) {
        # never-ACTIVE remnant at target number cannot happen (we stage ACTIVE+1 which is > any existing validated gen);
        # if a remnant exists there, it is non-canonical: remove it.
        Remove-DirTree -Path $dir
    }
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $files = Serialize-GenFiles -Proposed $Proposed
    $coreBytes = $script:Utf8NoBom.GetBytes($files.core)
    $indexBytes = $script:Utf8NoBom.GetBytes($files.index)
    $archiveBytes = $script:Utf8NoBom.GetBytes($files.archive)
    Write-FileExact -Path (Join-Path $dir 'core.md') -Text $files.core
    Write-FileExact -Path (Join-Path $dir 'index.md') -Text $files.index
    Write-FileExact -Path (Join-Path $dir 'archive.md') -Text $files.archive
    $notesDir = Join-Path $dir 'notes'
    [System.IO.Directory]::CreateDirectory($notesDir) | Out-Null
    $affectedStr = '-'
    if ($Proposed.affected.Count -gt 0) { $affectedStr = ($Proposed.affected -join ',') }
    $stateText = Build-STATEText -Generation $Proposed.gen -OperationId $OperationId -SpecSha $SpecSha `
        -AffectedIds $affectedStr -Action $Proposed.action -CoreBytes $coreBytes -IndexBytes $indexBytes -ArchiveBytes $archiveBytes -Notes $files.notes
    Write-FileExact -Path (Join-Path $dir 'STATE') -Text $stateText
    foreach ($k in $files.notes.Keys) {
        $nt = $files.notes[$k]
        if ($null -eq $nt) { continue }  # restore-carried note: copy from base
        Write-FileExact -Path (Join-Path $notesDir ($k + '.md')) -Text $nt
    }
    # copy restore-carried notes from base generation
    if ($Proposed.gen -gt 1) {
        $baseNotesDir = Join-Path (Get-GenDir -N ($Proposed.gen - 1)) 'notes'
        foreach ($k in $files.notes.Keys) {
            if ($null -eq $files.notes[$k]) {
                $src = Join-Path $baseNotesDir ($k + '.md')
                if (Test-Path -LiteralPath $src) {
                    [System.IO.File]::Copy($src, (Join-Path $notesDir ($k + '.md')), $false)
                }
            }
        }
    }
}

function Verify-GenerationOnDisk {
    param([string]$Dir, [int]$ExpectedGen)
    return (Load-Generation -Dir $Dir -ExpectedGen $ExpectedGen)
}

# ---------------------------------------------------------------------------
# Read modes
# ---------------------------------------------------------------------------
function Invoke-ReadMode {
    param([string]$ModeName)
    if (-not (Test-Path -LiteralPath $script:MemFull)) {
        $diags = @()
        $extra = $null
        if ($ModeName -eq 'Status') {
            $extra = [ordered]@{}
            $extra['generation_count'] = 0
            $extra['completed_bytes_total'] = 0
            $extra['active_generation_bytes'] = 0
            $extra['largest_generation_bytes'] = 0
            $extra['noncanonical_bytes'] = 0
            $extra['receipt_count'] = 0
            $extra['receipt_bytes_total'] = 0
        }
        Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics $diags -Extra $extra
    }
    $base = Resolve-BaseState
    if (-not $base.ok) {
        # Corrupted/unresolvable ACTIVE (or pointer set): unprovable switch
        # outcome (frozen 006.j). No auto-repair, no adoption.
        $extra = $null
        if ($ModeName -eq 'Status') { $extra = Get-StatusMetrics }
        Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-BaseStateId -Base $base) -Diagnostics @('active_switch_outcome_unknown') -Extra $extra
    }
    $diags = New-Object System.Collections.Generic.List[string]
    $pendingId = $null
    if ($null -ne $base.active) {
        $st = Load-Generation -Dir (Get-GenDir -N $base.active.generation) -ExpectedGen $base.active.generation
        if (-not $st.ok) {
            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-BaseStateId -Base $base) -Diagnostics @() -Extra $(if ($ModeName -eq 'Status') { Get-StatusMetrics } else { $null })
        }
        $stateId = Get-StateIdFromActive -ActiveRec $base.active -State $st.state -CurrentRec $base.current
        if ($null -ne $base.current -and $base.current.generation -gt $base.active.generation) {
            $pendingId = $base.current.operation_id
        }
        if ($pendingId) {
            # Pending operation: read modes report pending without PASS (frozen 006.b/006.g).
            $pExtra = $null
            if ($ModeName -eq 'Status') { $pExtra = Get-StatusMetrics }
            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $stateId -Diagnostics @('pending_operation:' + $pendingId) -Extra $pExtra
        }
        switch ($ModeName) {
            'Validate' {
                Out-Result -Status 'PASS' -Operation 'validate' -Records @() -StateId $stateId -Diagnostics @($diags)
            }
            'Status' {
                $extra = Get-StatusMetrics
                Out-Result -Status 'PASS' -Operation 'status' -Records @() -StateId $stateId -Diagnostics @($diags) -Extra $extra
            }
            'Recall' {
                Invoke-Recall -Base $base -GenLoad $st -StateId $stateId -PendingId $pendingId -Diags $diags
            }
        }
    } else {
        # logical generation 0
        $stateId = Get-EmptyStateId
        if ($null -ne $base.current) {
            $stateId['current']['generation'] = $base.current.generation
            $stateId['current']['operation_id'] = $base.current.operation_id
            $pendingId = $base.current.operation_id
        }
        if ($pendingId) {
            # First-write pending (logical gen 0): read modes report pending without PASS (frozen 006.g).
            $pExtra = $null
            if ($ModeName -eq 'Status') { $pExtra = Get-StatusMetrics }
            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $stateId -Diagnostics @('pending_operation:' + $pendingId) -Extra $pExtra
        }
        switch ($ModeName) {
            'Validate' {
                Out-Result -Status 'PASS' -Operation 'validate' -Records @() -StateId $stateId -Diagnostics @($diags)
            }
            'Status' {
                $extra = Get-StatusMetrics
                Out-Result -Status 'PASS' -Operation 'status' -Records @() -StateId $stateId -Diagnostics @($diags) -Extra $extra
            }
            'Recall' {
                Out-Result -Status 'MISS' -Operation 'recall' -Records @() -StateId $stateId -Diagnostics @($diags) -Extra @{ candidates = @() }
            }
        }
    }
}

function Get-StatusMetrics {
    $m = [ordered]@{}
    $genA = 0
    if (Test-Path -LiteralPath (Join-Path $script:MemFull 'ACTIVE')) {
        $ap = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
        if ($ap.ok -and $null -ne $ap.rec) { $genA = $ap.rec.generation }
    }
    $genDirs = @()
    if (Test-Path -LiteralPath $script:GenRoot) {
        $genDirs = @(Get-ChildItem -LiteralPath $script:GenRoot -Directory -Force)
    }
    $completedCount = 0
    $completedBytes = 0
    $activeBytes = 0
    $largestBytes = 0
    $nonCanonicalBytes = 0
    foreach ($d in $genDirs) {
        if ($d.Name -notmatch '^[0-9]{6}$') { continue }
        $n = [int]$d.Name
        $bytes = Get-DirBytes -Path $d.FullName
        if ($n -le $genA) {
            $completedCount++
            $completedBytes += $bytes
            if ($n -eq $genA) { $activeBytes = $bytes }
            if ($bytes -gt $largestBytes) { $largestBytes = $bytes }
        } else {
            $nonCanonicalBytes += $bytes
        }
    }
    if (Test-Path -LiteralPath (Join-Path $script:MemFull 'CURRENT')) {
        $nonCanonicalBytes += (Get-Item -LiteralPath (Join-Path $script:MemFull 'CURRENT') -Force).Length
    }
    $rc = 0; $rb = 0
    if (Test-Path -LiteralPath $script:ReceiptsDir) {
        foreach ($rf in (Get-ChildItem -LiteralPath $script:ReceiptsDir -File -Force)) {
            $rc++
            $rb += $rf.Length
        }
    }
    $m['generation_count'] = $completedCount
    $m['completed_bytes_total'] = $completedBytes
    $m['active_generation_bytes'] = $activeBytes
    $m['largest_generation_bytes'] = $largestBytes
    $m['noncanonical_bytes'] = $nonCanonicalBytes
    $m['receipt_count'] = $rc
    $m['receipt_bytes_total'] = $rb
    return $m
}

function Invoke-Recall {
    param($Base, $GenLoad, $StateId, $PendingId, $Diags)
    $kws = @($Query -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($kws.Count -lt 1 -or $kws.Count -gt 4) {
        Out-Result -Status 'INVALID' -Operation 'recall' -Records @() -StateId $StateId -Diagnostics @() -Extra @{ candidates = @() }
    }
    $maxN = $Max
    if ($maxN -lt 1) { $maxN = 5 }
    if ($maxN -gt 10) { $maxN = 10 }
    $kwsL = @($kws | ForEach-Object { $_.ToLower() })

    # corpus: core + index, dedup by memory_id
    $byId = @{}
    foreach ($r in $GenLoad.index) { $byId[$r.id] = $r }
    $corpus = New-Object System.Collections.Generic.List[object]
    foreach ($r in $GenLoad.core) {
        if (-not $byId.ContainsKey($r.id)) { $byId[$r.id] = $r; $corpus.Add($r) }
    }
    foreach ($r in $GenLoad.index) {
        if ($corpus.Count -eq 0) { $corpus.Add($r); continue }
        $dup = $false
        foreach ($c in $corpus) { if ($c.id -eq $r.id) { $dup = $true; break } }
        if (-not $dup) { $corpus.Add($r) }
    }

    $cands = New-Object System.Collections.Generic.List[object]
    $dangling = $false
    foreach ($r in $corpus) {
        $subjL = $r.subject.ToLower()
        $summL = $r.summary.ToLower()
        $tagsL = (($r.tag_list -join ';')).ToLower()
        $score = 0
        $matchedFields = New-Object System.Collections.Generic.List[string]
        $matchedTerms = New-Object System.Collections.Generic.List[string]
        foreach ($i in 0..($kwsL.Count - 1)) {
            $kw = $kwsL[$i]
            $best = 0
            $hitField = $null
            if ($subjL.Contains($kw)) { $best = 3; $hitField = 'subject' }
            if ($tagsL.Contains($kw) -and $best -lt 3) { $best = 3; $hitField = 'tags' }
            if ($summL.Contains($kw) -and $best -lt 1) { $best = 1; $hitField = 'summary' }
            if ($best -gt 0) {
                $score += $best
                if (-not $matchedTerms.Contains($kws[$i])) { $matchedTerms.Add($kws[$i]) }
                # collect all fields matched by this keyword
                if ($subjL.Contains($kw) -and -not $matchedFields.Contains('subject')) { $matchedFields.Add('subject') }
                if ($tagsL.Contains($kw) -and -not $matchedFields.Contains('tags')) { $matchedFields.Add('tags') }
                if ($summL.Contains($kw) -and -not $matchedFields.Contains('summary')) { $matchedFields.Add('summary') }
            }
        }
        if ($score -gt 0) {
            $evStatus = 'ok'
            if ($r.source_pointer -ne '-') {
                $evFull = [System.IO.Path]::GetFullPath((Join-Path $script:WsFull $r.source_pointer))
                if (-not (Test-Path -LiteralPath $evFull)) { $evStatus = 'dangling'; $dangling = $true }
            }
            $c = [ordered]@{}
            $c['record_id'] = $r.id
            $c['recorded_at'] = $r.recorded_at
            $c['subject'] = $r.subject
            $c['tags'] = @($r.tag_list)
            $c['provenance'] = $r.provenance
            $c['source_pointer'] = $r.source_pointer
            $c['note_pointer'] = $r.note_pointer
            $c['evidence_status'] = $evStatus
            $c['matched_fields'] = @($matchedFields | Sort-Object)
            $c['matched_terms'] = @($matchedTerms)
            $c['score'] = $score
            $cands.Add($c)
        }
    }
    $sorted = @($cands | Sort-Object -Property @{ Expression = { [int]$_['score'] }; Descending = $true }, @{ Expression = { $_['recorded_at'] }; Descending = $true }, @{ Expression = { $_['record_id'] } })
    $top = @($sorted | Select-Object -First $maxN)
    if ($cands.Count -eq 0) {
        if ($dangling) { $Diags.Add('dangling_evidence') }
        if ($PendingId) { $Diags.Add('pending_operation:' + $PendingId) }
        Out-Result -Status 'MISS' -Operation 'recall' -Records @() -StateId $StateId -Diagnostics @($Diags) -Extra @{ candidates = @() }
    }
    if ($dangling) { $Diags.Add('dangling_evidence') }
    if ($PendingId) { $Diags.Add('pending_operation:' + $PendingId) }
    Out-Result -Status 'HIT' -Operation 'recall' -Records @() -StateId $StateId -Diagnostics @($Diags) -Extra @{ candidates = @($top) }
}

# ---------------------------------------------------------------------------
# Write engine (D3.5)
# ---------------------------------------------------------------------------
function Invoke-WriteMode {
    param([string]$ModeName)
    # --- spec (pre-lock) ---
    $specFull = [System.IO.Path]::GetFullPath($Spec)
    if (-not (Test-PathInside -Path $specFull -Root $script:SpFull)) {
        Out-Result -Status 'BLOCKED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics @()
    }
    $specParsed = Parse-Spec -SpecPath $specFull -ModeName $ModeName
    if (-not $specParsed.ok) {
        # 2026-10-12 amendment (04 AM-T-044): the operation-count violation is
        # surfaced as the SPEC_OP_COUNT diagnostic; other spec parse failures
        # keep empty diagnostics.
        $dd = @()
        if ($specParsed.code -eq 'SPEC_OP_COUNT') { $dd = @('SPEC_OP_COUNT') }
        Out-Result -Status 'INVALID' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics $dd
    }
    $specObj = $specParsed.spec
    $specSha = $specParsed.specSha
    $opId = "$($specObj.operation_id)"
    $expGen = [int]$specObj.expected.generation
    $expCore = "$($specObj.expected.core)"
    $expIndex = "$($specObj.expected.index)"
    $expArchive = "$($specObj.expected.archive)"

    # --- scaffolding + lock ---
    # Ensure the canonical layout (memory root + .gen + receipts) always exists.
    # This is idempotent: the memory root may pre-exist (created out-of-band or
    # partially initialized); in that case .gen and receipts/ are still required
    # before any receipt write, so we must not gate them on the root being absent.
    [System.IO.Directory]::CreateDirectory($script:MemFull) | Out-Null
    [System.IO.Directory]::CreateDirectory($script:GenRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($script:ReceiptsDir) | Out-Null
    $lock = New-WriterLock -TimeoutSeconds $LockTimeoutSeconds
    if ($null -eq $lock) {
        Out-Result -Status 'STALE' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics @('writer_active')
    }
    try {
        # --- base resolution ---
        $base = Resolve-BaseState
        $baseStateId = Get-BaseStateId -Base $base
        if (-not $base.ok) {
            Out-Result -Status 'BLOCKED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @()
        }

        # --- step 4: durable PASS replay ---
        $active = $base.active
        $histPath = Join-Path $script:ReceiptsDir ($opId + '.pass')
        $pendingGen = $null
        if ($null -ne $base.current -and $base.current.generation -gt $base.genA) {
            $pendingGen = $base.current.generation
        }
        if ($null -ne $active -and $active.operation_id -eq $opId) {
            if ($active.spec_sha256 -eq $specSha) {
                $recs = @()
                if ($active.affected_ids -ne '-') { $recs = @($active.affected_ids -split ',') }
                $st = Load-Generation -Dir (Get-GenDir -N $active.generation) -ExpectedGen $active.generation
                $sid = $baseStateId
                if ($st.ok) { $sid = Get-StateIdFromActive -ActiveRec $active -State $st.state -CurrentRec $base.current }
                Out-Result -Status 'PASS' -Operation $ModeName.ToLowerInvariant() -Records $recs -StateId $sid -Diagnostics @('idempotent_pass_recovered')
            } else {
                Out-Result -Status 'INVALID' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('operation_id_reuse')
            }
        }
        $hist = Parse-HistoricalReceipt -Path $histPath -ExpectedOpId $opId
        if (-not $hist.ok) {
            # Malformed pre-existing receipt (too large / BOM / invalid UTF-8 /
            # format / UUID mismatch): never treated as PASS; never modified (frozen 006.o/006.p).
            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
        }
        if ($hist.ok -and $hist.code -eq 'PRESENT') {
            if ($pendingGen -ne $null) {
                # pending resume scenario: expected receipt is fully determined by the pending STATE
                $pdir = Get-GenDir -N $pendingGen
                $pstate = Load-Generation -Dir $pdir -ExpectedGen $pendingGen
                if ($pstate.ok -and $pstate.state.operation_id -eq $opId -and $pstate.state.spec_sha256 -eq $specSha) {
                    $expectedReceipt = Get-ReceiptText -Generation $pendingGen -OperationId $opId -SpecSha $specSha `
                        -StateSha (Get-TextSha256Hex -Text $pstate.state.text) -Action $pstate.state.action -AffectedIds $pstate.state.affected_ids
                    if ($hist.text -cne $expectedReceipt) {
                        Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                    }
                    # byte-identical: one logical receipt; resume proceeds in step 5
                } else {
                    Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                }
            } else {
                if ($hist.rec.spec_sha256 -eq $specSha) {
                    $recs2 = @()
                    if ($hist.rec.affected_ids -ne '-') { $recs2 = @($hist.rec.affected_ids -split ',') }
                    Out-Result -Status 'PASS' -Operation $ModeName.ToLowerInvariant() -Records $recs2 -StateId $baseStateId -Diagnostics @('idempotent_pass_recovered')
                } else {
                    Out-Result -Status 'INVALID' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('operation_id_reuse')
                }
            }
        }

        # --- step 5: pending handling ---
        if ($pendingGen -ne $null) {
            $pdir = Get-GenDir -N $pendingGen
            $pstate = Load-Generation -Dir $pdir -ExpectedGen $pendingGen
            $pOpId = $null
            if ($pstate.ok) { $pOpId = $pstate.state.operation_id }
            if (-not $pstate.ok -or $pOpId -ne $base.current.operation_id -or $pstate.state.spec_sha256 -ne $base.current.spec_sha256) {
                # pending invalid: restore CURRENT to ACTIVE identity (remove for A=0), remove pending dir.
                # CURRENT is the 4-line WRITER record (01 D1.1): rebuild it from the ACTIVE
                # identity fields; never copy the 7-line ACTIVE receipt bytes.
                if ($null -ne $active) {
                    $curRestore = Get-CurrentText -Generation $active.generation -OperationId $active.operation_id -SpecSha $active.spec_sha256 -StateSha $active.state_sha256
                    Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
                } else {
                    Remove-Item -LiteralPath (Join-Path $script:MemFull 'CURRENT') -Force -ErrorAction SilentlyContinue
                }
                Remove-DirTree -Path $pdir
                Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('pending_invalid')
            }
            if ($pOpId -eq $opId) {
                if ($pstate.state.spec_sha256 -ne $specSha) {
                    Out-Result -Status 'INVALID' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('operation_id_reuse')
                }
                # exact retry: resume
                # ensure prior ACTIVE receipt archived (byte-identical create-new or conflict)
                if ($null -ne $active) {
                    $prevReceiptPath = Join-Path $script:ReceiptsDir ($active.operation_id + '.pass')
                    $oldActiveBytes = [System.IO.File]::ReadAllBytes((Join-Path $script:MemFull 'ACTIVE'))
                    if (Test-Path -LiteralPath $prevReceiptPath) {
                        $existing = [System.IO.File]::ReadAllBytes($prevReceiptPath)
                        if (-not (Test-BytesEqual -A $existing -B $oldActiveBytes)) {
                            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                        }
                    } else {
                        try {
                            Write-FileBytesFlushed -Path $prevReceiptPath -Bytes $oldActiveBytes
                        } catch {
                            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                        }
                    }
                }
                # write ACTIVE receipt for the pending generation
                $stateSha = Get-TextSha256Hex -Text $pstate.state.text
                $receiptText = Get-ReceiptText -Generation $pendingGen -OperationId $opId -SpecSha $specSha -StateSha $stateSha -Action $pstate.state.action -AffectedIds $pstate.state.affected_ids
                Set-PointerAtomic -Target (Join-Path $script:MemFull 'ACTIVE') -Text $receiptText -Tag 'active'
                $rb = Read-FileStrict -Path (Join-Path $script:MemFull 'ACTIVE')
                if (-not $rb.ok -or $rb.text -cne $receiptText) {
                    Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('active_switch_io_failed')
                }
                $recs3 = @()
                if ($pstate.state.affected_ids -ne '-') { $recs3 = @($pstate.state.affected_ids -split ',') }
                $newActive = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
                $newCurrent = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
                $sid3 = Get-StateIdFromActive -ActiveRec $newActive.rec -State $pstate.state -CurrentRec $newCurrent.rec
                Out-Result -Status 'PASS' -Operation $ModeName.ToLowerInvariant() -Records $recs3 -StateId $sid3 -Diagnostics @('pending_resumed:' + $opId)
            } else {
                Out-Result -Status 'STALE' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('pending_operation:' + $pOpId)
            }
        }

        # --- step 6: remnant cleanup (gen > CURRENT) ---
        $cleanupDiags = New-Object System.Collections.Generic.List[string]
        $cutGen = $base.genA
        if ($null -ne $base.current) { $cutGen = $base.current.generation }
        if (Test-Path -LiteralPath $script:GenRoot) {
            foreach ($d in (Get-ChildItem -LiteralPath $script:GenRoot -Directory -Force)) {
                if ($d.Name -notmatch '^[0-9]{6}$') { continue }
                $n = [int]$d.Name
                if ($n -gt $cutGen) {
                    Remove-DirTree -Path $d.FullName
                    $cleanupDiags.Add('stale_generation_cleaned:' + $n)
                }
            }
        }

        # --- step 7: load + validate ACTIVE base ---
        $baseGen = $null
        if ($base.genA -gt 0) {
            $baseGen = Load-Generation -Dir (Get-GenDir -N $base.genA) -ExpectedGen $base.genA
            if (-not $baseGen.ok) {
                Out-Result -Status 'BLOCKED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @()
            }
        }

        # --- step 8: CAS ---
        $actualCore = 'ABSENT'; $actualIndex = 'ABSENT'; $actualArchive = 'ABSENT'
        if ($base.genA -gt 0) {
            $actualCore = $baseGen.state.core_sha256
            $actualIndex = $baseGen.state.index_sha256
            $actualArchive = $baseGen.state.archive_sha256
        }
        if ($expGen -ne $base.genA -or $expCore -cne $actualCore -or $expIndex -cne $actualIndex -or $expArchive -cne $actualArchive) {
            Out-Result -Status 'STALE' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('cas_mismatch')
        }

        # --- step 9-10: compute ---
        $computed = Compute-Transition -Base $base -SpecParsed $specParsed -ModeName $ModeName -SpecSha $specSha -CommitDate (Get-DateToday)
        if (-not $computed.ok) {
            $map = @{
                'RESTORE_SOURCE_MISSING' = @('restore_source_missing')
                'RESTORE_NOTE_MISSING' = @('restore_note_missing')
            }
            $dd = @()
            if ($map.ContainsKey($computed.code)) { $dd = $map[$computed.code] }
            Out-Result -Status 'INVALID' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics $dd
        }
        $proposed = $computed.proposed

        # --- step 11: stage ---
        try {
            Stage-Generation -Proposed $proposed -OperationId $opId -SpecSha $specSha
        } catch {
            if ($env:BAM_DEBUG_ERROR -eq '1') { try { [System.IO.File]::WriteAllText($env:BAM_DEBUG_ERROR_FILE, ('STAGE_CATCH: ' + $_.Exception.GetType().FullName + "`n" + $_.Exception.Message + "`n" + $_.ScriptStackTrace), (New-Object System.Text.UTF8Encoding($false))) } catch {} }
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @()
        }
        # Frozen 006.a: the pre-CURRENT-switch fault must return the structured
        # FAILED (staged_verify_failed) result; all other fault points terminate
        # without JSON (crash simulation).
        if ($script:FaultArmed -and $script:FaultPoint -eq 'FAULT_BEFORE_CURRENT_SWITCH') {
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('staged_verify_failed')
        }
        Invoke-Fault -Point 'FAULT_BEFORE_CURRENT_SWITCH'

        # --- step 12: staged disk verification ---
        $staged = Verify-GenerationOnDisk -Dir (Get-GenDir -N $proposed.gen) -ExpectedGen $proposed.gen
        if (-not $staged.ok) {
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('staged_verify_failed')
        }
        $stateSha = Get-TextSha256Hex -Text $staged.state.text

        # --- step 13: re-read ACTIVE/CURRENT under lock ---
        $active2 = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
        $current2 = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
        if ($null -eq $active) {
            $sameActive = ($active2.code -eq 'ABSENT')
        } else {
            $sameActive = ($active2.code -eq 'PRESENT' -and $active2.rec.operation_id -eq $active.operation_id -and $active2.rec.generation -eq $active.generation)
        }
        if ($null -eq $base.current) {
            $sameCurrent = ($current2.code -eq 'ABSENT')
        } else {
            $sameCurrent = ($current2.code -eq 'PRESENT' -and $current2.rec.generation -eq $base.current.generation -and $current2.rec.operation_id -eq $base.current.operation_id)
        }
        if (-not $sameActive -or -not $sameCurrent) {
            Out-Result -Status 'STALE' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @()
        }

        # --- step 14: CURRENT switch ---
        $oldActiveBytes = $null
        if ($null -ne $active) { $oldActiveBytes = [System.IO.File]::ReadAllBytes((Join-Path $script:MemFull 'ACTIVE')) }
        $currentText = Get-CurrentText -Generation $proposed.gen -OperationId $opId -SpecSha $specSha -StateSha $stateSha
        try {
            Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $currentText -Tag 'cur'
        } catch {
            if ($env:BAM_DEBUG_ERROR -eq '1') { try { [System.IO.File]::WriteAllText($env:BAM_DEBUG_ERROR_FILE, ('CURRENT_CATCH: ' + $_.Exception.GetType().FullName + "`n" + $_.Exception.Message + "`n" + $_.ScriptStackTrace), (New-Object System.Text.UTF8Encoding($false))) } catch {} }
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @()
        }
        Invoke-Fault -Point 'FAULT_AFTER_CURRENT_SWITCH'

        # --- step 15: revalidate through CURRENT ---
        $revalidated = Load-Generation -Dir (Get-GenDir -N $proposed.gen) -ExpectedGen $proposed.gen
        $curNow = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
        $rollbackCurrent = $false
        if (-not $revalidated.ok -or -not $curNow.ok -or $curNow.rec.generation -ne $proposed.gen -or $curNow.rec.operation_id -ne $opId) {
            $rollbackCurrent = $true
        }
        if (-not $rollbackCurrent -and $script:FaultArmed -and $script:FaultPoint -eq 'FAULT_POSTSWITCH_REVALIDATE') {
            $rollbackCurrent = $true
        }
        if ($rollbackCurrent) {
            if ($null -ne $active) {
                $curRestore = Get-CurrentText -Generation $active.generation -OperationId $active.operation_id -SpecSha $active.spec_sha256 -StateSha $active.state_sha256
                Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
            } else {
                Remove-Item -LiteralPath (Join-Path $script:MemFull 'CURRENT') -Force -ErrorAction SilentlyContinue
            }
            Remove-DirTree -Path (Get-GenDir -N $proposed.gen)
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('postswitch_rollback')
        }

        # --- step 16: archive prior ACTIVE receipt ---
        Invoke-Fault -Point 'FAULT_BEFORE_RECEIPT_ARCHIVE'
        if ($null -ne $active) {
            $prevReceiptPath = Join-Path $script:ReceiptsDir ($active.operation_id + '.pass')
            if (Test-Path -LiteralPath $prevReceiptPath) {
                $existing = [System.IO.File]::ReadAllBytes($prevReceiptPath)
                if (-not (Test-BytesEqual -A $existing -B $oldActiveBytes)) {
                    $curRestore = Get-CurrentText -Generation $active.generation -OperationId $active.operation_id -SpecSha $active.spec_sha256 -StateSha $active.state_sha256
                    Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
                    Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                }
            } else {
                try {
                    Write-FileBytesFlushed -Path $prevReceiptPath -Bytes $oldActiveBytes
                } catch {
                    $curRestore = Get-CurrentText -Generation $active.generation -OperationId $active.operation_id -SpecSha $active.spec_sha256 -StateSha $active.state_sha256
                    Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
                    Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('receipt_history_conflict')
                }
            }
        }
        Invoke-Fault -Point 'FAULT_AFTER_RECEIPT_ARCHIVE'

        # --- step 17: ACTIVE atomic durable PASS receipt ---
        $affectedStr = '-'
        if ($proposed.affected.Count -gt 0) { $affectedStr = ($proposed.affected -join ',') }
        $receiptText = Get-ReceiptText -Generation $proposed.gen -OperationId $opId -SpecSha $specSha -StateSha $stateSha -Action $proposed.action -AffectedIds $affectedStr
        $prevActiveBytesForTorn = $null
        if ($null -ne $active) { $prevActiveBytesForTorn = $oldActiveBytes }
        try {
            Set-PointerAtomic -Target (Join-Path $script:MemFull 'ACTIVE') -Text $receiptText -Tag 'active'
        } catch {
            Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('active_switch_io_failed')
        }
        if ($script:FaultArmed -and $script:FaultPoint -eq 'FAULT_ACTIVE_TORN') {
            # runner will (or has) force one of the two end states before retry;
            # this process terminates without JSON (crash simulation).
            [Console]::Out.Flush()
            exit 1
        }
        $rb2 = Read-FileStrict -Path (Join-Path $script:MemFull 'ACTIVE')
        $newActiveOk = $false
        if ($rb2.ok -and $rb2.text -eq $receiptText) { $newActiveOk = $true }
        if (-not $newActiveOk) {
            if ($null -ne $prevActiveBytesForTorn) {
                $prevText = [System.Text.Encoding]::UTF8.GetString($prevActiveBytesForTorn)
                if ($rb2.ok -and $rb2.text -eq $prevText) {
                    # still the prior valid receipt: ACTIVE switch did not take
                    $curRestore = Get-CurrentText -Generation $active.generation -OperationId $active.operation_id -SpecSha $active.spec_sha256 -StateSha $active.state_sha256
                    Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
                    Out-Result -Status 'FAILED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('active_switch_io_failed')
                }
            }
            Out-Result -Status 'UNVERIFIED' -Operation $ModeName.ToLowerInvariant() -Records @() -StateId $baseStateId -Diagnostics @('active_switch_outcome_unknown')
        }
        Invoke-Fault -Point 'FAULT_BEFORE_STDOUT'

        # --- step 18: emit PASS reconstructed from durable receipt ---
        $recsF = @()
        if ($affectedStr -ne '-') { $recsF = @($affectedStr -split ',') }
        $newActive = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
        $newCurrent = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
        $sidF = Get-StateIdFromActive -ActiveRec $newActive.rec -State $revalidated.state -CurrentRec $newCurrent.rec
        Out-Result -Status 'PASS' -Operation $ModeName.ToLowerInvariant() -Records $recsF -StateId $sidF -Diagnostics @($cleanupDiags)
    } finally {
        try {
            if ($null -ne $lock) { $lock.Dispose() }
        } catch { }
    }
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# AbortPending
# ---------------------------------------------------------------------------
function Invoke-AbortPending {
    $lock = New-WriterLock -TimeoutSeconds $LockTimeoutSeconds
    if ($null -eq $lock) {
        Out-Result -Status 'STALE' -Operation 'abortpending' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @('writer_active')
    }
    try {
        $base = Resolve-BaseState
        $baseStateId = Get-BaseStateId -Base $base
        if (-not $base.ok) {
            Out-Result -Status 'UNVERIFIED' -Operation 'abortpending' -Records @() -StateId $baseStateId -Diagnostics @()
        }
        # Pending = CURRENT is exactly one generation ahead of ACTIVE, or the
        # first-write pending at logical generation 0 (ACTIVE absent, CURRENT=1) (frozen 006.g).
        $isFirstPending = ($null -eq $base.active -and $null -ne $base.current -and $base.current.generation -eq 1)
        $isPending = ($null -ne $base.current -and (($isFirstPending) -or ($null -ne $base.active -and $base.current.generation -eq ($base.active.generation + 1))))
        if (-not $isPending) {
            Out-Result -Status 'STALE' -Operation 'abortpending' -Records @() -StateId $baseStateId -Diagnostics @()
        }
        $pdir = Get-GenDir -N $base.current.generation
        $pstate = Load-Generation -Dir $pdir -ExpectedGen $base.current.generation
        if (-not $pstate.ok -or $pstate.state.operation_id -ne $PendingOperationId) {
            Out-Result -Status 'STALE' -Operation 'abortpending' -Records @() -StateId $baseStateId -Diagnostics @()
        }
        if ($null -ne $base.active) {
            $curRestore = Get-CurrentText -Generation $base.active.generation -OperationId $base.active.operation_id -SpecSha $base.active.spec_sha256 -StateSha $base.active.state_sha256
            Set-PointerAtomic -Target (Join-Path $script:MemFull 'CURRENT') -Text $curRestore -Tag 'cur'
        } else {
            Remove-Item -LiteralPath (Join-Path $script:MemFull 'CURRENT') -Force -ErrorAction SilentlyContinue
        }
        Remove-DirTree -Path $pdir
        if ($null -ne $base.active) {
            $newActive = Parse-ActivePointer -Path (Join-Path $script:MemFull 'ACTIVE')
            $newCurrent = Parse-CurrentPointer -Path (Join-Path $script:MemFull 'CURRENT')
            $stA = Load-Generation -Dir (Get-GenDir -N $newActive.rec.generation) -ExpectedGen $newActive.rec.generation
            $sidA = Get-StateIdFromActive -ActiveRec $newActive.rec -State $stA.state -CurrentRec $newCurrent.rec
        } else {
            $sidA = Get-EmptyStateId
        }
        Out-Result -Status 'PASS' -Operation 'abortpending' -Records @() -StateId $sidA -Diagnostics @('pending_aborted:' + $PendingOperationId)
    } finally {
        try { if ($null -ne $lock) { $lock.Dispose() } } catch { }
    }
}

# ---------------------------------------------------------------------------
# FilterDeepOut
# ---------------------------------------------------------------------------
function Test-CandLine {
    param([string]$Line)
    $f = $Line -split '\|'
    if ($f.Count -ne 5) { return $false }
    if ($f[0] -notmatch '^CAND:(mem_[0-9]{4}|NO_ID)$') { return $false }
    if ($f[3].Length -lt 12) { return $false }
    if ($f[1].Length -lt 1) { return $false }
    if ($f[4].Length -lt 1) { return $false }
    return $true
}

function Invoke-FilterDeepOut {
    $outFull = [System.IO.Path]::GetFullPath($Out)
    if (-not (Test-PathInside -Path $outFull -Root $script:SpFull)) {
        Out-Result -Status 'UNVERIFIED' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @() -Extra @{ candidate_file = $null; total_cand_lines = 0; malformed_dropped = 0; out_bytes = 0 }
    }
    if (-not (Test-Path -LiteralPath $outFull)) {
        Out-Result -Status 'UNVERIFIED' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @() -Extra @{ candidate_file = $null; total_cand_lines = 0; malformed_dropped = 0; out_bytes = 0 }
    }
    $bytes = [System.IO.File]::ReadAllBytes($outFull)
    if ($bytes.Length -gt $script:OutMaxBytes) {
        Out-Result -Status 'FAILED' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @('out_exceeds_bound') -Extra @{ candidate_file = $null; total_cand_lines = 0; malformed_dropped = 0; out_bytes = $bytes.Length }
    }
    $rd = Read-StrictUtf8 -Bytes $bytes
    if (-not $rd.ok) {
        Out-Result -Status 'UNVERIFIED' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @() -Extra @{ candidate_file = $null; total_cand_lines = 0; malformed_dropped = 0; out_bytes = $bytes.Length }
    }
    $lines = $rd.text -split "`n"
    $candLines = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        $t = $ln.TrimEnd("`r")
        if ($t.StartsWith('CAND:')) { $candLines.Add($t) }
    }
    $kept = New-Object System.Collections.Generic.List[string]
    $malformed = 0
    foreach ($ln in $candLines) {
        if ($kept.Count -ge 3) { continue }
        if (Test-CandLine -Line $ln) { $kept.Add($ln) } else { $malformed++ }
    }
    $common = @{ total_cand_lines = $candLines.Count; malformed_dropped = $malformed; out_bytes = $bytes.Length }
    if ($kept.Count -eq 0) {
        $common['candidate_file'] = $null
        Out-Result -Status 'MISS' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @() -Extra $common
    }
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $candPath = Join-Path $script:SpFull ('draft_bam_deep_candidates_' + $ts + '.txt')
    $n = 2
    while (Test-Path -LiteralPath $candPath) {
        $candPath = Join-Path $script:SpFull ('draft_bam_deep_candidates_' + $ts + '_' + $n + '.txt')
        $n++
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ln in $kept) { $null = $sb.Append($ln); $null = $sb.Append("`n") }
    Write-FileExact -Path $candPath -Text $sb.ToString()
    $common['candidate_file'] = [System.IO.Path]::GetFullPath($candPath)
    Out-Result -Status 'HIT' -Operation 'filterdeepout' -Records @() -StateId (Get-EmptyStateId) -Diagnostics @() -Extra $common
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Mode) {
    'Validate' { Invoke-ReadMode -ModeName 'Validate' }
    'Status' { Invoke-ReadMode -ModeName 'Status' }
    'Recall' { Invoke-ReadMode -ModeName 'Recall' }
    'Commit' { Invoke-WriteMode -ModeName 'Commit' }
    'Forget' { Invoke-WriteMode -ModeName 'Forget' }
    'Restore' { Invoke-WriteMode -ModeName 'Restore' }
    'AbortPending' { Invoke-AbortPending }
    'FilterDeepOut' { Invoke-FilterDeepOut }
}

# Fallback: any path that reaches here is a bug; emit FAILED.
Out-Result -Status 'FAILED' -Operation $Mode.ToLowerInvariant() -Records @() -StateId (Get-EmptyStateId) -Diagnostics @()

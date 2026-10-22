# bam-adapter.ps1 — BAM core v0.7 (Bionic auxiliary memory adapter)
#
# Modes   : Bootstrap / Status / Validate / Commit / Demote
# Contract: 01_SPEC.md (same folder). Authority: requirements spec (approved 2026-10-21).
# Platform: Windows PowerShell 5.1. No network. Single-writer. No reparse gate.
# Output  : exactly one JSON line on stdout (+ Bootstrap PASS: body text after the line).
# Exit    : 0 = success (fail-open states such as NO_HOT_STATE / STALE / UNVERIFIED
#           also exit 0; the JSON status field carries the detail) / 1 = invalid
#           arguments, invalid root or internal error.
# Encoding: this file MUST stay UTF-8 with BOM (contains Japanese hints; PS 5.1).
#
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('Bootstrap', 'Status', 'Validate', 'Commit', 'Demote')]
    [string]$Mode,

    [string]$Root = '',
    [string]$ChatRoot = '',
    [string]$File = '',
    [int]$N = 0
)

$ErrorActionPreference = 'Stop'

$script:CAP_FILE_HARD     = 16384
$script:CAP_HOT_HARD      = 16384
$script:CAP_HOT_TARGET    = 4096
$script:CAP_ARCHIVE       = 65536
$script:DEMOTE_THRESHOLD  = 12288   # 80% of hard cap
$script:LOG_MAX           = 32768   # adapter.log rotation
$script:CHAT_BUDGET       = 6144    # Bootstrap combined output soft budget
$script:UTF8              = New-Object System.Text.UTF8Encoding($false, $true)
$script:UTF8NB            = New-Object System.Text.UTF8Encoding($false)
# NB: no $script:Root init here — param $Root already lives in script scope.
# Assigning $script:Root = '' here would clobber the caller's -Root value.
$script:HEADER_MARK       = '# HOT_STATE integrity header (managed by bam-adapter; do not edit)'

$script:TRACKED = @(
    'index.md',
    'canonical/policy.md',
    'canonical/profile.md',
    'canonical/facts.md',
    'state/current.md',
    'decisions/decisions.md',
    'candidates/pending.md',
    'references/archive.md',
    'runtime/HOT_STATE.md'
)

# FR-12: machine code + one-line Japanese hint (weak-LLM self-recovery loop).
$script:HINTS = @{
    'ROOT_MISSING'                = '記憶ルートが見つかりません。-Mode Bootstrap を実行して初期化してください。'
    'INVALID_ROOT'                = 'ルートパスが不正です。絶対パス、または相対パス（現在ディレクトリ基準）で -Root を指定してください。'
    'BOOTSTRAP_NO_HOT_STATE'      = 'HOT_STATE.md が見つかりません。state/current.md と必要な canonical/*.md を直接読み、要約を runtime/HOT_STATE.candidate.md に書いて -Mode Commit を実行してください。'
    'STALE_SOURCE_HASH'           = 'state/current.md が HOT_STATE 生成後に変わっています。-Mode Commit で要約を更新してください。'
    'HEADER_MISSING'              = 'HOT_STATE.md に integrity ヘッダがありません。-Mode Commit で再生成してください。'
    'HEADER_INVALID'              = 'HOT_STATE.md のヘッダが破損しています。-Mode Commit で再生成してください。'
    'ENCODING_BOM'                = 'ファイルに BOM があります。UTF-8（BOM なし）で再保存してください。'
    'ENCODING_INVALID_UTF8'       = 'ファイルに無効な UTF-8 バイトがあります。UTF-8（BOM なし）で再保存してください。'
    'ENCODING_CRLF'               = 'ファイルに CRLF 改行があります。LF 改行で保存してください（adapter の書込は常に LF に正規化されます）。'
    'SIZE_HARD_EXCEEDED'          = 'ファイルがハード上限を超過しています（各ファイル 16384B / HOT_STATE 16384B / archive 65536B）。内容を短縮するか Demote で降格してください。'
    'SIZE_TARGET_EXCEEDED'        = 'HOT_STATE が target 4096B を超過しています（hard 16384B まで可）。要約を短縮してください。'
    'SOURCE_MISSING'              = 'state/current.md が見つかりません。再作成してから -Mode Commit を実行してください。'
    'MANIFEST_MISSING'            = 'manifest.toml が見つかりません。-Mode Bootstrap でルートを再初期化するか、archive-legacy から復元してください。'
    'MANIFEST_PARSE'              = 'manifest.toml が破損しています。再初期化または archive-legacy からの復元を検討してください。'
    'INTEGRITY_MISMATCH'          = 'ファイル内容と manifest の hash が一致しません（手編集の可能性があります）。内容を確認し、-Mode Commit 経由で更新してください。'
    'MANIFEST_DRIFT'              = 'manifest のファイル一覧が実際と一致しません。再初期化または archive-legacy からの復元を検討してください。'
    'TRACKED_MISSING'             = '必要なファイルが見つかりません。-Mode Bootstrap で初期化し直すか、削除を元に戻してください。'
    'READ_FAILED'                 = 'ファイルを読み取れませんでした。ファイルのアクセス権を確認してください。'
    'COMMIT_NO_CANDIDATE'         = 'runtime/HOT_STATE.candidate.md が見つかりません。state/current.md の変更内容を短い要約として（ヘッダ不要）書いてから再実行してください。'
    'COMMIT_CANDIDATE_INVALID_UTF8' = 'candidate に無効な UTF-8 バイトがあります。UTF-8（BOM なし）で再保存してください。'
    'COMMIT_CANDIDATE_EMPTY'      = 'candidate が空です。要約を書いてから再実行してください。'
    'COMMIT_CANDIDATE_PREAMBLE_STRIPPED' = 'candidate の最初の ## より前の行を除去しました（ヘッダは adapter が自動付与します）。'
    'COMMIT_CANDIDATE_HAS_HEADER' = 'candidate に既存ヘッダがありました。除去して adapter ヘッダを付与し直しました。'
    'COMMIT_CANDIDATE_BOM_STRIPPED' = 'candidate の BOM を除去しました（出力は常に BOM なし UTF-8 です）。'
    'COMMIT_SIZE_HARD_EXCEEDED'   = 'candidate とヘッダの合計が HOT_STATE ハード上限 16384B を超過しています。要約を短縮してください。'
    'COMMIT_SOURCE_MISSING'       = 'state/current.md が見つかりません。再作成してから再実行してください。'
    'COMMIT_REPLACE_FAILED'       = 'HOT_STATE の公開に失敗しました。公開前の状態に復元しました。アクセス権を確認して再実行してください。'
    'COMMIT_POSTVALIDATE_FAILED'  = 'コミット後検証に失敗しました。rollback から公開前の状態に復元しました。'
    'COMMIT_MANIFEST_WRITE_FAILED'= 'manifest 更新に失敗しました。HOT_STATE を公開前の状態に復元しました。アクセス権を確認して再実行してください。'
    'DEMOTE_BAD_FILE'             = 'Demote の対象は canonical/facts.md と decisions/decisions.md のみです。'
    'DEMOTE_PATH_ESCAPE'          = 'パスが記憶ルート外を指しています。ルート相対パス（例: canonical/facts.md）で指定してください。'
    'DEMOTE_PATH_OUTSIDE'         = '絶対パスが記憶ルート外を指しています。記憶ルート内のファイルのみ指定できます。'
    'DEMOTE_NO_DATED_ENTRIES'     = '対象ファイルに日付付きエントリ（- YYYY-MM-DD: 形式）がありません。降格できる内容がありません。'
    'DEMOTE_NOT_NEEDED'           = 'ファイルは降格閾値（80%）を下回っています。降格は不要です。'
    'DEMOTE_INSUFFICIENT'         = '日付付きエントリを全部移動しても閾値未満になりません。古い内容を手動で整理してください。'
    'DEMOTE_BAD_N'                = '-N が日付付きエントリ件数を超過しています。'
    'DEMOTE_ARCHIVE_FULL'         = 'references/archive.md が上限（65536B）に達しています。手動で古い内容を整理してから再実行してください。'
    'DEMOTE_WRITE_FAILED'         = '降格の書込に失敗しました。すべてのファイルを降格前の状態に復元しました。'
    'INTERNAL_ERROR'              = '内部エラーです。runtime/adapter.log を確認して再実行してください。'
    'CHAT_ROOT_CREATED'           = 'チャットルートが初期化されました。チャットルートの Commit / Validate は -Root <チャットルート> で実行してください。'
    'CHAT_ROOT_MISSING'           = 'チャットルートが存在しません。-Mode Bootstrap -ChatRoot で初期化できます。'
    'CHAT_ROOT_NOT_FRESH'         = 'チャットルートの HOT_STATE が FRESH ではないため連結を省略しました。'
    'SIZE_CHAT_OVERBUDGET'        = 'Bootstrap 連結出力が ~6KB を超過しています（警告のみ・内容は省略しません）。チャットルートの要約を短くしてください。'
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

function Get-NowIso {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function ByteLen {
    param([string]$Text)
    return $script:UTF8NB.GetByteCount($Text)
}

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # Open for read with a permissive share (ReadWrite): on Windows this avoids
        # spurious sharing violations when another process (AV / editor / test lock)
        # already holds the file. Requesting ReadWrite for a read-only open is
        # strictly more compatible than requesting Read.
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $dig = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($dig) -replace '-', '').ToLower()
}

function Write-StrictText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -ne '' -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $t, $script:UTF8NB)
}

# Strict text probe for tracked memory files.
# BOM / invalid UTF-8 = error. CR (CRLF) = warning-level (ENCODING_CRLF, severity decided by caller).
# returns @{ ok; code; text; bytes }
function Test-StrictText {
    param([string]$Path)
    $bytes = @()
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return @{ ok = $false; code = 'READ_FAILED'; text = ''; bytes = @() } }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ ok = $false; code = 'ENCODING_BOM'; text = ''; bytes = $bytes }
    }
    try { $text = $script:UTF8.GetString($bytes) } catch {
        return @{ ok = $false; code = 'ENCODING_INVALID_UTF8'; text = ''; bytes = $bytes }
    }
    $hasCr = $false
    foreach ($b in $bytes) { if ($b -eq 0x0D) { $hasCr = $true; break } }
    if ($hasCr) { return @{ ok = $false; code = 'ENCODING_CRLF'; text = $text; bytes = $bytes } }
    return @{ ok = $true; code = ''; text = $text; bytes = $bytes }
}

function Resolve-RootPath {
    param([string]$In)
    if ([string]::IsNullOrWhiteSpace($In)) { $In = Join-Path $PWD 'memory' }
    try { return [System.IO.Path]::GetFullPath($In).TrimEnd('\') } catch { return '' }
}

# simple root containment (NFR-07). relative resolves under root; absolute must stay inside.
function Test-InsideRoot {
    param([string]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $cand = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
        $full = [System.IO.Path]::GetFullPath($cand)
        $root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        return ($full -ieq $root) -or ($full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Cap-Of {
    param([string]$Rel)
    if ($Rel -eq 'references/archive.md') { return $script:CAP_ARCHIVE }
    return $script:CAP_FILE_HARD
}

# ---------------------------------------------------------------------------
# manifest.toml  (machine-managed)
# ---------------------------------------------------------------------------

function Get-Manifest {
    param([string]$Root)
    $mp = Join-Path $Root 'manifest.toml'
    if (-not (Test-Path -LiteralPath $mp)) { return $null }
    $rd = Test-StrictText $mp
    if (-not $rd.ok) {
        if ($rd.code -ne 'ENCODING_CRLF') { return @{ broken = $true; integrity = @{}; meta = @{} } }
        $text = $rd.text -replace "`r`n", "`n"
    } else { $text = $rd.text }
    $integrity = @{}
    $meta = @{}
    $section = ''
    foreach ($ln in @($text -split "`n")) {
        $t = $ln.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -eq 'integrity' -and $t -match '^"(.+)"\s*=\s*"([0-9a-f]{64})"$') {
            $integrity[$Matches[1]] = $Matches[2]
        }
        elseif ($section -eq 'bundle' -and $t -match '^([a-z_]+)\s*=\s*"(.*)"$') {
            $meta[$Matches[1]] = $Matches[2]
        }
    }
    return @{ broken = $false; integrity = $integrity; meta = $meta }
}

function Write-Manifest {
    param([string]$Root, [string]$Scope, [string]$CreatedAt)
    $old = Get-Manifest $Root
    if ($null -ne $old -and -not $old.broken) {
        if ($old.meta.ContainsKey('scope')) { $Scope = $old.meta['scope'] }
        if ($old.meta.ContainsKey('created_at') -and $CreatedAt -eq '') { $CreatedAt = $old.meta['created_at'] }
    }
    if ($CreatedAt -eq '') { $CreatedAt = (Get-NowIso) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# bam-manifest v1 (machine-managed; do not edit manually)')
    $lines.Add('[bundle]')
    $lines.Add('format_version = 1')
    $lines.Add(('scope = "{0}"' -f $Scope))
    $lines.Add(('created_at = "{0}"' -f $CreatedAt))
    $lines.Add(('updated_at = "{0}"' -f (Get-NowIso)))
    $lines.Add('')
    $lines.Add('[integrity]')
    foreach ($rel in ($script:TRACKED | Sort-Object)) {
        $p = Join-Path $Root ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $p) {
            $lines.Add(('"{0}" = "{1}"' -f $rel, (Get-Sha256Hex $p)))
        }
    }
    # NFR-04: same atomic publish pattern as HOT_STATE (tmp + replace + rollback).
    # A read-only manifest is respected: the rename-based replace would bypass the
    # lock, so refuse instead (the failure surfaces as COMMIT_MANIFEST_WRITE_FAILED).
    # Restore guard (same pattern as Restore-Hot): a rollback file left by an
    # earlier successful operation is never restored blindly; only the pre-image
    # of THIS operation (verified by hash) is restored, and only when the publish
    # actually changed the file.
    $mp = Join-Path $Root 'manifest.toml'
    $tmpMp = Join-Path $Root 'manifest.toml.tmp'
    $rbMp = Join-Path $Root 'manifest.toml.rollback'
    $preMpHash = $null
    $preMpText = $null
    if (Test-Path -LiteralPath $mp) {
        if ([System.IO.File]::GetAttributes($mp) -band [System.IO.FileAttributes]::ReadOnly) {
            throw (New-Object System.Exception('manifest.toml is read-only; not bypassing the lock'))
        }
        $preMpHash = Get-Sha256Hex $mp
        try { $preMpText = [System.IO.File]::ReadAllText($mp, $script:UTF8NB) } catch { $preMpText = $null }
    }
    try {
        Write-StrictText $tmpMp (($lines -join "`n") + "`n")
        if (Test-Path -LiteralPath $mp) {
            [System.IO.File]::Replace($tmpMp, $mp, $rbMp)
        }
        else {
            [System.IO.File]::Move($tmpMp, $mp)
        }
    } catch {
        try {
            if ($preMpHash -ne $null) {
                if (-not (Test-Path -LiteralPath $mp) -or (Get-Sha256Hex $mp) -ne $preMpHash) {
                    if (Test-Path -LiteralPath $rbMp) { [System.IO.File]::Copy($rbMp, $mp, $true) }
                    elseif ($preMpText -ne $null) { Write-StrictText $mp $preMpText }
                }
            }
            else {
                if (Test-Path -LiteralPath $mp) { [System.IO.File]::Delete($mp) }
            }
        } catch { }
        try { if (Test-Path -LiteralPath $tmpMp) { [System.IO.File]::Delete($tmpMp) } } catch { }
        throw
    }
}

# ---------------------------------------------------------------------------
# HOT_STATE header
# ---------------------------------------------------------------------------

function Build-Header {
    param([string]$SrcHash, [string]$When)
    return ($script:HEADER_MARK + "`n" +
        'FORMAT_VERSION: 1' + "`n" +
        'AUTHORITY: DERIVED_NON_CANONICAL' + "`n" +
        ('GENERATED_AT: {0}' -f $When) + "`n" +
        'SOURCE_CURRENT: state/current.md' + "`n" +
        ('SOURCE_CURRENT_SHA256: {0}' -f $SrcHash) + "`n" +
        ('VALIDATED_AT: {0}' -f $When) + "`n" +
        'VALIDATION_STATUS: PASS' + "`n" +
        '---' + "`n")
}

# returns @{ ok; code; fields; body }
function Parse-Header {
    param([string]$Text)
    $lines = @($Text -split "`n")
    if ($lines.Count -lt 2 -or -not $lines[0].StartsWith('# HOT_STATE')) {
        return @{ ok = $false; code = 'HEADER_MISSING'; fields = @{}; body = '' }
    }
    $i = 1
    $fields = @{}
    while ($i -lt $lines.Count) {
        if ($lines[$i].Trim() -eq '---') { break }
        $eq = $lines[$i].IndexOf(':')
        if ($eq -lt 1) { return @{ ok = $false; code = 'HEADER_INVALID'; fields = @{}; body = '' } }
        $fields[$lines[$i].Substring(0, $eq).Trim()] = $lines[$i].Substring($eq + 1).Trim()
        $i++
    }
    if ($i -ge $lines.Count) { return @{ ok = $false; code = 'HEADER_INVALID'; fields = @{}; body = '' } }
    foreach ($req in @('FORMAT_VERSION', 'AUTHORITY', 'SOURCE_CURRENT', 'SOURCE_CURRENT_SHA256', 'VALIDATION_STATUS')) {
        if (-not $fields.ContainsKey($req)) { return @{ ok = $false; code = 'HEADER_INVALID'; fields = $fields; body = '' } }
    }
    $body = ''
    if ($i + 1 -lt $lines.Count) { $body = ($lines[($i + 1)..($lines.Count - 1)] -join "`n").Trim() }
    return @{ ok = $true; code = ''; fields = $fields; body = $body }
}

# ---------------------------------------------------------------------------
# HOT_STATE quick validation (Bootstrap / Status)
# state: FRESH | STALE | UNVERIFIED | MISSING
# ---------------------------------------------------------------------------

function Test-HotState {
    param([string]$Root)
    $hp = Join-Path $Root 'runtime\HOT_STATE.md'
    if (-not (Test-Path -LiteralPath $hp)) { return @{ state = 'MISSING'; code = 'BOOTSTRAP_NO_HOT_STATE' } }
    $rd = Test-StrictText $hp
    if (-not $rd.ok) {
        if ($rd.code -eq 'ENCODING_CRLF') { $text = $rd.text -replace "`r`n", "`n" }
        else { return @{ state = 'UNVERIFIED'; code = $rd.code } }
    } else { $text = $rd.text }
    $ph = Parse-Header $text
    if (-not $ph.ok) { return @{ state = 'UNVERIFIED'; code = $ph.code } }
    $sp = Join-Path $Root 'state\current.md'
    if (-not (Test-Path -LiteralPath $sp)) { return @{ state = 'UNVERIFIED'; code = 'SOURCE_MISSING' } }
    if ($ph.fields['SOURCE_CURRENT_SHA256'] -ne (Get-Sha256Hex $sp)) { return @{ state = 'STALE'; code = 'STALE_SOURCE_HASH' } }
    $mf = Get-Manifest $Root
    if ($null -eq $mf) { return @{ state = 'UNVERIFIED'; code = 'MANIFEST_MISSING' } }
    if ($null -ne $mf) {
        if ($mf.broken) { return @{ state = 'UNVERIFIED'; code = 'MANIFEST_PARSE' } }
        if (-not $mf.integrity.ContainsKey('runtime/HOT_STATE.md')) { return @{ state = 'UNVERIFIED'; code = 'MANIFEST_DRIFT' } }
        if ($mf.integrity['runtime/HOT_STATE.md'] -ne (Get-Sha256Hex $hp)) { return @{ state = 'UNVERIFIED'; code = 'INTEGRITY_MISMATCH' } }
    }
    return @{ state = 'FRESH'; code = '' }
}

function Get-DemoteHints {
    param([string]$Root)
    $hints = New-Object System.Collections.ArrayList
    foreach ($rel in @('canonical/facts.md', 'decisions/decisions.md')) {
        $p = Join-Path $Root ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $p) {
            $sz = (Get-Item -LiteralPath $p).Length
            if ($sz -gt $script:DEMOTE_THRESHOLD) {
                $pct = [int][math]::Floor(($sz * 100.0) / $script:CAP_FILE_HARD)
                [void]$hints.Add(('{0} at {1}%' -f $rel, $pct))
            }
        }
    }
    return $hints
}

# ---------------------------------------------------------------------------
# templates (initial state = empty template, FR-14)
# ---------------------------------------------------------------------------

function Get-IndexTemplate {
    $self = 'bam-adapter.ps1 (see INSTALL_RECEIPT.json next to the installed skill for the actual path)'
    if ($PSScriptRoot) { $self = (Join-Path $PSScriptRoot 'bam-adapter.ps1') }
    $tpl = @'
# BAM index - AI operating contract

This memory root is managed by a single adapter, `bam-adapter.ps1`.
Adapter path: `@@ADAPTER_PATH@@` (global placement).
Run every command with `-Root <this memory root>` (add `-ChatRoot` for a chat root).
Single-writer assumption. No network use.

## Read order (once at session start / after compaction / on handoff receipt)
1. Run `-Mode Bootstrap` (add `-ChatRoot <chat root>` if a chat root exists).
   - On PASS the HOT_STATE body is printed. On NO_HOT_STATE / STALE / UNVERIFIED, follow the pointer instructions and read the files directly (never block the session).
2. Read HOT_STATE first. If it is insufficient, read `state/current.md`; if still insufficient, read only the `canonical/*.md` / `decisions/decisions.md` files you need.
3. Never compute hashes. Never edit `manifest.toml`. Never edit `runtime/HOT_STATE.md` or its integrity header directly.

## Content type -> file mapping (the write target is decided by content type)
| content type | write target |
|---|---|
| verified fact (with source and verification scope) | `canonical/facts.md` (append-only, dated) |
| user preferences / settings | `canonical/profile.md` |
| currently adopted work policy | `canonical/policy.md` |
| current goal / state / next action / unresolved | `state/current.md` |
| significant decision and its rationale | `decisions/decisions.md` (append-only, dated) |
| unverified candidate (silent promotion forbidden) | `candidates/pending.md` |

- facts / decisions format: one entry = one line `- YYYY-MM-DD: <content> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED]`. Append new entries at the end. Never rewrite an old entry (a change is a correction entry with a new date, appended at the end).
- The provenance label (MACHINE_VERIFIED / USER_STATED / UNVERIFIED) is mandatory on every entry.
- Never store secrets (credentials, etc.) or full conversation transcripts.

## Write discipline
- No semantic change = no write (the primary rule against bloat).
- After changing memory (especially `state/current.md`): write a short summary into `runtime/HOT_STATE.candidate.md` (**no integrity header required**; lines before the first `##` are safely stripped) -> run `-Mode Commit`.
- **Stored memory is not execution authorization. Never store GO / approval / execution authority.**

## Demotion
- When the adapter prints `DEMOTE_SUGGESTED <file> at NN%` (it may appear in Status / Bootstrap / Commit output), just run `-Mode Demote -File <file>`. Do not decide how many entries to move and do not operate on files by hand.
- Older / demoted material lives in `references/archive.md`. Read it only when the user asks for past detail or the current files lack the information you need.
- To re-promote a demoted entry: write it back into the current file with a new date (no special mechanism).

## Natural commands (Japanese triggers)
- 「補助記憶ブートして」 = run `-Mode Bootstrap` once
- 「補助記憶に反映して」 = write files per the mapping + write the candidate + run `-Mode Commit`
- 「チャット単位の補助記憶を有効に」 = initialize with `-Mode Bootstrap -ChatRoot <chat root>` (default chat root: `<scratchpad>\memory`). Chat selection is NOT stored: pass `-ChatRoot` on every Bootstrap; the chat HOT_STATE is concatenated automatically when the chat root exists and is FRESH. Commit / Validate for the chat are run with `-Root <chat root>`.

## Sizes
- Hot files <= 16384 B (HOT_STATE: target 4096 B / hard 16384 B). `references/archive.md` <= 65536 B.
'@
    return $tpl.Replace('@@ADAPTER_PATH@@', $self)
}

function New-Template {
    param([string]$Root, [string]$Scope)
    $files = [ordered]@{}
    $files['index.md'] = (Get-IndexTemplate)
    $files['canonical/policy.md'] = "# policy（現在採用中の作業 policy）`n`n<!-- 自由形式で編集。GO / 認可は保存しない。 -->`n"
    $files['canonical/profile.md'] = "# profile（ユーザー設定・好み）`n`n<!-- 自由形式で編集。 -->`n"
    $files['canonical/facts.md'] = "# facts（検証済み事実）`n`n<!-- 追記型。1 エントリ = 1 行: - YYYY-MM-DD: <内容> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED] -->`n"
    $files['state/current.md'] = "# current（現在の状態）`n`n## 目的`n（なし）`n`n## 状態`n（なし）`n`n## next action`n（なし）`n`n## unresolved`n（なし）`n"
    $files['decisions/decisions.md'] = "# decisions（重要決定）`n`n<!-- 追記型。1 エントリ = 1 行: - YYYY-MM-DD: <決定 + 根拠> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED] -->`n"
    $files['candidates/pending.md'] = "# candidates（未検証候補）`n`n<!-- 未検証項目。黙認昇格禁止: 検証・確認したら facts.md 等へ新日付 + ラベルで移動。 -->`n"
    $files['references/archive.md'] = "# archive（降格先・cold tier）`n`n<!-- 古い facts / decisions の機械移動先。読取は「ユーザーが過去の詳細を求めた時、または現ファイルに必要な情報がない時」のみ。 -->`n"
    foreach ($k in @($files.Keys)) {
        Write-StrictText (Join-Path $Root ($k -replace '/', '\')) $files[$k]
    }
    $srcP = Join-Path $Root 'state\current.md'
    $hdr = Build-Header (Get-Sha256Hex $srcP) (Get-NowIso)
    $hotBody = '# 初期状態' + "`n`n" + '- まだ記録はありません。記憶を書いたら、短い要約を runtime/HOT_STATE.candidate.md に書いて -Mode Commit で公開してください。'
    Write-StrictText (Join-Path $Root 'runtime\HOT_STATE.md') ($hdr + $hotBody + "`n")
    New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
    Write-Manifest $Root $Scope ''
    return (@($files.Keys).Count + 1)
}

# ---------------------------------------------------------------------------
# log (NFR-06: 32 KB rotation; fail-open)
# ---------------------------------------------------------------------------

function Log-Op {
    param([string]$JsonLine)
    try {
        if ($script:Root -eq '' -or -not (Test-Path -LiteralPath $script:Root)) { return }
        $rt = Join-Path $script:Root 'runtime'
        if (-not (Test-Path -LiteralPath $rt)) { New-Item -ItemType Directory -Path $rt -Force | Out-Null }
        $lp = Join-Path $rt 'adapter.log'
        if (Test-Path -LiteralPath $lp) {
            if ((Get-Item -LiteralPath $lp).Length -gt $script:LOG_MAX) {
                [System.IO.File]::Move($lp, (Join-Path $rt 'adapter.log.1'), $true)
            }
        }
        [System.IO.File]::AppendAllText($lp, ($JsonLine + "`n"), $script:UTF8NB)
    } catch { }
}

function Emit {
    param($Obj, [string]$BodyText = '', [int]$ExitCode = 0)
    $json = ($Obj | ConvertTo-Json -Compress -Depth 8)
    Log-Op $json
    [Console]::Out.Write($json + "`n")
    if ($BodyText -ne '') { [Console]::Out.Write($BodyText + "`n") }
    [Console]::Out.Flush()
    exit $ExitCode
}

function New-Warning {
    param([string]$Code)
    $h = ''
    if ($script:HINTS.ContainsKey($Code)) { $h = $script:HINTS[$Code] }
    return @{ code = $Code; hint_ja = $h }
}

try {
    [Console]::OutputEncoding = $script:UTF8NB
} catch { }

try {

    # -----------------------------------------------------------------------
    # Bootstrap
    # -----------------------------------------------------------------------
    if ($Mode -eq 'Bootstrap') {
        $root = Resolve-RootPath $Root
        if ($root -eq '') {
            Emit ([ordered]@{ operation = 'bootstrap'; status = 'FAIL'; code = 'INVALID_ROOT'; hint_ja = $script:HINTS['INVALID_ROOT'] }) '' 1
        }
        $script:Root = $root
        $chat = ''
        $chatCreated = $false
        if (-not [string]::IsNullOrWhiteSpace($ChatRoot)) { $chat = Resolve-RootPath $ChatRoot }
        # An explicit -ChatRoot is an explicit intent to have a chat root: initialize
        # it independently of project creation (existing project and existing chat
        # roots are kept). Degenerate case -ChatRoot == root: behavior unchanged.
        if ($chat -ne '' -and $chat -ne $root -and -not (Test-Path -LiteralPath $chat)) {
            $null = New-Template $chat 'chat'
            $chatCreated = $true
        }

        if (-not (Test-Path -LiteralPath $root)) {
            $n = New-Template $root 'project'
            $idxText = ''
            $idxP = Join-Path $root 'index.md'
            if (Test-Path -LiteralPath $idxP) { $idxText = [System.IO.File]::ReadAllText($idxP, $script:UTF8NB) }
            Emit ([ordered]@{ operation = 'bootstrap'; status = 'INITIALIZED'; root = $root; files_created = $n; chat_root_created = $chatCreated; hint_ja = '初期化しました。以下に AI 操作契約（index.md）を出力します。' }) $idxText 0
        }

        $hs = Test-HotState $root
        $demoteHints = Get-DemoteHints $root
        if ($hs.state -eq 'FRESH') {
            $hotP = Join-Path $root 'runtime\HOT_STATE.md'
            $rd = Test-StrictText $hotP
            $text = if ($rd.ok) { $rd.text } else { ($rd.text -replace "`r`n", "`n") }
            $ph = Parse-Header $text
            $out = $ph.body
            $chatIncluded = $false
            $warns = New-Object System.Collections.ArrayList
            if ($chat -ne '') {
                if (Test-Path -LiteralPath $chat) {
                    $ch = Test-HotState $chat
                    if ($ch.state -eq 'FRESH') {
                        $chrd = Test-StrictText (Join-Path $chat 'runtime\HOT_STATE.md')
                        $chtext = if ($chrd.ok) { $chrd.text } else { ($chrd.text -replace "`r`n", "`n") }
                        $chph = Parse-Header $chtext
                        $out = $out + "`n`n<!-- BAM scope: chat -->`n" + $chph.body
                        $chatIncluded = $true
                        if ((ByteLen $out) -gt $script:CHAT_BUDGET) { [void]$warns.Add((New-Warning 'SIZE_CHAT_OVERBUDGET')) }
                    } else {
                        [void]$warns.Add(@{ code = 'CHAT_ROOT_NOT_FRESH'; hint_ja = ($script:HINTS['CHAT_ROOT_NOT_FRESH'] + ' state=' + $ch.state) })
                    }
                } else {
                    [void]$warns.Add((New-Warning 'CHAT_ROOT_MISSING'))
                }
            }
            if ($chatCreated) { [void]$warns.Add((New-Warning 'CHAT_ROOT_CREATED')) }
            Emit ([ordered]@{
                operation = 'bootstrap'; status = 'PASS'; root = $root; chat_included = $chatIncluded
                chat_root_created = $chatCreated
                hot_state_bytes = (ByteLen $out); demote_suggested = @($demoteHints); warnings = @($warns)
            }) $out 0
        } else {
            $st = if ($hs.state -eq 'MISSING') { 'NO_HOT_STATE' } else { $hs.state }
            $hint = if ($script:HINTS.ContainsKey($hs.code)) { $script:HINTS[$hs.code] } else { $script:HINTS['INTERNAL_ERROR'] }
            Emit ([ordered]@{
                operation = 'bootstrap'; status = $st; root = $root; code = $hs.code; hint_ja = $hint
                pointer = 'state/current.md と必要な canonical/*.md を直接読んでください（セッションはブロックしません）'
                demote_suggested = @($demoteHints)
            }) '' 0
        }
    }

    # -----------------------------------------------------------------------
    # Status
    # -----------------------------------------------------------------------
    elseif ($Mode -eq 'Status') {
        $root = Resolve-RootPath $Root
        $script:Root = $root
        if ($root -eq '' -or -not (Test-Path -LiteralPath $root)) {
            Emit ([ordered]@{ operation = 'status'; status = 'MISSING_ROOT'; code = 'ROOT_MISSING'; hint_ja = $script:HINTS['ROOT_MISSING'] }) '' 0
        }
        $files = 0
        $total = 0
        foreach ($rel in $script:TRACKED) {
            $p = Join-Path $root ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $p) { $files++; $total += (Get-Item -LiteralPath $p).Length }
        }
        $hs = Test-HotState $root
        $mfState = 'OK'
        $mf = Get-Manifest $root
        $missingTracked = New-Object System.Collections.Generic.List[string]
        if ($null -eq $mf) { $mfState = 'MISSING' }
        elseif ($mf.broken) { $mfState = 'BROKEN' }
        else {
            $mismatch = $false
            foreach ($rel in $script:TRACKED) {
                $p = Join-Path $root ($rel -replace '/', '\')
                if (Test-Path -LiteralPath $p) {
                    if (-not $mf.integrity.ContainsKey($rel) -or $mf.integrity[$rel] -ne (Get-Sha256Hex $p)) { $mismatch = $true }
                }
                else { $missingTracked.Add($rel) }
            }
            if ($mismatch) { $mfState = 'MISMATCH' }
            elseif ($missingTracked.Count -gt 0) { $mfState = 'TRACKED_MISSING' }
        }
        Emit ([ordered]@{
            operation = 'status'; status = 'OK'; root = $root; files = $files; total_bytes = $total
            hot_state = $hs.state; manifest = $mfState; manifest_missing = @($missingTracked)
            demote_suggested = @((Get-DemoteHints $root))
        }) '' 0
    }

    # -----------------------------------------------------------------------
    # Validate
    # -----------------------------------------------------------------------
    elseif ($Mode -eq 'Validate') {
        $root = Resolve-RootPath $Root
        $script:Root = $root
        if ($root -eq '' -or -not (Test-Path -LiteralPath $root)) {
            Emit ([ordered]@{ operation = 'validate'; status = 'FAIL'; code = 'ROOT_MISSING'; hint_ja = $script:HINTS['ROOT_MISSING'] }) '' 1
        }
        $errs = New-Object System.Collections.ArrayList
        $warns = New-Object System.Collections.ArrayList
        foreach ($rel in $script:TRACKED) {
            $p = Join-Path $root ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $p)) {
                [void]$errs.Add(@{ code = 'TRACKED_MISSING'; file = $rel })
                continue
            }
            $rd = Test-StrictText $p
            if (-not $rd.ok) {
                if ($rd.code -eq 'ENCODING_CRLF') {
                    # CRLF is warning-level only; the hard cap is checked independently
                    # (a CRLF file may still exceed the cap).
                    [void]$warns.Add(@{ code = 'ENCODING_CRLF'; file = $rel })
                }
                else { [void]$errs.Add(@{ code = $rd.code; file = $rel }); continue }
            }
            $cap = Cap-Of $rel
            if ($rd.bytes.Length -gt $cap) { [void]$errs.Add(@{ code = 'SIZE_HARD_EXCEEDED'; file = $rel }) }
        }
        # HOT_STATE specifics
        $hp = Join-Path $root 'runtime\HOT_STATE.md'
        if (Test-Path -LiteralPath $hp) {
            $rd = Test-StrictText $hp
            $text = if ($rd.ok) { $rd.text } else { ($rd.text -replace "`r`n", "`n") }
            $ph = Parse-Header $text
            if (-not $ph.ok) { [void]$errs.Add(@{ code = $ph.code; file = 'runtime/HOT_STATE.md' }) }
            if ($ph.ok) {
                $sp = Join-Path $root 'state\current.md'
                if (-not (Test-Path -LiteralPath $sp)) {
                    [void]$errs.Add(@{ code = 'SOURCE_MISSING'; file = 'state/current.md' })
                }
                elseif ($ph.fields['SOURCE_CURRENT_SHA256'] -ne (Get-Sha256Hex $sp)) {
                    [void]$errs.Add(@{ code = 'STALE_SOURCE_HASH'; file = 'runtime/HOT_STATE.md' })
                }
                if ((ByteLen $ph.body) -gt $script:CAP_HOT_TARGET) {
                    [void]$warns.Add(@{ code = 'SIZE_TARGET_EXCEEDED'; file = 'runtime/HOT_STATE.md' })
                }
            }
        }
        # manifest
        $mf = Get-Manifest $root
        if ($null -eq $mf) {
            [void]$errs.Add(@{ code = 'MANIFEST_MISSING'; file = 'manifest.toml' })
        }
        elseif ($mf.broken) {
            [void]$errs.Add(@{ code = 'MANIFEST_PARSE'; file = 'manifest.toml' })
        }
        else {
            foreach ($rel in $script:TRACKED) {
                $p = Join-Path $root ($rel -replace '/', '\')
                if (Test-Path -LiteralPath $p) {
                    if (-not $mf.integrity.ContainsKey($rel)) { [void]$errs.Add(@{ code = 'MANIFEST_DRIFT'; file = $rel }) }
                    elseif ($mf.integrity[$rel] -ne (Get-Sha256Hex $p)) { [void]$errs.Add(@{ code = 'INTEGRITY_MISMATCH'; file = $rel }) }
                }
            }
        }
        # Precompute warning hints with plain if-statements: a parenthesized
        # if-expression in argument position breaks PS 5.1 at runtime
        # ("The term 'if' is not recognized").
        # Note: on this PS 5.1, `@()` applied directly to a List[object] throws
        # ArgumentException (binder quirk); use .ToArray() at the wrap site.
        $warnList = New-Object System.Collections.Generic.List[object]
        foreach ($w in $warns) {
            $wh = ''
            if ($script:HINTS.ContainsKey($w.code)) { $wh = $script:HINTS[$w.code] }
            $warnList.Add([ordered]@{ code = $w.code; file = $w.file; hint_ja = $wh })
        }
        if ($errs.Count -gt 0) {
            $codes = @()
            foreach ($e in $errs) { $codes += ('{0}:{1}' -f $e.code, $e.file) }
            $first = $errs[0]
            # FR-12 (weak-LLM self-recovery): when present, SOURCE_MISSING takes
            # precedence as the primary code (its hint - recreate state/current.md
            # and Commit - is the actionable one).
            foreach ($e in $errs) { if ($e.code -eq 'SOURCE_MISSING') { $first = $e; break } }
            $hint = if ($script:HINTS.ContainsKey($first.code)) { $script:HINTS[$first.code] } else { $script:HINTS['INTERNAL_ERROR'] }
            Emit ([ordered]@{
                operation = 'validate'; status = 'FAIL'; root = $root; code = $first.code; hint_ja = $hint
                codes = $codes
                warnings = @($warnList.ToArray())
            }) '' 1
        }
        Emit ([ordered]@{
            operation = 'validate'; status = 'PASS'; root = $root; codes = @()
            warnings = @($warnList.ToArray())
        }) '' 0
    }

    # -----------------------------------------------------------------------
    # Commit
    # -----------------------------------------------------------------------
    elseif ($Mode -eq 'Commit') {
        $root = Resolve-RootPath $Root
        $script:Root = $root
        if ($root -eq '' -or -not (Test-Path -LiteralPath $root)) {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'ROOT_MISSING'; hint_ja = $script:HINTS['ROOT_MISSING'] }) '' 1
        }
        $candP = Join-Path $root 'runtime\HOT_STATE.candidate.md'
        if (-not (Test-Path -LiteralPath $candP)) {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_NO_CANDIDATE'; hint_ja = $script:HINTS['COMMIT_NO_CANDIDATE'] }) '' 1
        }
        $warns = New-Object System.Collections.ArrayList
        $cbytes = @()
        try { $cbytes = [System.IO.File]::ReadAllBytes($candP) } catch {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'READ_FAILED'; hint_ja = $script:HINTS['READ_FAILED'] }) '' 1
        }
        if ($cbytes.Length -ge 3 -and $cbytes[0] -eq 0xEF -and $cbytes[1] -eq 0xBB -and $cbytes[2] -eq 0xBF) {
            $cbytes = @($cbytes[3..($cbytes.Length - 1)])
            [void]$warns.Add((New-Warning 'COMMIT_CANDIDATE_BOM_STRIPPED'))
        }
        $ctext = ''
        try { $ctext = $script:UTF8.GetString($cbytes) } catch {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_CANDIDATE_INVALID_UTF8'; hint_ja = $script:HINTS['COMMIT_CANDIDATE_INVALID_UTF8'] }) '' 1
        }
        $ctext = $ctext -replace "`r`n", "`n"
        $ctext = $ctext -replace "`r", "`n"
        $clines = @($ctext -split "`n")
        $body = ''
        if ($clines.Count -ge 1 -and $clines[0].StartsWith('# HOT_STATE')) {
            $i = 1
            while ($i -lt $clines.Count -and $clines[$i].Trim() -ne '---') { $i++ }
            $body = ''
            if ($i + 1 -lt $clines.Count) { $body = ($clines[($i + 1)..($clines.Count - 1)] -join "`n").Trim() }
            [void]$warns.Add((New-Warning 'COMMIT_CANDIDATE_HAS_HEADER'))
        }
        else {
            $idx = -1
            for ($j = 0; $j -lt $clines.Count; $j++) {
                if ($clines[$j].StartsWith('## ')) { $idx = $j; break }
            }
            if ($idx -gt 0) {
                $body = ($clines[$idx..($clines.Count - 1)] -join "`n").Trim()
                [void]$warns.Add((New-Warning 'COMMIT_CANDIDATE_PREAMBLE_STRIPPED'))
            }
            else { $body = $ctext.Trim() }
        }
        if ($body -eq '') {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_CANDIDATE_EMPTY'; hint_ja = $script:HINTS['COMMIT_CANDIDATE_EMPTY']; warnings = @($warns) }) '' 1
        }
        $srcP = Join-Path $root 'state\current.md'
        if (-not (Test-Path -LiteralPath $srcP)) {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_SOURCE_MISSING'; hint_ja = $script:HINTS['COMMIT_SOURCE_MISSING']; warnings = @($warns) }) '' 1
        }
        $srcHash = Get-Sha256Hex $srcP
        $when = Get-NowIso
        $composed = (Build-Header $srcHash $when) + $body + "`n"
        if ((ByteLen $composed) -gt $script:CAP_HOT_HARD) {
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_SIZE_HARD_EXCEEDED'; hint_ja = $script:HINTS['COMMIT_SIZE_HARD_EXCEEDED']; warnings = @($warns) }) '' 1
        }
        if ((ByteLen $body) -gt $script:CAP_HOT_TARGET) { [void]$warns.Add((New-Warning 'SIZE_TARGET_EXCEEDED')) }

        $hotP = Join-Path $root 'runtime\HOT_STATE.md'
        $rbP = Join-Path $root 'runtime\HOT_STATE.md.rollback.md'
        $tmpP = Join-Path $root 'runtime\HOT_STATE.md.tmp'
        $preHash = $null
        $preText = $null
        if (Test-Path -LiteralPath $hotP) {
            $preHash = Get-Sha256Hex $hotP
            try { $preText = [System.IO.File]::ReadAllText($hotP, $script:UTF8NB) } catch { $preText = $null }
        }
        function Restore-Hot {
            param($HotP, $RbP, $PreHash, $PreText)
            try {
                if ($preHash -ne $null) {
                    if (-not (Test-Path -LiteralPath $HotP) -or (Get-Sha256Hex $HotP) -ne $PreHash) {
                        if (Test-Path -LiteralPath $RbP) { [System.IO.File]::Copy($RbP, $HotP, $true) }
                        elseif ($preText -ne $null) { Write-StrictText $HotP $preText }
                    }
                }
                else {
                    if (Test-Path -LiteralPath $HotP) { [System.IO.File]::Delete($HotP) }
                }
            } catch { }
        }
        try {
            Write-StrictText $tmpP $composed
            if (Test-Path -LiteralPath $hotP) {
                [System.IO.File]::Replace($tmpP, $hotP, $rbP)
            }
            else {
                [System.IO.File]::Move($tmpP, $hotP)
            }
        } catch {
            Restore-Hot $hotP $rbP $preHash $preText
            try { if (Test-Path -LiteralPath $tmpP) { [System.IO.File]::Delete($tmpP) } } catch { }
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_REPLACE_FAILED'; hint_ja = $script:HINTS['COMMIT_REPLACE_FAILED']; warnings = @($warns) }) '' 1
        }
        # post-commit revalidation
        $ok = $true
        $failCode = ''
        $rd = Test-StrictText $hotP
        if (-not $rd.ok) {
            if ($rd.code -eq 'ENCODING_CRLF') { $htext = ($rd.text -replace "`r`n", "`n") }
            else { $ok = $false; $failCode = $rd.code }
        } else { $htext = $rd.text }
        if ($ok) {
            $ph = Parse-Header $htext
            if (-not $ph.ok) { $ok = $false; $failCode = $ph.code }
            elseif ($ph.fields['SOURCE_CURRENT_SHA256'] -ne (Get-Sha256Hex $srcP)) { $ok = $false; $failCode = 'STALE_SOURCE_HASH' }
        }
        if ((Test-Path -LiteralPath $hotP) -and ((Get-Item -LiteralPath $hotP).Length -gt $script:CAP_HOT_HARD)) { $ok = $false; if ($failCode -eq '') { $failCode = 'SIZE_HARD_EXCEEDED' } }
        if (-not $ok) {
            Restore-Hot $hotP $rbP $preHash $preText
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_POSTVALIDATE_FAILED'; hint_ja = $script:HINTS['COMMIT_POSTVALIDATE_FAILED']; warnings = @($warns) }) '' 1
        }
        try {
            Write-Manifest $root '' ''
        } catch {
            Restore-Hot $hotP $rbP $preHash $preText
            Emit ([ordered]@{ operation = 'commit'; status = 'FAIL'; code = 'COMMIT_MANIFEST_WRITE_FAILED'; hint_ja = $script:HINTS['COMMIT_MANIFEST_WRITE_FAILED']; warnings = @($warns) }) '' 1
        }
        try { [System.IO.File]::Delete($candP) } catch { [void]$warns.Add(@{ code = 'COMMIT_CANDIDATE_DELETE_FAILED'; hint_ja = 'candidate の削除に失敗しました（内容は公開済み・次回 Commit 前に削除してください）' }) }
        Emit ([ordered]@{
            operation = 'commit'; status = 'PASS'; root = $root
            hot_state_bytes = (Get-Item -LiteralPath $hotP).Length
            warnings = @($warns | ForEach-Object { if ($_ -is [hashtable]) { @{ code = $_.code; hint_ja = $_.hint_ja } } else { $_ } })
        }) '' 0
    }

    # -----------------------------------------------------------------------
    # Demote
    # -----------------------------------------------------------------------
    elseif ($Mode -eq 'Demote') {
        $root = Resolve-RootPath $Root
        $script:Root = $root
        if ($root -eq '' -or -not (Test-Path -LiteralPath $root)) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'ROOT_MISSING'; hint_ja = $script:HINTS['ROOT_MISSING'] }) '' 1
        }
        if ([string]::IsNullOrWhiteSpace($File)) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_BAD_FILE'; hint_ja = $script:HINTS['DEMOTE_BAD_FILE'] }) '' 1
        }
        if (-not (Test-InsideRoot $root $File)) {
            $pathCode = if ([System.IO.Path]::IsPathRooted($File)) { 'DEMOTE_PATH_OUTSIDE' } else { 'DEMOTE_PATH_ESCAPE' }
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = $pathCode; hint_ja = $script:HINTS[$pathCode] }) '' 1
        }
        $rel = ($File -replace '\\', '/').TrimStart('/')
        if ($rel -ne 'canonical/facts.md' -and $rel -ne 'decisions/decisions.md') {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_BAD_FILE'; hint_ja = $script:HINTS['DEMOTE_BAD_FILE'] }) '' 1
        }
        $srcP = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $srcP)) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'TRACKED_MISSING'; hint_ja = $script:HINTS['TRACKED_MISSING'] }) '' 1
        }
        $archP = Join-Path $root 'references\archive.md'
        if (-not (Test-Path -LiteralPath $archP)) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'TRACKED_MISSING'; hint_ja = $script:HINTS['TRACKED_MISSING'] }) '' 1
        }
        # read src (fail-tolerant: BOM strip + CRLF normalize; output always strict)
        $sbytes = [System.IO.File]::ReadAllBytes($srcP)
        if ($sbytes.Length -ge 3 -and $sbytes[0] -eq 0xEF -and $sbytes[1] -eq 0xBB -and $sbytes[2] -eq 0xBF) { $sbytes = @($sbytes[3..($sbytes.Length - 1)]) }
        $stext = $script:UTF8.GetString($sbytes)
        $stext = $stext -replace "`r`n", "`n"
        $slines = @($stext -split "`n")
        if ($slines.Count -gt 0 -and $slines[-1] -eq '') { $slines = @($slines[0..($slines.Count - 2)]) }
        $dated = New-Object System.Collections.Generic.List[int]
        for ($j = 0; $j -lt $slines.Count; $j++) {
            if ($slines[$j] -match '^- \d{4}-\d{2}-\d{2}: ') { [void]$dated.Add($j) }
        }
        if ($dated.Count -eq 0) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_NO_DATED_ENTRIES'; hint_ja = $script:HINTS['DEMOTE_NO_DATED_ENTRIES'] }) '' 1
        }
        $curSize = (Get-Item -LiteralPath $srcP).Length
        $hasPointer = $false
        foreach ($ln in $slines) { if ($ln.Contains('demote-pointer:')) { $hasPointer = $true; break } }
        $n = $N
        if ($n -le 0) {
            if ($curSize -le $script:DEMOTE_THRESHOLD) {
                Emit ([ordered]@{ operation = 'demote'; status = 'NOT_NEEDED'; code = 'DEMOTE_NOT_NEEDED'; hint_ja = $script:HINTS['DEMOTE_NOT_NEEDED']; file = $rel }) '' 0
            }
            $pointerLine = ('<!-- demote-pointer: oldest entries moved to references/archive.md ({0}) -->' -f (Get-NowIso))
            $baseDelta = 0
            if (-not $hasPointer) { $baseDelta = (ByteLen $pointerLine) + 1 }
            $running = $curSize
            $n = 0
            for ($k = 0; $k -lt $dated.Count; $k++) {
                $running -= (ByteLen $slines[$dated[$k]]) + 1
                if ($k -eq 0) { $running += $baseDelta }
                if ($running -lt $script:DEMOTE_THRESHOLD) { $n = $k + 1; break }
            }
            if ($n -le 0) {
                Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_INSUFFICIENT'; hint_ja = $script:HINTS['DEMOTE_INSUFFICIENT']; file = $rel }) '' 1
            }
        }
        if ($n -gt $dated.Count) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_BAD_N'; hint_ja = $script:HINTS['DEMOTE_BAD_N']; file = $rel; dated_entries = $dated.Count }) '' 1
        }
        $moved = @()
        for ($k = 0; $k -lt $n; $k++) { $moved += $slines[$dated[$k]] }
        $movedSet = @{}
        foreach ($m in $moved) { $movedSet[$m] = $true }
        $movedBytes = 0
        foreach ($m in $moved) { $movedBytes += (ByteLen $m) + 1 }
        # archive capacity check
        $abytes = [System.IO.File]::ReadAllBytes($archP)
        $atext = $script:UTF8.GetString($abytes)
        $atext = $atext -replace "`r`n", "`n"
        if (($atext -notmatch '[\r\n]$') -and $atext -ne '') { $atext = $atext + "`n" }
        $archNewSize = (ByteLen $atext) + $movedBytes
        if ($archNewSize -gt $script:CAP_ARCHIVE) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_ARCHIVE_FULL'; hint_ja = $script:HINTS['DEMOTE_ARCHIVE_FULL']; archive_bytes = $archNewSize; cap = $script:CAP_ARCHIVE }) '' 1
        }
        # build new src
        $nslines = New-Object System.Collections.Generic.List[string]
        foreach ($ln in $slines) { if (-not $movedSet.ContainsKey($ln)) { [void]$nslines.Add($ln) } }
        $pointerLine = ('<!-- demote-pointer: oldest entries moved to references/archive.md ({0}) -->' -f (Get-NowIso))
        if (-not $hasPointer) { [void]$nslines.Add($pointerLine) }
        $newSrc = ($nslines -join "`n") + "`n"
        if ((ByteLen $newSrc) -gt $script:CAP_FILE_HARD) {
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_INSUFFICIENT'; hint_ja = $script:HINTS['DEMOTE_INSUFFICIENT']; file = $rel }) '' 1
        }
        $newArch = $atext
        foreach ($m in $moved) { $newArch = $newArch + $m + "`n" }
        # atomic write (two files) + rollback
        $tmpSrc = Join-Path $root 'runtime\demote.src.tmp'
        $tmpArch = Join-Path $root 'runtime\demote.archive.tmp'
        # Regression note: `Join-Path $a $b + $c` (command form) passes '+' as a
        # literal argument (no operator precedence in command form). Parenthesize.
        $rbSrc = Join-Path $root (($rel -replace '/', '\') + '.rollback.md')
        $rbArch = Join-Path $root 'references\archive.md.rollback.md'
        $preSrcHash = Get-Sha256Hex $srcP
        $preArchHash = Get-Sha256Hex $archP
        $preSrcText = $stext
        $preArchText = $atext
        $doneSrc = $false
        $doneArch = $false
        try {
            Write-StrictText $tmpSrc $newSrc
            Write-StrictText $tmpArch $newArch
            [System.IO.File]::Replace($tmpArch, $archP, $rbArch)
            $doneArch = $true
            [System.IO.File]::Replace($tmpSrc, $srcP, $rbSrc)
            $doneSrc = $true
        } catch {
            if ($doneArch) { try { [System.IO.File]::Copy($rbArch, $archP, $true) } catch { try { Write-StrictText $archP $preArchText } catch { } } }
            if ($doneSrc) { try { [System.IO.File]::Copy($rbSrc, $srcP, $true) } catch { try { Write-StrictText $srcP $preSrcText } catch { } } }
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_WRITE_FAILED'; hint_ja = $script:HINTS['DEMOTE_WRITE_FAILED']; file = $rel }) '' 1
        }
        try {
            Write-Manifest $root '' ''
        } catch {
            try { [System.IO.File]::Copy($rbArch, $archP, $true) } catch { }
            try { [System.IO.File]::Copy($rbSrc, $srcP, $true) } catch { }
            Emit ([ordered]@{ operation = 'demote'; status = 'FAIL'; code = 'DEMOTE_WRITE_FAILED'; hint_ja = $script:HINTS['DEMOTE_WRITE_FAILED']; file = $rel }) '' 1
        }
        $hints = Get-DemoteHints $root
        Emit ([ordered]@{
            operation = 'demote'; status = 'DEMOTED'; root = $root; file = $rel; count = $n
            src_bytes = (Get-Item -LiteralPath $srcP).Length
            archive_bytes = (Get-Item -LiteralPath $archP).Length
            demote_suggested = @($hints)
        }) '' 0
    }
}
catch {
    $msg = $_.Exception.Message
    try {
        Emit ([ordered]@{ operation = $Mode.ToLower(); status = 'FAIL'; code = 'INTERNAL_ERROR'; hint_ja = ($script:HINTS['INTERNAL_ERROR'] + ' detail=' + $msg) }) '' 1
    } catch {
        Write-Host ('INTERNAL_ERROR: ' + $msg)
        exit 1
    }
}

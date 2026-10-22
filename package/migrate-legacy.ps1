# migrate-legacy.ps1 — BAM one-shot migration script (legacy v0.6 -> BAM v0.7)
#
# Modes : Dump | Retreat | Verify
# Policy: one-shot, out of production core (requirements FR-11). Never writes to the legacy tree.
#         Non-destructive: refuses to overwrite an existing destination (MIG_DEST_EXISTS).
# Output: exactly one JSON line on stdout. Exit 0 = success / 1 = FAIL.
# Encoding: this file MUST stay UTF-8 with BOM (contains Japanese hints; PS 5.1).
#
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('Dump', 'Retreat', 'Verify')]
    [string]$Mode,

    [string]$LegacyRoot = '',
    [string]$NewRoot = '',
    [string]$OutDir = '',
    [string]$LegacyHelper = '',
    [string]$ExpectedLegacyHash = '',
    [int]$Max = 200,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$script:CAP_FILE_HARD = 16384
$script:CAP_ARCHIVE   = 65536
$script:Utf8NoBom     = New-Object System.Text.UTF8Encoding($false)
$script:PsExe         = (Get-Process -Id $PID).Path

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

$script:MIG_HINTS = @{
    'MIG_USAGE'               = 'パラメータが不足しています。Dump: -LegacyRoot -OutDir [-LegacyHelper] [-DryRun] / Retreat: -LegacyRoot -NewRoot / Verify: -NewRoot -OutDir。'
    'MIG_LEGACY_MISSING'      = 'legacy 記憶ルートが見つかりません。存在する v0.6 memory ルートを -LegacyRoot で指定してください。'
    'MIG_NEWROOT_MISSING'     = '新しいルートが見つかりません。-Mode Bootstrap で初期化してから実行してください。'
    'MIG_HELPER_MISSING'      = 'legacy helper (memory-helper.ps1) が見つかりません。-LegacyHelper で指定してください。'
    'MIG_LIST_FAILED'         = 'legacy 記憶一覧の読取に失敗しました。-LegacyRoot / -LegacyHelper を確認してください。'
    'MIG_GET_FAILED'          = 'legacy レコードの読取に失敗しました（id 参照）。再実行してください。'
    'MIG_DEST_EXISTS'         = '新しいルートの archive-legacy が既に存在します。上書きしません（非破壊）。先に内容を確認してください。'
    'MIG_LEGACY_CHANGED'      = '移行中に legacy ツリーが変わりました。legacy ツリーの安定を確認して再実行してください。'
    'MIG_DUMP_MANIFEST_MISSING' = 'dump-manifest.json が見つかりません。先に Dump を実行してください。'
    'MIG_PHANTOM_MARKER'      = '新しいルートに dump になし [legacy:mem_XXXX] マーカーがあります。対応するレコードを確認してください。'
    'MIG_COUNT_MISMATCH'      = 'dump manifest と照合結果の件数に不一致があります。'
    'TRACKED_MISSING'         = '新しいルートに必要なファイルがありません。'
    'SIZE_HARD_EXCEEDED'      = '新しいルートのファイルがサイズ上限を超過しています。'
    'ENCODING_BOM'            = 'ファイルに BOM があります。UTF-8（BOM なし）で再保存してください。'
    'ENCODING_INVALID_UTF8'   = 'ファイルに無効な UTF-8 バイトがあります。'
}

function Quote-Arg {
    param([string]$V)
    if ($V -match '[\s"]') { return ('"' + ($V -replace '"', '\\"') + '"') }
    return $V
}

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { $dig = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($dig) -replace '-', '').ToLower()
}

function Get-Sha256OfText {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $dig = $sha.ComputeHash($script:Utf8NoBom.GetBytes($Text)) } finally { $sha.Dispose() }
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
    [System.IO.File]::WriteAllText($Path, $t, $script:Utf8NoBom)
}

function Get-TreeHash {
    param([string]$Root)
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        $parts.Add(('{0}:{1}' -f $rel, (Get-Sha256Hex $f.FullName)))
    }
    return (Get-Sha256OfText ($parts -join "`n"))
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
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { $p.Start() | Out-Null } catch {
        return @{ exit = -1; out = ''; err = $_.Exception.Message; line = ''; json = $null }
    }
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result
    $ls = @($out -split "`n" | Where-Object { $_.Trim() -ne '' })
    $line = ''
    if ($ls.Count -gt 0) { $line = $ls[0] }
    $json = $null
    try { $json = ($line | ConvertFrom-Json) } catch { $json = $null }
    return @{ exit = $p.ExitCode; out = $out; err = $err; line = $line; json = $json }
}

function Get-LegacyActive {
    param([string]$Root)
    $ap = Join-Path $Root 'ACTIVE'
    if (-not (Test-Path -LiteralPath $ap)) { return @{ generation = 0; operation_id = '' } }
    $gen = 0
    $op = ''
    $rd = [System.IO.File]::ReadAllText($ap, $script:Utf8NoBom)
    foreach ($ln in @($rd -split "`n" | Where-Object { $_.Trim() -ne '' })) {
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $ln.Substring(0, $eq)
        $v = $ln.Substring($eq + 1)
        if ($k -eq 'GENERATION' -and $v -match '^[0-9]+$') { $gen = [int]$v }
        elseif ($k -eq 'OPERATION_ID') { $op = $v }
    }
    return @{ generation = $gen; operation_id = $op }
}

function Emit {
    param($Obj, [int]$ExitCode)
    $json = ($Obj | ConvertTo-Json -Compress -Depth 10)
    [Console]::Out.Write($json + "`n")
    [Console]::Out.Flush()
    exit $ExitCode
}

try {
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch { }

try {

    if ($Mode -eq 'Dump') {
        if ([string]::IsNullOrWhiteSpace($LegacyRoot) -or ((-not $DryRun) -and [string]::IsNullOrWhiteSpace($OutDir))) {
            Emit ([ordered]@{ operation = 'dump'; status = 'FAIL'; code = 'MIG_USAGE'; hint_ja = $script:MIG_HINTS['MIG_USAGE'] }) 1
        }
        try { $legFull = [System.IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\') } catch { $legFull = '' }
        if ($legFull -eq '' -or -not (Test-Path -LiteralPath $legFull)) {
            Emit ([ordered]@{ operation = 'dump'; status = 'FAIL'; code = 'MIG_LEGACY_MISSING'; hint_ja = $script:MIG_HINTS['MIG_LEGACY_MISSING'] }) 1
        }
        if ([string]::IsNullOrWhiteSpace($LegacyHelper)) {
            $ws = Split-Path -Parent $legFull
            $LegacyHelper = Join-Path $ws 'tools\memory-tool\memory-helper.ps1'
        }
        if (-not (Test-Path -LiteralPath $LegacyHelper)) {
            Emit ([ordered]@{ operation = 'dump'; status = 'FAIL'; code = 'MIG_HELPER_MISSING'; hint_ja = $script:MIG_HINTS['MIG_HELPER_MISSING'] }) 1
        }
        $act = Get-LegacyActive $legFull
        $r = Invoke-Child $LegacyHelper @('list', '-MemoryRoot', $legFull, '-Max', ("{0}" -f $Max))
        if ($r.exit -ne 0 -or $null -eq $r.json -or $r.json.status -ne 'PASS') {
            Emit ([ordered]@{ operation = 'dump'; status = 'FAIL'; code = 'MIG_LIST_FAILED'; hint_ja = $script:MIG_HINTS['MIG_LIST_FAILED']; detail = $r.line; stderr = $r.err }) 1
        }
        $recs = @($r.json.records)
        $legacyHash = Get-TreeHash $legFull
        if ($DryRun) {
            $brief = @($recs | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; subject = "$($_.subject)"; provenance = "$($_.provenance)"; lifecycle = "$($_.lifecycle)" } })
            Emit ([ordered]@{
                operation = 'dump'; status = 'DRY_RUN'; count = $recs.Count
                generation = $act.generation; operation_id = $act.operation_id
                legacy_tree_hash = $legacyHash; records = $brief
            }) 0
        }
        $outFull = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\')
        New-Item -ItemType Directory -Path (Join-Path $outFull 'records') -Force | Out-Null
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($rec in $recs) {
            $gid = "$($rec.id)"
            $g = Invoke-Child $LegacyHelper @('get', '-RecordId', $gid, '-MemoryRoot', $legFull)
            if ($g.exit -ne 0 -or $null -eq $g.json -or $g.json.status -ne 'PASS' -or $null -eq $g.json.records) {
                $hint = $script:MIG_HINTS['MIG_GET_FAILED'] -replace '\{0\}', $gid
                Emit ([ordered]@{ operation = 'dump'; status = 'FAIL'; code = 'MIG_GET_FAILED'; hint_ja = $hint; record_id = $gid; detail = $g.line; stderr = $g.err }) 1
            }
            $ro = $g.json.records[0]
            $rawLine = $g.line
            $sha = Get-Sha256OfText $rawLine
            $jp = Join-Path $outFull ('records\' + $gid + '.json')
            $mp = Join-Path $outFull ('records\' + $gid + '.md')
            Write-StrictText $jp $rawLine
            $tags = ''
            if ($null -ne $ro.tags) { $tags = (@($ro.tags) -join '; ') }
            $note = "$($ro.note)"
            if ($note -eq 'null') { $note = '' }
            $md = New-Object System.Collections.Generic.List[string]
            $md.Add(('# legacy record: {0}' -f $gid))
            $md.Add('')
            $md.Add('- source: BAM legacy v0.6 dump (read-only export)')
            $md.Add(('- generation: {0}' -f $act.generation))
            $md.Add(('- operation_id: {0}' -f $act.operation_id))
            $md.Add(('- recorded_at: {0}' -f $ro.recorded_at))
            $md.Add(('- subject: {0}' -f $ro.subject))
            $md.Add(('- tags: {0}' -f $tags))
            $md.Add(('- provenance: {0}' -f $ro.provenance))
            $md.Add(('- lifecycle: {0}' -f $ro.lifecycle))
            $md.Add(('- summary: {0}' -f $ro.summary))
            $md.Add(('- sha256_json: {0}' -f $sha))
            $md.Add('')
            $md.Add('## note')
            $md.Add('')
            if ($note -eq '') { $md.Add('(none)') } else { $md.Add($note) }
            Write-StrictText $mp (($md -join "`n") + "`n")
            $entries.Add([pscustomobject]@{
                id = $gid
                path = ('records/' + $gid + '.md')
                sha256 = $sha
                subject = "$($ro.subject)"
                provenance = "$($ro.provenance)"
                lifecycle = "$($ro.lifecycle)"
            })
        }
        $manifest = [ordered]@{
            count = $recs.Count
            generation = $act.generation
            operation_id = $act.operation_id
            dumped_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            legacy_root = $legFull
            legacy_tree_hash = $legacyHash
            # PS 5.1 quirk (verified): `@()` on a List[object] throws ArgumentException;
            # wrap the .ToArray() result instead.
            records = @($entries.ToArray())
        }
        Write-StrictText (Join-Path $outFull 'dump-manifest.json') (($manifest | ConvertTo-Json -Depth 10) + "`n")
        Emit ([ordered]@{
            operation = 'dump'; status = 'DUMPED'; count = $recs.Count; out_dir = $outFull
            generation = $act.generation; operation_id = $act.operation_id
            legacy_tree_hash = $legacyHash
        }) 0
    }

    elseif ($Mode -eq 'Retreat') {
        if ([string]::IsNullOrWhiteSpace($LegacyRoot) -or [string]::IsNullOrWhiteSpace($NewRoot)) {
            Emit ([ordered]@{ operation = 'retreat'; status = 'FAIL'; code = 'MIG_USAGE'; hint_ja = $script:MIG_HINTS['MIG_USAGE'] }) 1
        }
        try { $legFull = [System.IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\') } catch { $legFull = '' }
        try { $newFull = [System.IO.Path]::GetFullPath($NewRoot).TrimEnd('\') } catch { $newFull = '' }
        if ($legFull -eq '' -or -not (Test-Path -LiteralPath $legFull)) {
            Emit ([ordered]@{ operation = 'retreat'; status = 'FAIL'; code = 'MIG_LEGACY_MISSING'; hint_ja = $script:MIG_HINTS['MIG_LEGACY_MISSING'] }) 1
        }
        if ($newFull -eq '') {
            Emit ([ordered]@{ operation = 'retreat'; status = 'FAIL'; code = 'MIG_NEWROOT_MISSING'; hint_ja = $script:MIG_HINTS['MIG_NEWROOT_MISSING'] }) 1
        }
        $dest = Join-Path $newFull 'archive-legacy'
        if (Test-Path -LiteralPath $dest) {
            Emit ([ordered]@{ operation = 'retreat'; status = 'FAIL'; code = 'MIG_DEST_EXISTS'; hint_ja = $script:MIG_HINTS['MIG_DEST_EXISTS']; dest = $dest }) 1
        }
        $preHash = Get-TreeHash $legFull
        Copy-Item -LiteralPath $legFull -Destination $dest -Recurse -Force
        $postHash = Get-TreeHash $legFull
        if ($preHash -ne $postHash) {
            Emit ([ordered]@{ operation = 'retreat'; status = 'FAIL'; code = 'MIG_LEGACY_CHANGED'; hint_ja = $script:MIG_HINTS['MIG_LEGACY_CHANGED']; expected = $preHash; actual = $postHash }) 1
        }
        $fileCount = (Get-ChildItem -LiteralPath $dest -Recurse -File).Count
        Emit ([ordered]@{
            operation = 'retreat'; status = 'RETREATED'; dest = $dest; files = $fileCount
            legacy_tree_hash = $preHash
            archive_tree_hash = (Get-TreeHash $dest)
        }) 0
    }

    elseif ($Mode -eq 'Verify') {
        if ([string]::IsNullOrWhiteSpace($NewRoot) -or [string]::IsNullOrWhiteSpace($OutDir)) {
            Emit ([ordered]@{ operation = 'verify'; status = 'FAIL'; code = 'MIG_USAGE'; hint_ja = $script:MIG_HINTS['MIG_USAGE'] }) 1
        }
        try { $newFull = [System.IO.Path]::GetFullPath($NewRoot).TrimEnd('\') } catch { $newFull = '' }
        try { $outFull = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\') } catch { $outFull = '' }
        if ($newFull -eq '' -or -not (Test-Path -LiteralPath $newFull)) {
            Emit ([ordered]@{ operation = 'verify'; status = 'FAIL'; code = 'MIG_NEWROOT_MISSING'; hint_ja = $script:MIG_HINTS['MIG_NEWROOT_MISSING'] }) 1
        }
        $errs = New-Object System.Collections.ArrayList
        $warns = New-Object System.Collections.ArrayList
        foreach ($rel in $script:TRACKED) {
            $p = Join-Path $newFull ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $p)) {
                [void]$errs.Add(@{ code = 'TRACKED_MISSING'; file = $rel })
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $bad = $false
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                [void]$errs.Add(@{ code = 'ENCODING_BOM'; file = $rel }); $bad = $true
            }
            $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
            $text = ''
            try { $text = $utf8Strict.GetString($bytes) } catch {
                [void]$errs.Add(@{ code = 'ENCODING_INVALID_UTF8'; file = $rel }); $bad = $true
            }
            if (-not $bad) {
                foreach ($b in $bytes) { if ($b -eq 0x0D) { [void]$warns.Add(@{ code = 'ENCODING_CRLF'; file = $rel; hint_ja = 'CRLF 改行です（警告のみ）。LF 推奨。' }); break } }
                $cap = $script:CAP_FILE_HARD
                if ($rel -eq 'references/archive.md') { $cap = $script:CAP_ARCHIVE }
                if ($bytes.Length -gt $cap) { [void]$errs.Add(@{ code = 'SIZE_HARD_EXCEEDED'; file = $rel }) }
            }
        }
        # reconciliation
        $count = 0
        $migratedCount = 0
        $residual = @()
        $manP = Join-Path $outFull 'dump-manifest.json'
        if (-not (Test-Path -LiteralPath $manP)) {
            [void]$errs.Add(@{ code = 'MIG_DUMP_MANIFEST_MISSING'; file = 'dump-manifest.json' })
        }
        else {
            $man = ([System.IO.File]::ReadAllText($manP, $script:Utf8NoBom)) | ConvertFrom-Json
            $ids = @($man.records | ForEach-Object { "$($_.id)" })
            $count = $ids.Count
            $markers = New-Object System.Collections.Generic.List[string]
            foreach ($rel in $script:TRACKED) {
                $p = Join-Path $newFull ($rel -replace '/', '\')
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $t = [System.IO.File]::ReadAllText($p, $script:Utf8NoBom)
                $ms = [regex]::Matches($t, '\[legacy:(mem_[0-9]{4})\]')
                foreach ($mm in $ms) { [void]$markers.Add($mm.Groups[1].Value) }
            }
            $migrated = @($markers | Select-Object -Unique)
            $migratedCount = $migrated.Count
            $phantom = @($migrated | Where-Object { $ids -notcontains $_ })
            if ($phantom.Count -gt 0) {
                [void]$errs.Add(@{ code = 'MIG_PHANTOM_MARKER'; file = ($phantom -join ',') })
            }
            $residual = @($ids | Where-Object { $migrated -notcontains $_ })
            if (($migratedCount + $residual.Count) -ne $count) {
                [void]$errs.Add(@{ code = 'MIG_COUNT_MISMATCH'; file = ('count={0} migrated={1} residual={2}' -f $count, $migratedCount, $residual.Count) })
            }
        }
        # optional legacy tree hash check
        $legacyHash = ''
        if (-not [string]::IsNullOrWhiteSpace($LegacyRoot) -and -not [string]::IsNullOrWhiteSpace($ExpectedLegacyHash)) {
            try { $legFull = [System.IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\') } catch { $legFull = '' }
            if ($legFull -ne '' -and (Test-Path -LiteralPath $legFull)) {
                $legacyHash = Get-TreeHash $legFull
                if ($legacyHash -ne $ExpectedLegacyHash) {
                    [void]$errs.Add(@{ code = 'MIG_LEGACY_CHANGED'; file = ('expected={0} actual={1}' -f $ExpectedLegacyHash, $legacyHash) })
                }
            }
        }
        if ($errs.Count -gt 0) {
            $codes = @()
            foreach ($e in $errs) { $codes += ('{0}:{1}' -f $e.code, $e.file) }
            $first = $errs[0]
            $hint = if ($script:MIG_HINTS.ContainsKey($first.code)) { $script:MIG_HINTS[$first.code] } else { $first.code }
            Emit ([ordered]@{
                operation = 'verify'; status = 'FAIL'; code = $first.code; hint_ja = $hint
                codes = $codes; count = $count; migrated = $migratedCount; residual = @($residual)
            }) 1
        }
        $wjson = @($warns | ForEach-Object { @{ code = $_.code; file = $_.file; hint_ja = $_.hint_ja } })
        Emit ([ordered]@{
            operation = 'verify'; status = 'PASS'; count = $count
            migrated = $migratedCount; residual = @($residual)
            legacy_tree_hash = $legacyHash
            warnings = $wjson
        }) 0
    }
}
catch {
    $msg = $_.Exception.Message
    try {
        Emit ([ordered]@{ operation = $Mode.ToLower(); status = 'FAIL'; code = 'INTERNAL_ERROR'; hint_ja = ('内部エラーです。detail=' + $msg) }) 1
    } catch {
        Write-Host ('INTERNAL_ERROR: ' + $msg)
        exit 1
    }
}

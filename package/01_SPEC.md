# BAM core v0.7 - Specification (01_SPEC, single document)

Authority chain: requirements definition (approved 2026-10-21, normative; retained in the
source environment, not distributed here) > this specification > implementation.
Deliverables: `bam-adapter.ps1` (core) / `migrate-legacy.ps1` (migration) /
`test-bam-adapter.ps1` (suite) / this document.
Assumptions: personal use, single writer, no network, no dependency on host hooks
(replaced by skill/policy discipline).

## 1. CLI contract (bam-adapter.ps1)

Invocation: `powershell -NoProfile -File <adapter> -Mode <M> -Root <memory-root> [-ChatRoot <chat-root>] [-File <rel|abs>] [-N n]`

`-Root` may be omitted; the adapter then defaults to `<current directory>\memory`.
The skill/policy convention is to always pass it explicitly.

| Mode | dedicated parameters | stdout (1 JSON line) | exit |
|---|---|---|---|
| Bootstrap | `-ChatRoot` (optional) | INITIALIZED: JSON line + index.md / PASS: JSON line + HOT_STATE body / NO_HOT_STATE, STALE, UNVERIFIED: JSON line + `pointer` | 0 (fail-open states included) / 1 = invalid root / internal error |
| Status | - | files / total_bytes / hot_state(FRESH\|STALE\|UNVERIFIED\|MISSING) / manifest(OK\|MISSING\|BROKEN\|MISMATCH) / demote_suggested | 0 (missing = MISSING_ROOT) |
| Validate | - | PASS: codes=[] / FAIL: code (primary) + codes[] + warnings[] | 0 / 1 |
| Commit | - | PASS: hot_state_bytes / FAIL: code + hint_ja | 0 / 1 |
| Demote | `-File` (required), `-N` (optional) | DEMOTED: count/src_bytes/archive_bytes / NOT_NEEDED / FAIL: code | 0 / 1 |

Common JSON fields: `operation / status / root? / code? / hint_ja? / codes? / warnings[{code,file?,hint_ja?}]`
(always 1 line. Bootstrap appends the body after it. Also recorded in adapter.log, section 6).
This .ps1 is kept as **UTF-8 with BOM** (PS 5.1 interprets BOM-less as cp932).

## 2. Data model

Under a memory root `<memory-root>`, 9 tracked files (manifest-managed):

```
index.md                  # AI operating contract (section 8; emitted at INITIALIZED)
canonical/policy.md       # work policy (free form)
canonical/profile.md      # user settings / preferences (free form)
canonical/facts.md        # verified facts (append-only, dated)
state/current.md          # current goal / state / next action / unresolved
decisions/decisions.md    # significant decisions + rationale (append-only, dated)
candidates/pending.md     # unverified candidates (promotion forbidden)
references/archive.md     # demotion target (cold tier)
runtime/HOT_STATE.md      # adapter-managed (AI direct editing forbidden)
```
Plus `manifest.toml` and `runtime/adapter.log` (adapter-managed, untracked).

- All published files are **UTF-8 (no BOM) / LF** (BOM / invalid UTF-8 = error, CRLF = warning).
- Append-only entries (facts / decisions): `- YYYY-MM-DD: <content> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED]`
  (label mandatory, append-only. A change = a correction entry with a new date).
- Migration marker (migrate Verify): regex `\[legacy:(mem_\d{4})\]`.
  Never store: secrets / full transcripts (FR-18), **GO / approval / execution authority (FR-17)**.
- Limits: per file 16384 B hard / HOT_STATE target 4096 B (exceed = warning), hard 16384 B /
  archive 65536 B / demotion threshold 12288 B (80%) / Bootstrap concatenated output budget
  6144 B (exceed = warning only).

## 3. File formats

**HOT_STATE.md header** (adapter-generated; AI editing forbidden):

```
# HOT_STATE integrity header (managed by bam-adapter; do not edit)
FORMAT_VERSION: 1
AUTHORITY: DERIVED_NON_CANONICAL
GENERATED_AT: <ISO8601>
SOURCE_CURRENT: state/current.md
SOURCE_CURRENT_SHA256: <sha256 of state/current.md, lowercase hex>
VALIDATED_AT: <ISO8601>
VALIDATION_STATUS: PASS
---
<body: AI-written summary (generated from the header-less candidate)>
```

**manifest.toml**:

```
# bam-manifest v1 (machine-managed; do not edit manually)
[bundle]
format_version = 1
scope = "project" | "chat"
created_at = "<ISO8601>"
updated_at = "<ISO8601>"

[integrity]
"<tracked relative path, / separated>" = "<sha256 lowercase 64 hex>"
```

**candidate** (`runtime/HOT_STATE.candidate.md`, AI-written, no header required):
BOM = stripped with warning / lines before the leading `## ` = stripped with warning (PREAMBLE) /
existing `# HOT_STATE` header = stripped with warning.

**Rollback files**: `runtime/HOT_STATE.md.rollback.md` / `manifest.toml.rollback` /
`references/archive.md.rollback.md` / `<demoted target>.rollback.md`.

## 4. Mode algorithms

- **Bootstrap**: root missing -> template initialization (9 files + HOT_STATE + manifest,
  scope=project) -> INITIALIZED. An explicit `-ChatRoot` pointing at a missing chat root
  initializes it (scope=chat) **independently of project creation** (an existing project
  or chat root is kept); the PASS output carries `chat_root_created`, and when true a
  CHAT_ROOT_CREATED warning is added. FRESH -> emit body (if chat is FRESH, concatenate
  with a `<!-- BAM scope: chat -->` line). STALE / UNVERIFIED / NO_HOT_STATE -> emit
  pointer, **do not block (fail-open, exit 0)**.
- **Status**: tracked file count + total bytes + hot_state state + manifest state +
  demotion candidates (`"<rel> at <pct>%"`).
- **Validate**: (1) presence of all tracked files (TRACKED_MISSING); (2) strict text
  (BOM / invalid UTF-8 = error, CRLF = warning); (3) limits (SIZE_HARD_EXCEEDED;
  checked independently of the CRLF warning);
  (4) HOT_STATE: header (HEADER_MISSING/INVALID), source hash (STALE_SOURCE_HASH),
  source missing (SOURCE_MISSING), body > target = warning; (5) manifest
  (missing / corrupt / drift / mismatch). **Primary code on FAIL: SOURCE_MISSING takes
  priority when present** (FR-12).
- **Commit**: read candidate (BOM strip -> UTF-8 validation -> LF normalization) ->
  strip header/preamble (warning) -> empty = FAIL -> source hash -> `Build-Header + body`
  composition -> hard limit -> **atomic publish** (tmp write -> existing: `File.Replace(tmp,
  hot, rollback)` / new: Move) -> post-publish revalidation -> manifest update -> candidate
  deletion. **All failure paths: restore from rollback + individual code + exit 1**.
- **Demote**: targets are `canonical/facts.md` / `decisions/decisions.md` only. Path safety
  (section 6) -> extract dated entries -> `-N` omitted = **auto-N**: the minimum number of
  entries that brings the file below the threshold (the inserted pointer line is accounted
  for in advance) -> archive capacity check (exceed = DEMOTE_ARCHIVE_FULL) -> **two-file
  atomic write** (archive first, source after; both with rollback) -> manifest recompute ->
  DEMOTED.
- **Pointer line** (auto-inserted at the end of the file at demotion):
  `<!-- demote-pointer: oldest entries moved to references/archive.md (<ISO8601>) -->`
- **Crash safety (NFR-04)**: every write to a published file and to manifest.toml is
  tmp + replace + rollback (a crash never corrupts a published file). A read-only
  manifest is respected (the write fails instead of bypassing the lock).

## 5. Error / warning code table

sev: E = FAIL (exit 1) / W = warning (continue) / I = internal.
`hint_ja` = the FR-12 (weak-LLM self-recovery loop) implementation: the next move can be
taken from code + hint_ja alone.

| code | sev | meaning (hint summary) |
|---|---|---|
| ROOT_MISSING | E | root missing -> initialize with Bootstrap |
| INVALID_ROOT | E | invalid path -> pass -Root as an absolute or relative path |
| BOOTSTRAP_NO_HOT_STATE | W | HOT_STATE missing -> direct read + candidate + Commit |
| STALE_SOURCE_HASH | E | source changed after generation -> update with Commit |
| HEADER_MISSING / HEADER_INVALID | E | header missing/corrupt -> regenerate with Commit |
| ENCODING_BOM / ENCODING_INVALID_UTF8 | E | re-save as UTF-8 (no BOM) |
| ENCODING_CRLF | W | save with LF (adapter writes are always LF) |
| SIZE_HARD_EXCEEDED | E | over 16384 B (archive 65536 B) -> shorten or Demote |
| SIZE_TARGET_EXCEEDED | W | HOT_STATE > 4096 B -> shorten the summary |
| SOURCE_MISSING | E | state/current.md missing -> recreate + Commit (primary-code priority) |
| MANIFEST_MISSING / MANIFEST_PARSE | E | manifest missing/corrupt -> reinitialize or restore from archive-legacy |
| INTEGRITY_MISMATCH | E | content vs manifest hash mismatch (suspected manual edit) -> confirm + Commit |
| MANIFEST_DRIFT | E | manifest listing vs actual mismatch -> same as above |
| TRACKED_MISSING | E | required file missing -> reinitialize or revert |
| READ_FAILED | E | read failed -> check access rights |
| COMMIT_NO_CANDIDATE | E | candidate missing -> write the summary + rerun |
| COMMIT_CANDIDATE_INVALID_UTF8 | E | candidate has invalid UTF-8 -> re-save |
| COMMIT_CANDIDATE_EMPTY | E | candidate empty -> write the summary + rerun |
| COMMIT_CANDIDATE_PREAMBLE_STRIPPED / HAS_HEADER / BOM_STRIPPED | W | report of automatic stripping |
| COMMIT_SIZE_HARD_EXCEEDED | E | composed result > 16384 B -> shorten the summary |
| COMMIT_SOURCE_MISSING | E | source missing -> recreate + rerun |
| COMMIT_REPLACE_FAILED | E | publish failed -> restored before publish; check access |
| COMMIT_POSTVALIDATE_FAILED | E | post-publish validation failed -> restored via rollback |
| COMMIT_MANIFEST_WRITE_FAILED | E | manifest write failed -> restored via rollback |
| COMMIT_CANDIDATE_DELETE_FAILED | W | candidate deletion failed (content already published) |
| DEMOTE_BAD_FILE | E | target is facts / decisions only |
| DEMOTE_PATH_ESCAPE / DEMOTE_PATH_OUTSIDE | E | path outside the root -> specify as a root-relative path |
| DEMOTE_NO_DATED_ENTRIES | E | no dated entries |
| DEMOTE_NOT_NEEDED | I(0) | below threshold -> demotion not needed (exit 0) |
| DEMOTE_INSUFFICIENT | E | still below threshold even after moving everything -> manual cleanup |
| DEMOTE_BAD_N | E | -N exceeds the entry count |
| DEMOTE_ARCHIVE_FULL | E | archive reached 65536 B -> manual cleanup |
| DEMOTE_WRITE_FAILED | E | write failed -> all files restored |
| INTERNAL_ERROR | I | internal error (with detail) -> check adapter.log |
| CHAT_ROOT_CREATED | W | chat root just initialized by an explicit -ChatRoot |
| CHAT_ROOT_MISSING / CHAT_ROOT_NOT_FRESH | W | chat root missing / not FRESH -> concatenation omitted |
| SIZE_CHAT_OVERBUDGET | W | concatenation > ~6 KB (warning only; nothing omitted) |

## 6. Path safety, logging, operation

- **Root containment (NFR-07)**: relative paths resolve under the root; absolute paths
  escaping the root are rejected (DEMOTE_PATH_*). No network. Single-writer assumption
  (no exclusion of parallel writes; documented).
- **adapter.log**: one JSON line appended per operation; rotated to `adapter.log.1` past
  32 KB. **Log failure is fail-open**.
- Placement: global tool directory (installer default `%LOCALAPPDATA%\bam\`; overridable
  with the installer's `-ToolDir`). The memory root is always passed explicitly with
  `-Root`; if omitted, the adapter falls back to `<current directory>\memory`.
  Convention (skill/policy): project root = `<workspace>\memory`, chat root =
  `<scratchpad>\memory`.
- Change path: design document rev + user GO + one entry in the section 11 changelog
  (NFR-08).

## 7. migrate-legacy.ps1 (legacy v0.6 -> v0.7)

Invocation: `-Mode DryRun|Dump|Verify|Retreat`. The legacy tree is **always read-only**
(tests verify that the tree hash is unchanged).
- Helper contract: `tools\memory-tool\memory-helper.ps1` under the parent of the legacy
  root (`list -MemoryRoot <r> -Max N` / `get -RecordId <id> -MemoryRoot <r>` -> 1 stdout
  JSON line (status=PASS, records[]) / exit 0).
- **DryRun**: count and summary only (no writes).
- **Dump**: each record -> `OutDir\records\<id>.json` (raw helper line + sha256) +
  `<id>.md` (rendered) + `dump-manifest.json` (count / generation / operation_id /
  dumped_at / legacy_root / legacy_tree_hash / records[]).
- **Verify**: collect `\[legacy:(mem_\d{4})\]` markers from all tracked files of the new
  root and reconcile against dump-manifest: total = migrated + residual (`residual` =
  array of not-migrated ids). Legacy hash unchanged.
- **Retreat**: copy the legacy tree to `<new root>\archive-legacy\` (original untouched).

## 8. AI contract (index.md summary; source of truth is index.md)

- **Bootstrap discipline (FR-19)**: exactly one Bootstrap at session start / after
  compaction / on handoff receipt.
- **Read order**: (1) Bootstrap -> (2) HOT_STATE -> (3) state/current.md -> (4) only the
  canonical / decisions files you need. **Hash computation / manifest editing / direct
  HOT_STATE editing are forbidden (adapter only)**.
- **Write-target mapping (FR-09, exclusion of guessing)**: verified facts -> facts /
  preferences & settings -> profile / work policy -> policy / current state -> current /
  significant decisions -> decisions / unverified candidates -> candidates.
- **Write discipline**: no semantic change = no write (the primary rule against bloat).
  After a memory change: write a short summary to the header-less candidate -> Commit.
  **Stored memory is not execution authorization.**
- **Demotion**: when `DEMOTE_SUGGESTED` appears, run `Demote -File <file>` exactly once
  (no count decisions, no file surgery).
- **Natural commands**: "auxiliary memory, boot" = Bootstrap / "reflect to auxiliary
  memory" = mapped write + candidate + Commit / "enable per-chat auxiliary memory" =
  Bootstrap -ChatRoot.

## 9. Test suite -> FR/AC mapping (33 cases)

| group (case count) | what is verified |
|---|---|
| format (5) | initial Bootstrap / header missing / invalid UTF-8 / limit exceeded / SOURCE_MISSING priority -> FR-01..04,12 / NFR-04 |
| staleness (4) | STALE detection / manifest missing / integrity mismatch / commit recovery -> FR-03 / NFR-04 |
| commit (4) | success (preamble strip) / invalid UTF-8 / publish failure (lock) + manifest write failure (rollback) / source missing -> FR-05,06 / NFR-04 |
| path (3) | `..` escape / absolute path outside root / relative path inside root -> NFR-07 |
| size (3) | BOM / archive cap / target exceeded (warning only) -> FR-15 / NFR-01 |
| fail-open (3) | round-trip / STALE non-blocking / NO_HOT_STATE non-blocking -> FR-02 / NFR-02 |
| migration (3) | DryRun / Dump+Verify (2 = 1+1) + legacy hash unchanged / Retreat -> FR-11 |
| demote (3) | auto demotion (order, pointer, Validate recovery) / auto-N / archive cap -> FR-06,07 / NFR-04 |
| review (5) | chat root initialized independently of project creation (idempotent rerun) / CRLF warning does not bypass the hard cap / atomic manifest publish (no tmp residue, consistent after commit) / blocked manifest publish does not restore the stale rollback (read-lock; manifest + HOT_STATE keep pre-commit hashes) / Status names missing required tracked files (manifest=TRACKED_MISSING + manifest_missing) -> section 2 scope model / NFR-04 |

Suite: all PASS + exit 0. NFR-03: single invocation < 5000 ms (PS 5.1 cold start included;
measured max ~1.2 s).

## 10. Acceptance evidence (AC, machine-verified)

| AC | evidence |
|---|---|
| AC-01 | suite 33/33 PASS (transcript record) |
| AC-02 | L1 (source chat) + L2 (muse 30B subagent, isolated) workflow PASS + round-trip match + no STALE |
| AC-03 | Bootstrap + Commit on a cloud-synced memory root (sync-client file locking) succeeds (resolves the v0.6 BLOCK) |
| AC-04 | GO-2: mechanical tally of the real 40-record migration + legacy hash unchanged + no GO-text contamination |
| AC-05 / 06 | fail-open (BOOT-02/03 + L1/L2 real workflow) / limit-exceed rejection (SIZE-* + hint) |
| AC-07 | 0 grep hits for user-specific absolute paths in the 4 core artifacts (generic references only, e.g. `%USERPROFILE%`) |
| AC-08 | measured size budget report (**judgment required**: measured 52.8/31.9 KB vs budget 30/25 KB. Floor with all FRs kept ~43 KB (FR-09 template + FR-12 hints are non-removable). Requires a budget revision or designation of reduction targets) |

## 11. Changelog

- **v0.7 (2026-10-21)**: complete rebuild (v0.6 deprecated; migration via migrate-legacy.ps1
  in GO-2). Adapted the Codex reference implementation to Bionic (no host hooks, weak-LLM
  use). Handling of proven PS 5.1 constraints (see site comments): parenthesized if
  expressions in argument position are forbidden / `@()` into List[object] requires
  `.ToArray()` / command-form `Join-Path` concatenation requires parentheses / UTF-8 BOM is
  mandatory in .ps1.
- **v0.7-portable (2026-10-22)**: portable distribution build. The index.md template is
  English; the adapter path it prints is injected at runtime from the adapter's own
  location ($PSScriptRoot). No machine-specific paths appear in the distributed source.
  migrate-legacy.ps1 is bundled in the package (required by the suite MIG cases) but is
  intentionally not installed into the tool dir (one-shot tool; see PROCEDURE.md).
- **v0.7-portable rev2 (2026-10-22)**: pre-publication review fixes. (1) status-report
  now reports FAIL / exit 1 when placement or memory health is incomplete (missing
  skill / receipt / memory root, adapter status error, manifest not OK); HOT_STATE not
  FRESH is a non-fatal warning. (2) Shared tool dir handling: byte-identical tools are
  reused (tool_dir_state=MATCHING), conflicts stop the install (exit 2,
  TOOL_DIR_CONFLICT); check-target now takes -Zip / -ExpectedSha256. (3) An explicit
  -ChatRoot initializes the chat root independently of project creation
  (chat_root_created + CHAT_ROOT_CREATED). (4) CRLF (warning) no longer bypasses the
  hard-cap check. (5) manifest.toml is published atomically (tmp + replace + rollback;
  read-only manifest respected). Suite extended to 31 cases (REVIEW group).
- **v0.7-portable rev3 (2026-10-22)**: final pre-publication review fixes. (1) A blocked
  manifest publish (e.g. an open read handle without DELETE share) no longer restores the
  rollback file left by an earlier successful operation; the manifest and HOT_STATE keep
  their pre-commit hashes and Validate stays PASS (T-MANIFEST-LOCK). (2) Status now
  reports a missing required tracked file as manifest=TRACKED_MISSING with the file list
  in manifest_missing, so status-report FAILs on partial memory loss
  (T-STATUS-MISSING-TRACKED). Suite extended from 31 to 33 cases (REVIEW group).

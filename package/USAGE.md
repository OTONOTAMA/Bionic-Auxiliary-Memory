# USAGE - BAM v0.7 daily operation

## 30-second overview

BAM = selected file-based memory under a memory root, operated through one tool
(bam-adapter.ps1) with five modes. The installed skill (skill/bam-memory/SKILL.md)
drives the AI; the user only needs the three natural commands (Japanese, kept by
design):

    "補助記憶ブートして"            = bootstrap once
    "補助記憶に反映して"            = write the mapped memory files + commit
    "チャット単位の補助記憶を有効に" = enable per-chat memory (chat root)

## Scope model

- The tool is GLOBAL: installed once in the tool dir (default `%LOCALAPPDATA%\bam`,
  `-ToolDir` override) and usable from any workspace or chat.
- Memory is PROJECT by default: `<workspace>\memory`, shared by all chats of that
  workspace.
- Per-chat memory (optional, explicit): `<scratchpad>\memory`, activated with
  `-ChatRoot`; Bootstrap output then concatenates the chat HOT_STATE after the project
  one when the chat root exists and is FRESH.
- Chat selection is NOT stored by the tool: pass `-ChatRoot` on every Bootstrap. An
  explicit `-ChatRoot` pointing at a missing chat root initializes it (independent of
  project creation). Commit / Validate for the chat memory are run with
  `-Root <chat root>`, e.g. `... bam-adapter.ps1 -Mode Commit -Root <scratchpad>\memory`.

## Invocation (always pass -Root explicitly)

    powershell -NoProfile -File <tool dir>\bam-adapter.ps1 -Mode <M> -Root <workspace>\memory
      [-ChatRoot <scratchpad>\memory] [-File <rel|abs>] [-N n]

The exact adapter path is recorded in
`<ws>\.agents\skills\bam-memory\INSTALL_RECEIPT.json`.

## Modes

| Mode | What it does | exit |
|---|---|---|
| Bootstrap | session start / after compaction / on handoff receipt: exactly 1x. Prints 1 JSON line; then the HOT_STATE body (FRESH) or a pointer (STALE / UNVERIFIED / NO_HOT_STATE); initializes an empty root (INITIALIZED). Never blocks a session (fail-open). | 0 (fail-open states included) / 1 = invalid root / internal error |
| Status | 1-line summary: files / total_bytes / hot_state / manifest / demote_suggested | 0 (missing root = MISSING_ROOT) |
| Validate | full check: tracked files, encodings, size limits, HOT_STATE header, manifest | 0 = PASS / 1 = FAIL |
| Commit | atomically publish `runtime/HOT_STATE.candidate.md` -> `runtime/HOT_STATE.md` (AI writes the candidate summary; the tool builds the header, validates, publishes, revalidates, updates the manifest) | 0 = PASS / 1 = FAIL |
| Demote | move the oldest dated entries of `canonical/facts.md` or `decisions/decisions.md` into `references/archive.md` (auto-N: just enough to get under the threshold; pointer line auto-inserted) | 0 / 1 |

stdout is always exactly 1 JSON line:
`operation / status / root? / code? / hint_ja? / codes? / warnings[]`.
On FAIL, `code` + `hint_ja` alone tell the AI the next move - follow the hint, do not
guess.

## AI workflow (what the skill enforces)

1. Bootstrap discipline: exactly one Bootstrap at session start / after compaction / on
   handoff receipt. PASS -> use the emitted HOT_STATE body. NO_HOT_STATE / STALE /
   UNVERIFIED -> follow the pointer (direct file reads). Adapter missing or erroring ->
   continue anyway (fail-open); report UNVERIFIED.
2. Read order: Bootstrap -> HOT_STATE -> state/current.md -> only the canonical /
   decisions files you need. references/archive.md only when the user asks for old
   details.
3. Write mapping (no guessing): verified facts -> canonical/facts.md / preferences ->
   canonical/profile.md / work policy -> canonical/policy.md / current state ->
   state/current.md / significant decisions -> decisions/decisions.md / unverified
   candidates -> candidates/pending.md.
4. Write discipline: no semantic change = no write. After changing memory files: write a
   short summary into `runtime/HOT_STATE.candidate.md` (no header) -> `-Mode Commit` ->
   report the result (PASS: hot_state_bytes / FAIL: code + hint_ja -> follow the hint).
5. Append-only files (facts / decisions): 1 entry = 1 line
   `- YYYY-MM-DD: <content> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED]`. A change = a new
   dated correction entry; never rewrite old entries.
6. Demotion: when output contains `DEMOTE_SUGGESTED <file> at NN%`, run
   `-Mode Demote -File <file>` exactly once (no count decisions, no file surgery).
   Re-promotion = write back with a new date (no special mechanism).
7. Forbidden: hash computation, manifest.toml editing, direct editing of
   runtime/HOT_STATE.md or its header (adapter only).
8. Never store: secrets, full transcripts, GO / approval / execution authority. Stored
   memory is not execution authorization.

## Size budgets (machine-enforced)

| item | limit |
|---|---|
| per published file | 16384 B hard (exceed = FAIL) |
| HOT_STATE body | 4096 B target (exceed = warning), 16384 B hard |
| references/archive.md | 65536 B hard (exceed = DEMOTE_ARCHIVE_FULL) |
| demotion threshold | 12288 B (80% of the per-file hard limit) |
| Bootstrap concatenated output (project + chat) | 6144 B (exceed = warning only) |

## File format rules

- All memory files: UTF-8 without BOM, LF line endings (BOM / invalid UTF-8 = FAIL,
  CRLF = warning).
- Memory files are written by the AI and the adapter only; never hand-edit
  runtime/HOT_STATE.md or its header.

## Failure rules

- Adapter missing / error -> continue the session (fail-open). Read = bounded direct
  read + report UNVERIFIED. Write = BLOCKED (report and wait).
- `runtime/adapter.log`: one JSON line per operation (rotates to adapter.log.1 past
  32 KB).
- FAIL / STOP at install time -> see PROCEDURE.md (report verbatim, wait).
- `status-report` (installer) is a quick health check (placement + memory sanity;
  exit 0 = PASS / 1 = FAIL). It does not replace the adapter's `-Mode Validate`
  (full integrity check).

## Maintenance

- Uninstall is disabled (the installer `uninstall` subcommand deletes nothing; exit 2).
  Manual removal: delete `<ws>\memory` and `<ws>\.agents\skills\bam-memory` of that
  workspace. The tool files in the tool dir are shared by all workspaces: remove them
  only after checking the `tool_dir` value in the receipts of the other installed
  workspaces.
- The memory templates and the recovery hints (hint_ja) intentionally contain Japanese
  (natural-language triggers and hints for the user). The bundled documents
  (README / PROCEDURE / USAGE / 01_SPEC) are in English.
- 33-case suite: run test-bam-adapter.ps1 from a 4-file staging copy (adapter / test /
  migrate / 01_SPEC side by side). From the installed 3-file tool dir, 30/33 is expected
  (the 3 MIG cases need migrate-legacy.ps1, which is bundled in the package but not
  installed).
- migrate-legacy.ps1 (v0.6 -> v0.7): `-Mode Dump|Verify|Retreat` (the `-DryRun` switch
  is used with Dump); the legacy tree is always read-only. One-shot; not needed for
  fresh installs.

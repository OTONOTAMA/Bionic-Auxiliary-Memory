# BAM-P1 Auxiliary Memory (Core) - Portable Package

- Distribution: bamp1-portable / 2026-10-13 (v3)
- Design: v4 (draft_bam_portable_package_design_20261012_v4.md in the source scratchpad; not included in this ZIP)
- Prerequisites: fresh Bionic (standard features only), Windows PowerShell 5.1, no admin rights required

## Overview

Distributes the Bionic auxiliary-memory Core as a single ZIP.
Scope (Core): retain / fast recall / lifecycle (supersede, forget, restore) / status / validate /
write and integrity mechanism + the tool-side FilterDeepOut (a pure file filter, no offload
required, machine-tested).
Out of scope: the deep recall execution path (offload / strong model), live behavior that depends
on the source environment L0-L3 discipline, and real-compaction-dependent cases. Deep recall is
NOT provided in this distribution; on explicit request report it as unavailable (BLOCKED) (no
fabrication, no substitute).

## Provenance and authority

- Frozen sources (source environment): REQ / 01..05 in this ZIP are distribution derivatives of
  the frozen documents. Each document carries a provenance header and a DISTRIBUTION SCOPE
  ADDENDUM that state source, version, change scope, and distribution authority.
- The frozen sources remain unchanged in the source environment (this ZIP contains only
  derivatives).
- 06 / 07 (test and revision history of the source environment) are not included.
- Authority: the frozen sources in the source environment remain the upstream authority. This
  distribution is normative only within a distributed installation (see each document's
  AUTHORITY_STATEMENT).

## Layout

    bamp1-portable/
    |- README.md                 human-facing (this file)
    |- PROCEDURE.md              target-LLM-facing (fixed commands + no-judgment rules)
    |- MANIFEST.sha256           SHA256 of all ZIP files (self excluded, 12 lines)
    |- bamp1.ps1                 install/verify script (single entry, subcommands)
    |- skill/bam-memory/SKILL.md Core-only skill (common to project / global / none)
    |- payload/
       |- tools/memory-tool/     memory-tool.ps1 / test-memory-tool.ps1 (distribution variant, self-location)
       |- draft_bionic_aux_mem/  REQ / 01..05 (distribution variants)

Sidecar (1 file outside the ZIP): `<zip name>.sha256` (whole-ZIP SHA256, 1 line).

## Installation (fixed 5 commands; a human can run them directly without an LLM)

    0. Extract the ZIP to any directory (Explorer or Expand-Archive)
    1. powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 verify-artifact -Zip <zip path> -ExpectedSha256 <sidecar value>
    2. powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 check-target -WorkspaceRoot <ws>
    3. powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 install-mock -WorkspaceRoot <ws>
       -> check the report (mock selftest results) -> [user approval]
    4. powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 install -WorkspaceRoot <ws> -SkillMode project
    5. powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 status-report

rollback:

    UNINSTALL IS DISABLED IN THIS BUILD. Running
    `powershell -NoProfile -ExecutionPolicy Bypass -File .\bamp1.ps1 uninstall -WorkspaceRoot <ws> -SkillMode project`
    deletes NOTHING and stops with a reason (exit 2).
    Manual rollback (only with explicit user judgment, after backing up evidence):
    delete <ws>\memory, <ws>\tools\memory-tool, <ws>\draft_bionic_aux_mem, and
    (project mode) <ws parent>\.agents\skills\bam-memory.

- <ws> = the target Bionic workspace folder (where memory / tools / draft_bionic_aux_mem are
  placed). If a same-named directory already exists, the script STOPS (exit 2); it never
  overwrites, migrates, or mixes.
- Places where approval can occur: the user decision between steps 3 and 4 (the script enforces
  the stop) / the Bionic write approval for the project skill write in step 4 (behavior on the
  target machine unverified) / the skill.install approval if global is chosen.
- No admin rights and no permanent security-setting changes (-ExecutionPolicy Bypass is
  per-invocation).

## Skill placement

- PROJECT (default candidate): the script places <ws parent>\.agents\skills\bam-memory\SKILL.md
  as an ordinary file.
- GLOBAL: the script does NOT place it (Bionic rule: global skills only via skill.install).
  Installing takes 1 AI message + user approval:
  "Install @bam-memory as a global skill. SKILL.md is at <extract dir>\skill\bam-memory\SKILL.md"
- NONE: no skill. Operate with only the (minimal) invocation contract in SKILL.md.
- Memory scope: <ws>\memory is workspace-level and shared by all chats in that workspace
  (project-level sharing). Per-chat memory does not exist in this Core.
- The skill description is an instruction to the model (a soft trigger); it does not guarantee
  session-start body reads or auto-firing. Explicit invocation `@bam-memory` is always
  available. Do not assume the same guarantees as the source environment.

## Minimal live check (after install; 1 fresh chat, 1-message probe)

1. "Remember: BAM-P1-TEST: test-marker-alpha" -> confirm storage (tag bamp1-test, not pinned)
2. "What is the BAM-P1 test marker?" -> expect a HIT with a 4-element citation
3. Ask about something not stored -> expect "no record in auxiliary memory"
4. (if the skill is placed) explicit invocation `@bam-memory` responds

- Judgment is recorded from user observation + a machine manifest diff (pre/post). Never PASS on
  self-evaluation alone.
- Test data is identifiable by tag bamp1-test / summary prefix BAM-P1-TEST:.
  Even after forget, the original text remains in archive and past generations; test-data
  disposal is NOT part of the install procedure (evidence retention + explicit user approval
  only, a separate GO).

## Constraints (this distribution)

- Timeouts: selftest runner 2400000 ms / single memory-tool invocation 60000 ms. A timeout on a
  slow machine is honestly reported as FAIL (no implicit retry).
- Test data (tag bamp1-test / BAM-P1-TEST:) keeps its original text in archive and past
  generations even after forget. Disposal is not part of the install procedure (evidence
  retention + explicit user approval only).
- Skill auto-firing and target-LLM behavior are not guaranteed (explicit invocation @bam-memory
  always available; verified only via the fresh-chat probe).
- On FAIL / STOP the target LLM must not edit, delete, or silently retry the distribution
  documents, hash table, or state (return machine output verbatim to the user and wait = see
  PROCEDURE).
- Save-then-ask within a single message is NOT a cross-session verification.
- A machine verification PASS does not mean user acceptance
  (MACHINE_CHECK_PASS != USER_ACCEPTANCE).

## Vocabulary

- BAM Status success = `PASS` (memory-tool vocabulary)
- runner exit 0 = all machine tests PASS
- A machine verification PASS does not mean user acceptance
  (MACHINE_CHECK_PASS != USER_ACCEPTANCE)
- DEV_STATE `OK` is the vocabulary of a different system (this distribution does not include
  DEV_STATE)

## Verification gate exception

- `bamp1.ps1` has a UTF-8 BOM (G2 contract, retained for PowerShell 5.1 safety).
  All other files are UTF-8 without BOM. This is mechanically checked by the MANIFEST / content
  gates.

## Language note

- All files in this ZIP are English, with one exception: `payload/draft_bionic_aux_mem/02_HUMAN_GUIDANCE.md`
  is two-part (first half English, second half the frozen Japanese original).
  Localizing messages for user display is the job of the target LLM, not of this package.
- In `01_...` and `04_...`, a small number of Japanese lines are kept byte-identical on purpose:
  they are functional test-identity content (exact quoted user prompts / a verbatim task
  contract copy). See the assembly classification table (source environment) for the full list.

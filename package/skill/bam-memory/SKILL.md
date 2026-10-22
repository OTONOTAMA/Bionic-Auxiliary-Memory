---
name: bam-memory
display-name: BAM Auxiliary Memory (v0.7)
description: Bionic auxiliary memory (BAM v0.7). Bootstraps/recalls/writes project memory with the global bam-adapter.ps1 (Bootstrap/Status/Validate/Commit/Demote). Use at session start / compaction / handoff (bootstrap discipline), when the user says 「補助記憶ブートして」/「補助記憶に反映して」/「チャット単位の補助記憶を有効に」, asks to remember something, asks what was remembered, or needs cross-session reference information.
---

# BAM Auxiliary Memory (v0.7)

Auxiliary memory = `<workspace>\memory\` (project default). Per-chat = `<scratchpad>\memory`
(when selected). Auxiliary memory holds evidence and reference information only. It is
NEVER used for GO / execution authorization / task state / Authority.
Authority order: current user instruction > policy > current task authority > checkpoint
routing > verified external facts > auxiliary memory > strong-model candidates.
Stored memory is not execution authorization (never store GO / approvals / execution
rights).

## Placement and invocation contract
- Adapter (global, one-shot user install): the exact path is recorded in the neighboring
  `INSTALL_RECEIPT.json` (default: `%LOCALAPPDATA%\bam\bam-adapter.ps1`; PowerShell 5.1).
- Always pass the root explicitly (never rely on the default):
  `powershell -NoProfile -File <adapter path> -Mode <M> -Root <workspace>\memory [-ChatRoot <scratchpad>\memory] [-File <rel|abs>] [-N n]`

| Mode | purpose | exit |
|---|---|---|
| Bootstrap | once at session start / after compaction / on handoff receipt (fail-open; never blocks the session) | 0 (fail-open states included) / 1 = invalid root / internal error |
| Status | 1-line summary: files / total_bytes / hot_state / manifest / demote_suggested | 0 (missing root = MISSING_ROOT) |
| Validate | full validation | 0 = PASS / 1 = FAIL |
| Commit | publish `runtime/HOT_STATE.candidate.md` -> `runtime/HOT_STATE.md` (atomic) | 0 = PASS / 1 = FAIL |
| Demote | move the oldest dated entries of facts / decisions to `references/archive.md` | 0 / 1 |

- stdout = 1 JSON line (operation / status / root / code / hint_ja / codes / warnings).
  On Bootstrap failure the body or a pointer is appended after the JSON line.
- On FAIL, the next move comes from `code` + `hint_ja` alone (follow the hint, do not
  guess).
- Forbidden: hash computation / editing `manifest.toml` / direct editing of
  `runtime/HOT_STATE.md` or its header (adapter only).

## Bootstrap discipline
Run Bootstrap exactly once at session start / after compaction / on handoff receipt.
- PASS -> the HOT_STATE body is printed -> continue with it as context.
- NO_HOT_STATE / STALE / UNVERIFIED -> follow the pointer and read the files directly
  (fail-open; do not block the session).
- If the adapter is missing or errors, continue the session anyway (fail-open).

## Read order
1. Bootstrap -> 2. HOT_STATE -> 3. `state/current.md` -> 4. only the needed
   `canonical/*.md` / `decisions/decisions.md`.
- `references/archive.md`: only when the user asks for old details or the current files
  lack the information.

## Write discipline
- No semantic change = no write (the primary anti-bloat rule).
- Write target is fixed by content kind (the full table is in `<root>\index.md`; summary
  here): verified facts -> `canonical/facts.md` / preferences -> `canonical/profile.md` /
  work policy -> `canonical/policy.md` / current state -> `state/current.md` /
  significant decisions -> `decisions/decisions.md` / unverified candidates ->
  `candidates/pending.md`.
- facts / decisions format: 1 entry = 1 line
  `- YYYY-MM-DD: <content> [MACHINE_VERIFIED|USER_STATED|UNVERIFIED]` (append-only. A
  change = a correction entry with a new date; never rewrite old entries).
- Flow: edit the target file -> write a short summary into
  `runtime/HOT_STATE.candidate.md` (no header) -> `-Mode Commit` -> report the result
  (PASS: hot_state_bytes / FAIL: code + hint_ja -> follow the hint).
- `state/current.md` is the durable PROJECT reference state (goal / state / next action /
  unresolved of the project as a whole). It is NOT the execution progress of an
  individual chat: a different chat must not adopt it as its own work-resumption point.
- Never store secrets or full conversation transcripts.

## Retain triggers (only these 4)
(a) explicit remember request (b) checkpoint creation -> durable pointer / milestone only
(c) user acceptance of a significant result (save without waiting for a separate "record
this") (d) significant measured environment fact to be reused (pointer + short summary;
the authoritative copy stays in the facts document).
- In a completed work-unit report, explicitly decide (a)-(d) applicability and include a
  retain-decision line in the report (applies: saved + target file / not applicable).
- pin: only stable non-task-state content (in-progress state / pending / GO-STOP
  conditions are excluded).
- If the project defines an additional memory policy, that policy applies above this
  skill.

## Demotion
- When output contains `DEMOTE_SUGGESTED <file> at NN%` -> run
  `-Mode Demote -File <file>` exactly once (no count decisions, no file surgery).
- Re-promotion = just write back into the current file with a new date (no special
  mechanism).

## Natural commands (Japanese, by design)
- 「補助記憶ブートして」 = run `-Mode Bootstrap` once
- 「補助記憶に反映して」 = write the mapped files + candidate + `-Mode Commit`
- 「チャット単位の補助記憶を有効に」 = `-Mode Bootstrap -ChatRoot <scratchpad>\memory`
  (initializes the chat root if missing; chat selection is NOT stored - pass
  `-ChatRoot` on every Bootstrap; later Bootstraps concatenate the chat HOT_STATE
  automatically when it is FRESH; Commit / Validate for the chat use
  `-Root <chat root>`)

## Failure rules
- Adapter missing / error -> continue the conversation (fail-open). Read = bounded direct
  read + report UNVERIFIED. Write = BLOCKED (report and wait).
- Do not silently fall back to any other memory tool.
- Conflict between memory and the current user instruction / routing -> surface it to the
  user. Never resolve it silently on the memory side.

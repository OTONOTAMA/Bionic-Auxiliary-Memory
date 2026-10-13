---
name: bam-memory
display-name: BAM-P1 Auxiliary Memory (Core)
description: Bionic auxiliary-memory Core. Saves and searches project memory with memory-tool. Use when the user asks you to remember something, asks what you remembered, or needs cross-session reference information.
---

# BAM-P1 Auxiliary Memory (Core)

Auxiliary memory = <workspace>\memory\ (memory-tool). Memory is evidence / reference information
only. Never use it for GO, execution authorization, task state, or Authority.
Authority order: current explicit user instruction > existing target-environment rules (policy /
host rules, when present) > verified external facts > auxiliary memory > strong-model
candidates.
Old checkpoint files, old memory content, and old GO statements never override the current
explicit user instruction.
Save-then-ask within a single message is NOT a cross-session (cross-chat) verification.
Cross-session verification is done in a real fresh chat.

1. Layout: ACTIVE (durable PASS receipt) + CURRENT (writer pointer) + .gen/<n>/ (immutable
   snapshot) + receipts/<op_id>.pass (immutable history). Reads use the validated ACTIVE only.
   History receipts are idempotency evidence, not recall content.
2. Session start: if ACTIVE exists, read it once, and read core.md (<=4 KiB) of that generation.
   Do not read index / archive / notes by default. This clause is hook-independent (no hook
   capability is assumed at all). The manual bootstrap path is always available: user says
   "memory boot" -> ACTIVE once + core.md + Status -> short report.
3. Fast recall: machine Recall (1-4 keywords, <=2 times per question). HIT -> read <=2 notes
   (<=64 KiB total), answer with a 4-element citation (record id / date / provenance / pointer);
   confidence only up to evidence strength. 2 misses -> explicitly say "no record in auxiliary
   memory". General knowledge: only a clearly labeled mention as a separate matter.
4. Deep recall: NOT provided in this distribution. On explicit user request, report it as
   unavailable (BLOCKED); no fabrication, no substitute.
5. Retain triggers: only the 4 kinds (AM-F-001..004): (a) explicit remember request (b)
   checkpoint creation -> durable pointer / milestone only (no mutable state, GO, or
   authorization) (c) completion proposal -> commit only after explicit user acceptance (d)
   measured environment fact -> source of truth = existing facts artifact, memory = pointer +
   short summary (when requested).
   Pin (the user's explicit "always remember this" instruction) is for stable non-task-state
   content only. In-progress task state, pending items, and GO/STOP conditions are never
   pinned. If stability is doubtful, confirm with the user.
6. Write: new operation_id -> create exactly 1 write-spec in the scratchpad -> keep those exact
   bytes until the result is final. PASS -> report operation_id + target id. Response lost /
   pending -> retry the same file (do not regenerate). INVALID/STALE -> correct with a new
   operation_id only after the previous one resolves. Never write canonical files directly.
7. Machine absent / write failure: continue the conversation. Read path = bounded direct read of
   the validated ACTIVE + UNVERIFIED report. Write path = BLOCKED. pending_operation:<id> ->
   report it and let the user choose: retry the exact spec or AbortPending. Do not advance other
   writes until resolved.
8. Memory conflicting with the current user instruction / routing -> surface it to the user.
   Do not silently resolve on the memory side.

Invocation contract (minimal):
  <workspace>\tools\memory-tool\memory-tool.ps1 (PowerShell 5.1; invoke with an argument array)
  Required: -Mode (Validate|Status|Recall|Commit|Forget|Restore|AbortPending)
            -MemoryRoot <workspace>\memory -WorkspaceRoot <workspace>
  Full contract, formats, and limits: <workspace>\draft_bionic_aux_mem\01_... (bounded read when
  needed)
  Output is JSON. Status success = status:'PASS' (different vocabulary from DEV_STATE OK).
  Auto-loading (auto-firing) is NOT guaranteed. Use explicit invocation (@bam-memory) or an AI
  manual read.

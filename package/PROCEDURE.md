# PROCEDURE - for the target LLM (bamp1-portable)

Role split: the target LLM only assists in running the short fixed commands, transcribes machine
output verbatim, and relays user decisions. Editing source or normative documents, creating or
rewriting hash tables, guessing placement targets, integrating with existing configuration on its
own, adjudicating test-FAIL causes or relaxing expectations, silently falling back to GLOBAL, and
declaring "installation succeeded" while anything is unverified are all NOT the target LLM's job
(design v4, section 0 ROLE_BOUNDARY).

## Fixed commands (same as README, in order)

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

## No-judgment rules

- Do not edit distribution documents, the hash table, or the script.
- Do not guess placement targets or the target root (use only the -WorkspaceRoot the user
  gave).
- Do not integrate or resolve conflicts with the existing environment (if STOP appears, report
  it as-is).
- On FAIL / STOP do not edit distribution documents, the hash table, or state files, do not
  delete files, and do not retry on your own judgment. Return machine output and receipt paths
  verbatim to the user and wait for explicit instruction.
- Do not adjudicate test-FAIL causes, relax expectations, or skip cases.
- Do not silently fall back to GLOBAL (only an explicit user choice).
- Do not declare "installation succeeded" while anything is unverified (for the "not machine
  verified" section, transcribe the machine report's wording).
- Do not decompose routine fixed work into piecemeal questions (each command is
  self-contained; 1 step per invocation).

## Presenting results

- Present the machine's console output and receipt paths as-is (verbatim). Do not summarize or
  interpret.
- Do not paraphrase a machine verification PASS as "installation complete"
  (MACHINE_CHECK_PASS != USER_ACCEPTANCE).
- Even if console output looks mojibake'd, judge by the JSON receipt content (receipts are
  UTF-8, no BOM).

## live (minimal post-install check; outside machine verification)

A 1-fresh-chat probe (the 4 steps in README "Minimal live check").
The formal 24 LIVE_BEHAVIORAL cases (AM-T-014..025 / 030..032 / 034..040 / 042 / 043, defined in
04) are the source-environment acceptance suite; on the distribution target, no formal test
other than this probe is executed.

IDs recorded NOT_RUN on the distribution target (reason):

- AM-T-018 / AM-T-019: deep recall (offload / strong model) not provided
- AM-T-017 / AM-T-025: strong-model invocation counting impossible without deep recall
- AM-T-021 / AM-T-032: depend on source-environment L0-L3 / checkpoint discipline (when the
  target environment has no equivalent)
- AM-T-022 / AM-T-023: require isolated operations via renaming/restoring memory-tool (not in
  this procedure)
- AM-T-031: real compaction / handoff dependent
- AM-T-034: acceptance audit (presumes the full test evidence of the source environment; out of
  scope on the distribution target)
- AM-T-043: presumes checkpoint-guard behavior (when the target environment has no
  checkpoint-guard)

IDs doable with user operation: AM-T-030 (recall from a different chat in the same workspace) /
AM-T-035..040 / 042 (in-conversation behavior checks, recorded via user observation + machine
manifest diff).

## Constraints (this distribution)

- uninstall is disabled (running it deletes nothing; prints a reason + exit 2). Deletion is
  manual, user judgment only.
- Timeouts: selftest 2400000 ms / single tool invocation 60000 ms. Timeouts are reported as
  FAIL.
- Test data keeps its original text in archive and past generations even after forget
  (disposal out of scope).
- Skill auto-firing and target-LLM behavior are not guaranteed.
- Save-then-ask within a single message is NOT a cross-session verification.

## STOP conditions

- exit 1 (FAIL) / exit 2 (STOP): present machine output and receipt paths to the user as-is,
  and stop. Do not adjudicate causes or decide on reruns (wait for user instruction).
- Existing data discovered / parallel writes / restore failure: stop and report (take no
  action).

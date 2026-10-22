# PROCEDURE - for the target LLM (bam-portable v0.7)

Role split: the target LLM only runs the short fixed commands below, transcribes the
machine output verbatim, and relays the user's decisions. Editing the distribution
files, creating or rewriting hash tables, guessing placement targets, integrating with
existing configuration on its own, adjudicating test failures or relaxing expectations,
silently retrying FAIL/STOP, and declaring "installation succeeded" while anything is
unverified are all NOT the target LLM's job.

## Fixed commands (in order)

    0. Extract the ZIP to any directory (Explorer or Expand-Archive).
    1. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 verify-artifact -Zip <zip path> -ExpectedSha256 <sidecar value>
    2. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 check-target -Zip <zip path> -ExpectedSha256 <sidecar value> -WorkspaceRoot <ws>
    3. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 install-mock -Zip <zip path> -ExpectedSha256 <sidecar value> -WorkspaceRoot <ws>
       -> check the report (33/33 suite in an isolated staging dir; target untouched) -> [user approval]
    4. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 install -Zip <zip path> -ExpectedSha256 <sidecar value> -WorkspaceRoot <ws>
       (optional: -ToolDir <dir> to place the tool files elsewhere; default %LOCALAPPDATA%\bam)
    5. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 status-report -WorkspaceRoot <ws>
       (quick health check: exit 0 = PASS / 1 = FAIL; the full integrity check is the
        adapter's -Mode Validate)

Each command prints exactly one JSON line to stdout and exits:
0 = PASS / OK, 1 = FAIL, 2 = STOP.

## Placement (fixed)

- Tool files (3): `%LOCALAPPDATA%\bam\` (bam-adapter.ps1, test-bam-adapter.ps1,
  01_SPEC.md) or the directory given with -ToolDir.
- Skill: `<ws>\.agents\skills\bam-memory\SKILL.md` (placed as an ordinary file) plus
  `INSTALL_RECEIPT.json` (machine receipt; exact installed paths and hashes).
- Memory: `<ws>\memory`, created and initialized by the adapter Bootstrap during install.
- migrate-legacy.ps1 is bundled in the ZIP but is NOT installed: it is a one-shot
  v0.6 -> v0.7 migration tool, kept only for the 33-case suite staging and for a
  one-time legacy migration.

## Rollback

    UNINSTALL IS DISABLED IN THIS BUILD. Running
    `powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 uninstall -WorkspaceRoot <ws>`
    deletes NOTHING and stops with a reason (exit 2).
    Manual rollback (only with explicit user judgment, after backing up evidence):
    delete <ws>\memory and <ws>\.agents\skills\bam-memory. The 3 tool files in the tool
    dir (default %LOCALAPPDATA%\bam\bam-adapter.ps1 / test-bam-adapter.ps1 / 01_SPEC.md)
    are shared by all workspaces: delete them only after checking the tool_dir value in
    the receipts of the other installed workspaces.

## No-judgment rules

- Do not edit distribution documents, the hash table (MANIFEST.sha256), or any script.
- Do not guess placement targets or the target root (use only the -WorkspaceRoot the user
  gave; ask if it is not explicitly known).
- Do not integrate or resolve conflicts with the existing environment (if STOP appears,
  report it as-is).
- On FAIL / STOP do not edit distribution documents, the hash table, or state files, do
  not delete files, and do not retry on your own judgment. Return machine output verbatim
  to the user and wait for explicit instruction.
- Do not declare "installation succeeded" while anything is unverified
  (MACHINE_CHECK_PASS != USER_ACCEPTANCE).
- Do not decompose routine fixed work into piecemeal questions (each command is
  self-contained; 1 step per invocation).

## Presenting results

- Present the machine's JSON line as-is (verbatim). Do not summarize or interpret.
- Do not paraphrase a machine verification PASS as "installation complete"
  (MACHINE_CHECK_PASS != USER_ACCEPTANCE).
- If console output looks garbled, judge by the JSON content (stdout is UTF-8).

## Suite note (30/33 vs 33/33)

The 33-case machine suite needs 4 files side by side (bam-adapter.ps1,
test-bam-adapter.ps1, migrate-legacy.ps1, 01_SPEC.md). The installer runs it from an
isolated staging copy created from the ZIP and requires 33/33. If you instead run
test-bam-adapter.ps1 directly from the installed tool dir (3 files), 30/33 is EXPECTED:
the 3 MIG (migration) cases need migrate-legacy.ps1, which is deliberately not
installed. 30/33 from the 3-file tool dir is not a defect.

## Minimal live check (after install; 1 fresh chat, user observation)

1. "補助記憶ブートして" -> expect Bootstrap JSON (status INITIALIZED or PASS) plus the
   HOT_STATE body.
2. "補助記憶に反映して: BAM-TEST marker-alpha" -> expect mapped file write +
   runtime/HOT_STATE.candidate.md + Commit PASS (hot_state_bytes reported).
3. Re-run the step 5 command -> status-report still PASS.

Judgment is recorded from user observation plus the machine JSON output. Never PASS on
self-evaluation alone.

## Weak-model note (honest)

This package is designed to be installed by a capable LLM following the fixed commands
above. A weak local LLM may still fail to follow the procedure correctly; nothing in this
package guarantees weak-model installation or operation. If the target LLM stalls, a
human can run the same fixed commands directly (no LLM required).

## STOP conditions

- exit 1 (FAIL) / exit 2 (STOP): present machine output verbatim and stop. Do not
  adjudicate causes or decide on reruns (wait for user instruction).
- Existing data discovered (check-target / install STOP): stop and report. The installer
  never overwrites or merges.

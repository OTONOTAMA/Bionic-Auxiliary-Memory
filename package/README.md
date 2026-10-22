# BAM v0.7 - Portable Package (bam-portable)

- Version: v0.7-portable (2026-10-22)
- Built for: Bionic on Windows (personal use, single user, no network, no host hooks)
- Prerequisites: Windows PowerShell 5.1, Bionic with shell execution, no admin rights

## What this is

BAM (Bionic Auxiliary Memory) is a small, file-based auxiliary memory for Bionic:
selected records (facts, decisions, current state, preferences, candidates) stored as
UTF-8 markdown under a memory root, with one PowerShell tool (bam-adapter.ps1) providing
five machine-checked operations (Bootstrap / Status / Validate / Commit / Demote) and a
33-case machine suite.

It is designed to support operation by weak local LLMs (support by design, not a
capability guarantee): every failure returns a machine code plus a Japanese hint
(hint_ja) that states the next move, and the tool never blocks a session (Bootstrap is
fail-open). It does NOT save whole conversations, and it never stores GO / approval /
execution authority (by spec).

## Layout (inside the ZIP)

    bam-portable/
    |- README.md                 this file
    |- PROCEDURE.md              target-LLM-facing fixed commands + no-judgment rules
    |- USAGE.md                  daily operation guide (modes, scope, budgets, failure rules)
    |- install-bam.ps1           installer (subcommands; 1 JSON line output; exit 0/1/2)
    |- MANIFEST.sha256           SHA256 of all files in this folder (self excluded, 9 lines)
    |- bam-adapter.ps1           the tool (UTF-8 with BOM - required by PowerShell 5.1)
    |- test-bam-adapter.ps1      33-case machine suite
    |- migrate-legacy.ps1        one-shot v0.6 -> v0.7 migration tool (bundled, not installed)
    |- 01_SPEC.md                specification (single document, English)
    |- skill/bam-memory/SKILL.md skill template (installed as an ordinary file)

Sidecar (outside the ZIP): `<zip name>.zip.sha256` - whole-ZIP SHA256, one line.

## Install via AI (copy this to your Bionic)

> Read README.md, PROCEDURE.md and USAGE.md inside the package. Use the fixed commands
> in PROCEDURE.md to verify the artifact, check the target workspace and run
> install-mock. Do not install until I approve the mock results. Do not overwrite
> existing data, modify tests or hashes, relax thresholds or retry FAIL/STOP without my
> instruction. Report the actual JSON output. I will make the final acceptance decision.
> Ask me for the exact workspace path if it is not explicitly known.

## Manual install (no LLM)

    0. Extract the ZIP anywhere.
    1. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 verify-artifact -Zip <zip> -ExpectedSha256 <sidecar>
    2. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 check-target -Zip <zip> -ExpectedSha256 <sidecar> -WorkspaceRoot <ws>
    3. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 install-mock -Zip <zip> -ExpectedSha256 <sidecar> -WorkspaceRoot <ws>
    4. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 install -Zip <zip> -ExpectedSha256 <sidecar> -WorkspaceRoot <ws>
    5. powershell -NoProfile -ExecutionPolicy Bypass -File .\install-bam.ps1 status-report -WorkspaceRoot <ws>

## Requirements / placement

- Windows PowerShell 5.1 (the installer and the tool are 5.1-compatible).
- Tool files: `%LOCALAPPDATA%\bam\` (default; `-ToolDir` overrides).
- Memory root: `<workspace>\memory` (project scope; per-chat scope via
  `-ChatRoot <scratchpad>\memory`).
- No admin rights; `-ExecutionPolicy Bypass` is per-invocation.

## Verification

- verify-artifact: ZIP hash vs sidecar + MANIFEST.sha256 vs all files.
- install-mock / install: run the 33-case machine suite in isolated staging;
  33/33 + exit 0 required.
- After install: status-report (quick health check: placement + memory sanity;
  exit 0 = PASS / 1 = FAIL). The full integrity check is the adapter's -Mode Validate.
- Repository-level check (publisher side): `python tools/verify_release.py`.

## Important limits

- Personal use, single writer. No network. No host hooks (skill/policy discipline
  instead).
- Existing workspace data stops installation (exit 2); nothing is ever overwritten or
  merged. A shared tool dir whose tool files are byte-identical to this package is
  reused (tool_dir_state=MATCHING); any other pre-existing tool dir stops the install
  (exit 2, TOOL_DIR_CONFLICT).
- Uninstall is disabled. Manual removal only (see PROCEDURE.md).
- Machine check PASS is not user acceptance (MACHINE_CHECK_PASS != USER_ACCEPTANCE).
- Weak local LLMs may fail to install or operate the tool correctly; a human can run the
  fixed commands directly (no LLM required).
- Do not store secrets or full transcripts in memory (spec FR-17 / FR-18).
- A checksum verifies integrity, not publisher authenticity.

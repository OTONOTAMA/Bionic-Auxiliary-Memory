# BAM portable v0.7

Assets: `dist/bam-portable-v0.7.zip` and `dist/bam-portable-v0.7.zip.sha256`.

v0.7 is a complete rebuild of the auxiliary memory (the v0.6 memory-tool line is
deprecated; one-shot migration via the bundled `migrate-legacy.ps1`).

Package contents: `bam-adapter.ps1` (core tool, 5 modes), `test-bam-adapter.ps1`
(33-case machine suite), `migrate-legacy.ps1` (bundled, not installed), `01_SPEC.md`
(single-document specification, English), `install-bam.ps1` (installer, JSON 1-line
output, exit 0/1/2), `PROCEDURE.md` / `README.md` / `USAGE.md`, and
`skill/bam-memory/SKILL.md`.

Placement: tool files in `%LOCALAPPDATA%\bam` (installer `-ToolDir` overrides); memory
in `<workspace>\memory` (project scope; per-chat via `-ChatRoot`); skill as an ordinary
file in `<workspace>\.agents\skills\bam-memory` with `INSTALL_RECEIPT.json`.

Notes:

- The 33-case suite runs from a 4-file staging copy. Running the suite directly from
  the installed 3-file tool dir yields 30/33 (the 3 MIG cases need the bundled,
  not-installed, migrate-legacy.ps1). This is expected, not a defect.
- Uninstall is disabled; manual removal only (see PROCEDURE.md).
- Personal use, single writer, no network, no host hooks. Weak local LLMs may fail to
  install or operate the tool; the fixed commands can be run by a human without an LLM.
- Personal memory, receipts, scratchpads and host configuration are not part of this
  release.
- rev2 (2026-10-22, pre-publication review fixes): status-report now FAILs (exit 1)
  on incomplete placement or unhealthy memory (HOT_STATE not FRESH is a non-fatal
  warning); a shared tool dir with byte-identical tools is reused
  (tool_dir_state=MATCHING) and other conflicts stop the install (exit 2,
  TOOL_DIR_CONFLICT); check-target takes -Zip / -ExpectedSha256; an explicit -ChatRoot
  initializes the chat root independently of project creation; CRLF no longer bypasses
  the hard-cap check; manifest.toml is published atomically (read-only respected).
  Suite extended from 28 to 31 cases (REVIEW group).
- rev3 (2026-10-22, final review fixes): a blocked manifest publish no longer restores
  the stale rollback left by an earlier operation (manifest and HOT_STATE keep their
  pre-commit hashes; Validate stays PASS); Status reports missing required tracked files
  as manifest=TRACKED_MISSING with manifest_missing, so status-report FAILs on partial
  memory loss. Suite extended from 31 to 33 cases (REVIEW group).

## Version and upgrade scope

The release tag is `v0.7`, matching the rebuilt BAM core. The previous portable
v3.4 release and its assets are retained. These are fresh-install instructions;
an existing installation requires a separate verified migration plan. The bundled
migration tool specifically targets the legacy v0.6 record format.

## Independent pre-publication checks

- ZIP SHA256, nine manifest entries and ten exact source/ZIP files verified.
- Installer and all 33 suite cases passed in an isolated Windows workspace.
- Blocked manifest replacement preserved both pre-operation file hashes and a
  subsequent Validate passed.
- A missing required memory file caused status-report to exit 1.
- Model behavior and Bionic Skill auto-selection remain outside these checks.

SHA256: `c99b46f74ed8e1310a36c5d527ca02e107decce6f3d715b6ab1951c4c0d7010e`

## License

Released under the MIT License. See [LICENSE](LICENSE) for the full license text.

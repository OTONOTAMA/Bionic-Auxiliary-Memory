# BIONIC_AUX_MEM
## CANONICAL_NORMATIVE_SPECIFICATION (Basic Design)

<BAM>

<META>
BUNDLE_ID=BIONIC_AUX_MEM
BUNDLE_VERSION=0.5
TARGET_PLATFORM=BIONIC_WINDOWS_LOCAL
BUNDLE_CLASS=DOMAIN_BUNDLE
FRAMEWORK_REFERENCE=ChatGPT_Bundle_Framework_v0.20 (development factory; not a runtime dependency)
SPECIFICATION_CLASS=NORMATIVE
CANONICAL_LANGUAGE=ENGLISH_STRUCTURED
STATUS=DESIGN_REVIEW_DRAFT
IMPLEMENTATION=NOT_STARTED
DATE=2026-10-06
BASIC_DESIGN_OWNER=CHATGPT_CODEX
NEXT_GATE=QWEN_READ_ONLY_IMPLEMENTATION_FEASIBILITY_AUDIT_THEN_USER_SCOPE_FREEZE_DECISION
DIST_VARIANT=[
"SOURCE_FILENAME=01_CANONICAL_NORMATIVE_SPECIFICATION.md"
"SOURCE_SHA256=E8EA13E9743747205421548ECB385CF8E92026A07B30025376CBBAD723DB9A11"
"SOURCE_ENVIRONMENT=path omitted (frozen design on the source PC; this distribution references filename and hash only)"
"DIST_DATE=2026-10-12"
"CHANGE_SCOPE=environment-specific paths removed; DISTRIBUTION SCOPE ADDENDUM appended at end"
"AUTHORITY_STATEMENT=this file is the normative design for the distributed installation; the frozen source document on the source environment remains the upstream reference"
]
REV=0.5 (basic design taken over by ChatGPT/Codex on explicit user direction 2026-10-06. Revision 0.5 preserves the accepted v0.4 corrections and closes the remaining transaction and lifecycle ambiguities: (1) every write has an immutable operation_id and spec hash; ACTIVE is an atomic durable PASS receipt, not a bare generation number; an exact retry recovers PASS without duplicating the write; (2) a switched-but-not-PASSed generation is NEVER adopted or discarded by an unrelated later write - only an exact retry may resume it, and only explicit user-approved AbortPending may discard it; (3) PASS visibility is operationalized as existence of a machine-verifiable durable PASS receipt, with immutable O(1) operation-id receipt history so acknowledgement loss remains recoverable after later commits; (4) evidence existence checks are transition-scoped: required for add and restore activation, not re-run against unchanged carried records; (5) storage growth is reported accurately as full-snapshot cumulative growth, with Status metrics and no claim that a generation is only a few KiB. Scope freeze remains HOLD; implementation remains NOT_STARTED.)
</META>

<AUTHORITY>
CANONICAL_SPECIFICATION=[
"THIS_DOCUMENT"
"THIS_DISTRIBUTION_FILE (distribution variant 2026-10-12 of 01_CANONICAL_NORMATIVE_SPECIFICATION.md)"
]
REQUIREMENTS_AUTHORITY=[
"BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md (document name only; absolute path omitted from distribution)"
"STATUS=APPROVED_SCOPE_FROZEN_2026-10-06"
"SHA256=5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A"
"SHA256_MEASURED=2026-10-06_Get-FileHash_SHA256_actual_command_run_by_basic_design_agent_matches_user_measurement"
"CORRECTION_2026-10-06=The v0.2 value 338051d17f3f899f3641213f35374c15307756f728023b122d459a388641e993 was a false OBSERVED claim (no command had been executed to measure it). It is retracted. The value above is the actual on-disk measurement."
]
HUMAN_GUIDANCE_AUTHORITY=NON_NORMATIVE
CONFLICT_RULE=[
"REQUIREMENTS_DOCUMENT_IS_UPSTREAM_AND_FROZEN"
"THIS_DOCUMENT_REALIZES_REQUIREMENTS_AND_MUST_NOT_INVALIDATE_ANY_SHALL"
"ANY_SHORTCUT_INVALIDATING_A_SHALL_IS_A_REQUIREMENT_CHANGE_PROPOSAL_RETURNING_TO_USER"
"CANONICAL_NORMATIVE_SPECIFICATION_OVERRIDES_HUMAN_GUIDANCE"
"CANONICAL_COPY_OVERRIDES_ANY_MIRROR_COPY"
]
DESIGN_PHASE_BOUNDARY=[
"THIS_PHASE_IS_READ_ONLY_WITH_RESPECT_TO_PRODUCTION_POLICY_MEMORY_CHECKPOINT_AND_TOOL_FILES"
"IMPLEMENTATION_REQUIRES_SEPARATE_EXPLICIT_USER_GO"
"SCOPE_FREEZE_REQUIRES_SEPARATE_EXPLICIT_USER_GO"
"REQUIREMENTS_SHA256_IS_FIXED_IN_THIS_DOCUMENT_AT_REVISION_0.3_BY_ACTUAL_MEASUREMENT"
"THE_SCOPE_FREEZE_RECORD_RECORDED_AT_A_LATER_GATE_MUST_AGREE_WITH_THIS_MEASURED_VALUE"
]
</AUTHORITY>

<PURPOSE>
PRIMARY_OBJECTIVES=[
"REALIZE_FROZEN_REQUIREMENTS_AM_F_AM_N_AM_C_AM_I_OF_BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_V0.3"
"DELIVERABLES_D1_TO_D12_PER_REQUIREMENTS_SECTION_K"
"KEEP_THE_NORMATIVE_CORE_SMALL_AND_THE_MACHINE_DETERMINISTIC"
"KEEP_THE_CHAT_MODEL_A_THIN_CLIENT_WITH_BOUNDED_JUDGMENT_SURFACE"
]
</PURPOSE>

<DESIGN_EVIDENCE>
RE_READ_FROM_DISK_IN_DESIGN_SESSION=2026-10-06
  - policy/bionic-policy.md (full, current 2026-10-06 revision, incl. L0 guard / AUTHORIZATION_UNKNOWN / false-GO firewall / TASK_SCOPE_RULE / protocol routing; MEMORY_RULE absent = to be added at implementation under its own GO)
  - workspace/tools/checkpoint-guard/checkpoint-guard.ps1 (interface: params, modes Validate/Commit, one-line JSON stdout, exit 0/1/2, CAS expected hash+seq, atomic temp+replace, backup/rollback, TestMode-gated fault injection)
  - workspace/tools/checkpoint-guard/test-checkpoint-guard.ps1 (selftest pattern: $env:TEMP fixture root, child-process invocation in exact Bionic command form, case counter, fixture kept on failure)
  - api-context-offload SKILL.md (contract: job spec JSON -> python offload.py; RESULT/OUT/PREVIEW/WARN/GATE stdout; exit 0/2/3/4/1; helper-injected fixed system preamble; no-probe and brand-frame rules; task template = self-contained 5 elements; NO quantity constraints in task text - measured weak-model failure trigger; on exit 4 the gate is a floor, not the sole correctness judge)
  - policy/api-context-offload-facts.md (OBSERVED: server http://localhost:1234; qwen3.8-27b loaded context 150016 / muse 131072; 26k prompt-token inputs processed normally; quantity-constraint failures measured for qwen; gate false-fail case ST-5 measured)
  - ChatGPT_Bundle_Framework_v0.20 (00/01/02/22 conventions: META/AUTHORITY blocks, SOT conflict rule, numbered lifecycle docs, scope-freeze record, test-first)
  - requirements v0.3 SHA256 (OBSERVED: actual Get-FileHash command run 2026-10-06 in this session; matches the user's own measurement)
  - requirements v0.3 normative text re-read 2026-10-06 for revision 0.4: AM-I-005 (revalidate committed state before returning PASS), AM-I-006 (one consistent committed transition), AM-I-007 (candidate until PASS), AM-I-008 (record fields incl. source_pointer), AM-I-010 (source pointer absent only for user-stated self-contained facts), AM-I-011 (note reference active only within the same validated transition), AM-T-042 (candidate not visible until commit returns PASS)
LEARNED_KNOWLEDGE_USED_AS=HYPOTHESIS_ONLY (per requirements section K evidence rules)
</DESIGN_EVIDENCE>

</BAM>

---

# D1. Architecture and responsibility map

## D1.1 Files, layout, and exclusive writers

Memory root: `workspace/memory/` (frozen by AM-C-002). Tool root: `workspace/tools/memory-tool/` (frozen by AM-C-002). The generation layout below is a permitted child-path refinement (AM-C-002).

```
workspace/memory/
  ACTIVE            # machine-managed READER pointer + durable PASS receipt.
                    # Fixed PASS receipt: GENERATION, OPERATION_ID, SPEC_SHA256,
                    # STATE_SHA256, ACTION, AFFECTED_IDS, RESULT=PASS.
                    # EVERY reader resolves and validates THIS receipt.
  CURRENT           # machine-managed WRITER record: GENERATION, OPERATION_ID,
                    # SPEC_SHA256, STATE_SHA256. At steady state it matches ACTIVE's
                    # identity; during a pending write it leads ACTIVE by one.
                    # Readers never use CURRENT as a content root.
  receipts/
    <operation_id>.pass
                    # immutable archived ACTIVE receipt, keyed by operation UUID;
                    # latest receipt remains in ACTIVE until a later PASS archives it
  .gen/
    000012/         # one COMPLETE state snapshot per generation
      core.md       # header + pinned records   (<=30 records, <=4096 UTF-8 bytes excl. header)
      index.md      # header + active records   (<=100 records, <=65536 UTF-8 bytes excl. header)
      archive.md    # header + archived records (unbounded; never read at bootstrap or fast recall)
      notes/
        mem_NNNN.md # one prose note per record that has one (<=32768 UTF-8 bytes each)
      STATE         # machine manifest incl. operation identity (see D2.5)
```

- A generation directory is COMPLETE by construction: it contains every canonical file of the state (core/index/archive, all notes, STATE). Readers never mix files from two generations (D5).
- Retention (revision 0.4, per user review 2026-10-06): the machine performs NO automatic pruning of completed (PASSed) generations in P1. Every completed generation stays on disk until an explicit operator action (D10.4 manual retention management). Rationale and the counterexample that defeated the revision-0.3 mtime guard: D5 proof 4. The revision-0.3 design constant PRUNE_DELAY_SECONDS is REMOVED from P1.
- Remnant cleanup (distinct from pruning): a generation directory that was NEVER referenced by a valid `ACTIVE` PASS receipt is non-canonical and can never have been resolved by a conforming reader. A staged remnant or a switched-but-not-PASSed generation may be removed under the writer lock according to the operation-id recovery rules in D3.5. An unrelated later write can never adopt it. This never touches a PASSed generation (D5 proof 4, invariant R3).
- Rejected alternative (recorded for audit, carried from revision 0.3): copying deep-recall inputs into a scratchpad staging directory before invocation. Rejected: it adds a copy step, a scratchpad lifecycle, and a second input location to reason about, while retaining the completed generation in place is deterministic and in-place.
- Rejected alternative (recorded for audit, revision 0.4): the revision-0.3 mtime-guarded retention (always keep CURRENT + CURRENT-1, keep older completed generations while their directory mtime is inside a 600 s delay, prune older ones under lock). REJECTED by user review 2026-10-06: a directory mtime is the time of the last WRITE to the directory (staging), not of the last READ; the delay therefore expires independently of any active reader. The D5 counterexample (two commits after a long-running reader starts) shows a deep-recall job can lose its input files even with the guard. A reader-lease scheme (mechanically prove "no active reader" before pruning) is recorded as a P2 candidate requiring its own mechanical proof; it is NOT in P1.
- The separate `.backup/` directory of revision 0.1 is REMOVED: the retained generation snapshots ARE the backup (single source of truth; no second copy to keep in sync). Retaining every completed generation (no P1 auto-pruning) makes the retained set a strict superset of the revision-0.3 retention, so every v0.3 rollback target remains available.

Disk-growth tradeoff (documented, accepted for P1): each completed generation stores a FULL snapshot, including the complete archive and every retained note. Archive and note count are not globally bounded; therefore one generation may grow beyond MiB scale and cumulative retained history may grow approximately quadratically with commit count in the worst case. Fixed seven-line receipt files grow only linearly and are retained independently of snapshot retention. P1 bounds neither total bytes nor generation count. `Status` SHALL report measured totals; these are evidence for a later explicit retention decision, never an automatic deletion trigger.

| File | Writer (exclusive) | Readers |
|---|---|---|
| `.gen/<n>/*` (core.md, index.md, archive.md, notes/, STATE) | machine only (`memory-tool.ps1` Commit/Forget/Restore), inside the staged generation | machine (all modes, via ACTIVE resolution); chat AI (bounded direct reads, via ACTIVE resolution, fail-open path only); strong model (deep-recall inputs via offload, ACTIVE-generation files) |
| `ACTIVE`, `CURRENT`, `.lock` | machine only | machine (ACTIVE = reader resolution + durable PASS receipt; CURRENT = writer/pending state; both are reported by Status); none (`.lock` is a transient OS handle target) |
| `receipts/*.pass` | machine only; immutable after creation | machine idempotency/status only; never bootstrap/recall input |
| Commit spec JSON | chat AI (scratchpad, `draft_` prefix) | machine (Commit input only) |
| Deep candidate file (`draft_bam_deep_candidates_*.txt`) | machine only (FilterDeepOut, D7) | chat AI (bounded read, <=3 lines) |

Invariant: the chat AI SHALL NOT write any canonical file or pointer file directly in any state (AM-F-007, AM-I-007). The AI drafts content; the machine formats, validates, and commits.

## D1.2 Actor responsibility boundaries (requirements section D, preserved)

| Actor | Owns | Does not own |
|---|---|---|
| Human | purpose, value choices, retain/forget intent, deep-recall request, execution GO, final acceptance | deterministic validation |
| Chat AI | intent interpretation; candidate spec drafting; keyword extraction; semantic relevance judgment after source inspection; pin stability classification (D3.5 step 9: only stable non-task-state content is pin-eligible); deep-candidate verification; evidence-calibrated reporting | unvalidated canonical writes; unbounded scanning; authority reconstruction; pin bound enforcement |
| Machine | validation; path/encoding checks; bounded lexical retrieval; canonical persistence; writer lock + CAS; operation-id idempotency; generation snapshot, staged verification, CURRENT pending switch, post-switch revalidation, ACTIVE durable-PASS receipt, exact-retry recovery/rollback; integrity evidence; id assignment; FIFO/supersession; deep-OUT local narrowing | semantic truth; value judgment; relevance ranking beyond lexical weights; pin stability judgment; execution authorization |
| Strong model (offload) | explicit deep-recall candidate generation with source pointers and verbatim source quotes | canonical writes; relevance finality; execution authorization; factual adjudication |

Judgment-location matrix (refines v0.2 J1-J9 to the v0.4 contract):

| # | Judgment | Owner | Bound |
|---|---|---|---|
| J1 | keyword extraction from user question | chat AI | 1-4 keywords, <=2 calls/question |
| J2 | which records match lexically | machine (Recall) | deterministic weights, memory_id dedup (D6) |
| J3 | semantic relevance of a returned candidate | chat AI, after reading bounded source | <=2 notes, <=64 KiB per normal answer |
| J4 | deep candidate generation | strong model, explicit user request only | source pointers + verbatim no-pipe quotes mandatory (D7) |
| J5 | answer composition with citation | chat AI | certainty <= evidence |
| J6 | record field drafting (subject/summary/tags/provenance) + note prose + evidence pointer | chat AI | bounded fields; machine validates |
| J7 | format, bounds, ids, supersession, FIFO, snapshot, staged verify, CAS, lock, rollback, reconciliation, deep-OUT narrowing | machine | deterministic |
| J8 | GO/authorization | not this system (L2 firewall) | - |
| J9 | current task identity | checkpoint routing, not memory | - |

## D1.3 Authority ordering (requirements section C boundary invariant)

```
CURRENT_USER_DIRECTION / POLICY / CURRENT_TASK_AUTHORITY
    > CHECKPOINT_ROUTING
    > VERIFIED_EXTERNAL_FACT_SOURCE
    > AUXILIARY_MEMORY
    > STRONG_MODEL_CANDIDATE
```

Existing Bionic L0-L3 rules remain active and unmodified (AM-F-030).

---

# D2. Canonical artifact model and schema (AM-I-008..AM-I-012)

## D2.1 Record line format (core.md and index.md)

One record per line. Ten pipe-delimited fields, fixed order (revision 0.4: field roles flipped per frozen AM-I-010 - `source_pointer` is the EXTERNAL EVIDENCE pointer; the record note moved to the new `note_pointer` field; a note and an external evidence pointer can coexist on one record):

```
memory_id|recorded_at|subject|tags|provenance|source_pointer|note_pointer|lifecycle|supersedes_id|summary
```

| Field | Machine-enforced rule |
|---|---|
| memory_id | `mem_` + 4 decimal digits zero-padded. Regex `^mem_[0-9]{4}$`. Machine-assigned at commit: global max across core+index+archive of the ACTIVE generation + 1. Unique. Never reused (archive retains retired ids). |
| recorded_at | `YYYY-MM-DD`, valid calendar date, not later than commit date. |
| subject | 1-64 UTF-8 characters; no pipe; no newline. |
| tags | 0-4 tags, `;`-separated; each `^[a-z0-9-]{1,32}$`; empty field = no tags. Non-authoritative label (AM-F-019). |
| provenance | one of `USER_STATED`, `MACHINE_VERIFIED`, `AI_INFERRED`, `UNVERIFIED`. |
| source_pointer | the EXTERNAL EVIDENCE pointer (AM-I-010): `-` or a relative path under the workspace root (existing file at commit time; no `..`, no absolute, no drive letter, reparse points/symlinks rejected, AM-N-009). Never written by the machine; read-only external artifact. Absence rule (AM-I-010, machine-enforced): `source_pointer` = `-` is allowed ONLY when `provenance = USER_STATED` (a user-stated self-contained fact). For `provenance` in {`MACHINE_VERIFIED`, `AI_INFERRED`, `UNVERIFIED`}, `source_pointer` MUST be a non-`-` pointer that resolves to an existing file at commit time (AM-I-010 "otherwise it SHALL resolve to existing evidence at commit time"). A `note_pointer` alone does NOT satisfy AM-I-010 for these provenance classes: the note is canonical memory content, not external evidence. |
| note_pointer | `-` or the NOTE pointer `notes/<memory_id>.md` - always the record's OWN note file (machine checks the id match). A NOTE pointer is active only if the note exists in the same committed transition (AM-I-011). The machine writes a note ONLY in the same commit transition that references it. |
| lifecycle | `pinned` (line in core.md) or `active` (line in index.md). |
| supersedes_id | `-` or the memory_id of an active record that is archived (reason=superseded) in the same transition (AM-F-020). Tag equality alone never supersedes. |
| summary | 1-256 UTF-8 characters; no pipe; no newline. |

Pointer consistency (machine rule, realizes AM-I-010 and AM-I-011):

- `source_pointer = -` (no external evidence) is allowed ONLY when `provenance = USER_STATED`, regardless of `note_pointer`.
- `provenance` in {`MACHINE_VERIFIED`, `AI_INFERRED`, `UNVERIFIED`} REQUIRES `source_pointer != -` resolving to an existing file at commit time. `note_pointer` may be `-` or set, independently.
- Both `source_pointer` and `note_pointer` set on the same record is always allowed (e.g., a MACHINE_VERIFIED fact whose external evidence is the original log file AND whose canonical note holds the verification summary).
- Note: AM-I-008 requires the record to expose `memory_id, recorded_at, subject, topic_tags, summary, provenance_status, source_pointer, lifecycle, optional supersedes_id`. This schema exposes all of them, with `source_pointer` carrying the external-evidence meaning required by AM-I-010, plus `note_pointer` for the note; exposing an additional field does not invalidate the SHALL.

Records are immutable after commit. Correction = supersession (new record referencing the old id). No in-place edit exists in P1.

## D2.2 Placement invariants

- A pinned record appears in BOTH core.md (line lifecycle=`pinned`) and index.md (same memory_id, line lifecycle=`active`, all other fields identical) within the same generation. Invariant CORE subseteq INDEX.
- A non-pinned active record appears only in index.md.
- Fast recall and list operate on core.md + index.md of the ACTIVE generation. Archive is invisible to bootstrap and fast recall (AM-N-011).

## D2.3 Archive line format (archive.md)

```
<archived_at>|<reason>|<original record line>
```

- archived_at: `YYYY-MM-DD`.
- reason: `superseded` | `evicted` | `forgotten`.
- original record line: byte-identical to the committed line as it stood at archival (its lifecycle field records the pre-archive placement; 10 fields, D2.1 order). Recoverable (AM-F-023).
- Duplicate archive lines for the same memory_id are LEGITIMATE HISTORY (a record forgotten, restored, forgotten again). Restore semantics for duplicates: D3.7.

## D2.4 Note files

`notes/<memory_id>.md` inside the generation directory: UTF-8 without BOM, <=32768 bytes, prose. Written only as part of a Commit transition that references it via `note_pointer` (AM-I-011). Every note of a generation is hash-listed in its STATE manifest (D2.5).

## D2.5 STATE manifest (machine-only, per generation)

ASCII, UTF-8 without BOM. Fixed 11-line head + one line per note (sorted by memory_id):

```
GENERATION=<n>
OPERATION_ID=<lowercase UUID>
SPEC_SHA256=<hex64>
AFFECTED_IDS=<comma-separated memory_ids or ->
ACTION=<initialize|commit|forget|restore>
CORE_SHA256=<hex64>
CORE_BYTES=<n>
INDEX_SHA256=<hex64>
INDEX_BYTES=<n>
ARCHIVE_SHA256=<hex64>
ARCHIVE_BYTES=<n>
NOTE_SHA256=<memory_id>:<hex64>:<bytes>     (one line per note in this generation, sorted by memory_id)
```

- GENERATION: monotonically increasing; equals the generation directory number; +1 per successful commit. CAS anchor.
- OPERATION_ID + SPEC_SHA256: immutable idempotency identity. Reusing an operation_id with different spec bytes is `INVALID`. An exact retry can recover a durable PASS without repeating the transition (D3.5).
- AFFECTED_IDS and ACTION: bounded durable result data used to reconstruct the original PASS after acknowledgement loss. Commit specs contain at most 16 operations; the field is therefore bounded.
- NOTE_SHA256 lines: NOTE BODIES ARE HASH-VERIFIED. Validate and every commit verify that each listed note exists with exactly the listed hash and byte count, and that no unlisted note file exists in the generation's notes/ directory. A mismatch = the generation is untrusted (UNVERIFIED / STATE_MISMATCH, D3.5, D4).
- A generation whose STATE hashes disagree with its actual files is incomplete/untrusted and must not be referenced by ACTIVE. If CURRENT names it, exact retry fails safely; other writes stop. Cleanup follows the explicit pending-failure/AbortPending rules in D3.5, never unrelated adoption.

## D2.6 Forbidden content (AM-F-028, AM-I-012)

Any record line, note, or archive line containing any of the tokens `GO_STATE`, `AUTHORIZED`, `EXECUTION_AUTHORIZATION`, `VALID_GO`, `APPROVED_TO_EXECUTE` (standalone field/key usage, same list as checkpoint-guard) is rejected by the machine as `INVALID`. Natural-language GO references that survive as historical evidence remain governed by AM-F-028 and the existing L2 firewall (machine enforcement is explicit-representation only; semantic false-GO prevention is L2).

## D2.7 Headers

First line of core.md / index.md / archive.md: `# memory-core v1` / `# memory-index v1` / `# memory-archive v1`. Excluded from record counts and byte bounds (AM-N-001..003).

## D2.8 Pointer model (evidence and note are separate fields; revision 0.4)

| Pointer | Field | Kind | Ownership | Failure semantics |
|---|---|---|---|---|
| evidence | `source_pointer` = relative workspace path | external read-only artifact | user/other tools own it; machine never writes it; NOT hash-listed in STATE | existence is mandatory when a record is first added or restored to active state for provenance in {MACHINE_VERIFIED, AI_INFERRED, UNVERIFIED}. An unchanged already-active record whose evidence later disappears remains structurally valid and is returned with `evidence_status=dangling`; unrelated writes are not blocked. |
| note | `note_pointer` = `notes/<memory_id>.md` | canonical memory artifact | machine writes it ONLY in the same commit transition; hash-listed in STATE (D2.5) | missing in a committed generation = structurally impossible (same transition); if found missing later = generation untrusted (UNVERIFIED / STATE_MISMATCH) |

Both pointers are independent and MAY be set on the same record. The D2.1 pointer consistency rule is the only cross-pointer constraint. Machine classification is deterministic from the field form (note prefix `notes/` in `note_pointer`; any other relative path in `source_pointer`).

Evidence-validation scope (normative): path syntax/root/reparse safety is validated for every record in every proposed state. File existence is additionally checked only for a transition that introduces or re-activates the record (`add` or `restore`). `pin`, `unpin`, `forget`, FIFO, supersession of an existing record, and copying unchanged records into a new generation do not reclassify a later-dangling external file as structural corruption. This separation prevents one deleted evidence file from blocking all unrelated future commits while preserving AM-I-010 at activation time.

Path-safety guarantee scope and accepted residual risk (2026-10-12 addendum; user-accepted limited operational condition; AM-N-009 unchanged and fully enforced):

- Mandatory checks (unchanged): pointer containment (relative path under the workspace root; no `..`, absolute paths, or drive letters) and the reparse-point/symlink check on every existing path component remain mandatory for every record in every proposed state. This acceptance permits no omission, weakening, or bypass of any existing check.
- Guarantee scope: the current pathname-based implementation provides NO guarantee of complete prevention of check-then-use replacement races (TOCTOU): an external process that replaces a path component between the check and its use is not fully prevented.
- Operational condition: the tool is operated in a trusted single-user local environment, and path-composition changes under the workspace root are avoided while the tool is processing.
- Limit: this is an acceptance of a residual risk under the stated operational condition, NOT a safety proof. A single-user environment does not make the race impossible, and no dynamic race-prevention claim is made.

Revision-0.3 conflict record (audit): revision 0.3 carried the NOTE pointer in `source_pointer` and the external evidence in a separate `evidence_pointer` field. That contradicted the frozen AM-I-010 reading confirmed by user review 2026-10-06 (a source pointer is the evidence pointer; it may be absent only for a user-stated self-contained fact). Revision 0.4 flips the roles; the field COUNT is unchanged (10), only the roles of fields 6 and 7 are redefined.

## D2.9 Durable PASS receipt and history

`ACTIVE` and every `receipts/<operation_id>.pass` file use the same fixed seven-line, UTF-8-no-BOM ASCII format defined in D3.5 step 17. The receipt is the machine's durable proof that one exact write specification reached PASS; it is not a content root and never supplies user facts.

- `ACTIVE` is the latest receipt and is also the sole reader pointer. A conforming reader validates it against the referenced generation/STATE before reading memory content.
- `receipts/<operation_id>.pass` is an immutable historical receipt. The filename UUID MUST equal `OPERATION_ID` inside the file. Each receipt is at most 1024 bytes. It is created with create-new semantics and is never overwritten.
- Before replacing ACTIVE, the exact old ACTIVE bytes are persisted at their deterministic receipt path. If the file already exists, byte identity is required. During an interrupted later commit, the same receipt may therefore exist both as ACTIVE and at its historical path; byte-identical copies are one logical receipt, not a duplicate operation.
- A historical receipt remains valid evidence that the operation passed even if an operator later deletes its old generation snapshot. In that case exact retry may report the historical PASS, but the deleted content cannot be read or used as a rollback target.
- No receipt is created for a staged or CURRENT-only generation. Receipt conflict, malformed content, filename/UUID mismatch, or two non-identical receipts for one operation_id is `UNVERIFIED`; the machine never guesses which is authoritative.

---

# D3. Machine command and structured status contract (AM-I-001..AM-I-007)

## D3.1 Script and invocation

`workspace/tools/memory-tool/memory-tool.ps1`. PowerShell 5.1. No network. No transcript access. No runtime dependencies. stdout = exactly one JSON line. Exit codes: `0` = PASS/HIT/MISS; `1` = INVALID/STALE/UNVERIFIED/BLOCKED/FAILED; `2` = usage error. (Same shape as checkpoint-guard, a proven behavioral reference, AM-C-006.)

Common parameters:

| Parameter | Applies to | Rule |
|---|---|---|
| `-MemoryRoot` | all memory-root modes | required; must be inside an allowed root |
| `-WorkspaceRoot` | all memory-root modes | required; bounds evidence-pointer resolution and spec containment checks |
| `-ScratchpadRoot` | Commit, FilterDeepOut | required; the spec file must reside here / the candidate file is written here |
| `-Spec` | Commit, Forget, Restore | write-spec JSON path (inside scratchpad); all write modes use the same idempotent envelope |
| `-PendingOperationId` | AbortPending | exact pending UUID to discard after explicit user choice |
| `-Query` / `-Max` | Recall | comma-separated 1-4 keywords / default 5, hard cap 10 |
| `-Out` | FilterDeepOut | the offload OUT file path (existing, UTF-8, <=256 KiB) |
| `-LockTimeoutSeconds` | Commit-class | default 10; writer-lock acquisition timeout |

Explicit single-value string parameters only (no string arrays; PowerShell 5.1 `-File` invocation safety, per the checkpoint-guard precedent).

Modes (eight; the six AM-I-001 capabilities plus two bounded support modes):

| Mode | Capability class | State change |
|---|---|---|
| `Validate` | read-only validation (ACTIVE generation + STATE/notes hashes) | none |
| `Status` | read-only list/status | none |
| `Recall` | read-only fast recall | none |
| `Commit` | canonical commit (multi-operation) | yes (writer lock) |
| `Forget` | canonical commit (single record -> archive) | yes (writer lock) |
| `Restore` | canonical commit (single record archive -> index) | yes (writer lock) |
| `AbortPending` | explicit disposal of one never-PASSed pending operation | operational pointer/remnant only; canonical ACTIVE unchanged |
| `FilterDeepOut` | deep-recall OUT local narrowing (D7): read the offload OUT file, keep at most 3 well-formed CAND lines, write them to a scratchpad candidate file | none on memory/ (scratchpad write only) |

## D3.2 Structured result (AM-I-002)

Every invocation returns one JSON object containing at least:

```
status      : PASS | HIT | MISS | INVALID | STALE | UNVERIFIED | BLOCKED | FAILED
operation   : validate | status | recall | commit | forget | restore | abortpending | filterdeepout
records     : [affected record ids]
state_id    : { generation, operation_id, spec_sha256, core_sha256, index_sha256, archive_sha256, current: {generation, operation_id} }
diagnostics : [safe, bounded strings; no transcript, no secrets, AM-N-012]
```

- `state_id.generation`, `operation_id`, and `spec_sha256` come from the validated ACTIVE durable PASS receipt and its matching STATE.
- `state_id.current` reports CURRENT generation/operation identity. It matches ACTIVE in steady state and leads by one in a pending write.
- Status additionally returns storage metrics for existing completed directories `n <= ACTIVE.GENERATION`: `generation_count`, `completed_bytes_total`, `active_generation_bytes`, `largest_generation_bytes`; pending/remnant bytes are reported separately as `noncanonical_bytes`; the independent ledger reports `receipt_count` and `receipt_bytes_total`. Metrics are measured from disk, labelled `UNVERIFIED` if enumeration fails, and never trigger deletion.

Candidate entries (Recall) additionally carry: record_id, recorded_at, subject, tags, provenance, source_pointer, note_pointer, evidence_status (ok|dangling), matched_fields, matched_terms, score.

FilterDeepOut additionally returns `candidate_file` (absolute path of the scratchpad file it wrote, at most 3 lines) and diagnostics `total_cand_lines`, `malformed_dropped`, `out_bytes`.

## D3.3 Status vocabulary (AM-I-003) and required client behavior

| Status | Machine meaning | Required chat-AI behavior |
|---|---|---|
| PASS | operation committed and re-verified, an exact retry recovered the same durable PASS, or validation is clean | continue; report the verified completed operation (1 line: operation_id + affected ids/result) |
| HIT | >=1 lexical candidate returned (Recall) or >=1 well-formed deep candidate written (FilterDeepOut) | inspect bounded source evidence (<=2 notes, <=64 KiB) before composing the answer |
| MISS | 0 lexical candidates / 0 well-formed deep candidates | report "no established auxiliary-memory record" / "deep recall returned no usable candidates"; never claim a real-world fact does not exist; at most 2 fast-recall attempts per question |
| INVALID | proposal or existing content violates schema/bounds/forbidden content | no state change; correct the spec and retry at most once (only while the user request is still pending) |
| STALE | CAS base mismatch, or a concurrent writer holds the writer lock | refresh state via Status/Validate; retry at most once; never overwrite newer state |
| UNVERIFIED | memory root absent / undecodable / STATE or note-hash mismatch / machine absent / OUT file unreadable | do not claim machine verification; bounded read-only fallback (ACTIVE-resolution direct read) or report unresolved; conversation continues; report `L0_UNVERIFIED`-style one-liner |
| BLOCKED | write path refused for a policy-level reason (memory root outside allowed roots; spec outside scratchpad root; commit requested over an UNVERIFIED base; deep-recall input budget exceeded) | keep the candidate spec in scratchpad; state the condition required to continue; never write canonical files directly |
| FAILED | I/O or staging/switch/verify failure (incl. `staged_verify_failed`, `postswitch_rollback`, `out_exceeds_bound`) | prior valid state preserved (retained generations); report failure; never claim success |

`MISS` and `UNVERIFIED` are distinct and never conflated (AM-I-016). The status vocabulary is exactly these 8. Sub-conditions travel in `diagnostics`, e.g. `writer_active`, `cas_mismatch`, `operation_id_reuse`, `idempotent_pass_recovered`, `pending_operation:<id>`, `pending_resumed:<id>`, `pending_aborted:<id>`, `receipt_history_conflict`, `staged_verify_failed`, `postswitch_rollback`, `stale_generation_cleaned:<n>`, `deep_input_exceeds_budget`, `dangling_evidence`, `out_exceeds_bound`.

## D3.4 Commit spec format (the candidate)

Written by the AI into the scratchpad (`draft_` prefix), consumed by `Commit`:

```json
{
  "operation_id": "8f06ca9e-9186-4f30-91d3-8b51ca4c82c4",
  "expected": {
    "generation": 12,
    "core":  "<sha256 hex or ABSENT>",
    "index": "<sha256 hex or ABSENT>",
    "archive": "<sha256 hex or ABSENT>"
  },
  "operations": [
    { "op": "add",
      "subject": "...",
      "tags": ["chess", "learning"],
      "provenance": "USER_STATED",
      "summary": "...",
      "note": "<inline prose or null>",
      "evidence": "<relative path under workspace root, or null>",
      "pin": false,
      "supersedes": "mem_0007 or null" },
    { "op": "pin",   "record_id": "mem_0003" },
    { "op": "unpin", "record_id": "mem_0003" }
  ]
}
```

- `operation_id` is mandatory for every write mode: canonical lowercase UUID text. The SHA256 of the exact UTF-8-no-BOM spec bytes is the `spec_sha256`. The same operation_id with different bytes is `INVALID` (`operation_id_reuse`). An exact byte-for-byte retry is idempotent.
- `expected` is mandatory and is the AI's most recent machine-observed state (from Status/Validate/previous Commit output; `state_id.generation` = ACTIVE). A missing memory root is the empty base: `generation 0`, all hashes `ABSENT`.
- `add.note` is inline prose (single self-contained candidate; no external content path). `add.evidence` is the external evidence path (becomes `source_pointer`). Both are independent and may be set together (D2.8). `evidence = null` is allowed only for `provenance = USER_STATED` (D2.1 pointer consistency rule, AM-I-010).
- Commit accepts 1-16 operations. Initialization uses the same envelope with exactly `"operations": [{"op":"initialize"}]`; it is permitted only against logical generation 0 and is INVALID once ACTIVE exists. Multiple ordinary operations in one spec = one consistent committed transition or none.
- `records` (result) = the record ids directly operated by the spec, in operation order, plus the explicitly named `supersedes` target id: `add` contributes its new id (then its supersedes target, if any); `pin` contributes the named target id when it effectively pins; `unpin`/`forget`/`restore` contribute the named target id. An id directly operated more than once in one spec may appear more than once (no deduplication is promised). FIFO-evicted ids that were not directly operated in that spec are never in `records`.
- Records are immutable: the spec vocabulary has no edit/update operation. Correction = `add` with `supersedes`.
- Forget and Restore use the same envelope and `-Spec`, with exactly one action object: `{ "op": "forget", "record_id": "mem_NNNN" }` or `{ "op": "restore", "record_id": "mem_NNNN" }`. Their `expected`, operation_id, hashing, CAS, durable PASS, and retry rules are identical to Commit.

## D3.5 Write protocol (durable PASS receipt, exact-retry recovery, no unrelated adoption)

Design choice (revision 0.5): generation snapshots and the writer-only CURRENT pointer preserve the required validate -> switch -> post-switch-revalidate order. Reader visibility and the durable result are one atomic artifact: ACTIVE is a fixed PASS receipt that binds generation, operation_id, exact spec hash, and STATE hash. A write that loses its stdout acknowledgement is recovered by exact retry; a different later write is never permitted to adopt the pending generation.

Writer lock: the machine opens `workspace/memory/.lock` with `FileShare.None`. The open handle is the lock; it is not a flag file and the OS releases it on process termination. Readers take no lock because they resolve only immutable generations named by a validated ACTIVE receipt.

Pointer invariants:

- steady state: ACTIVE and CURRENT carry the same generation/operation/spec/STATE identity; before the first PASS, both may be absent and logical generation is 0;
- pending state: `CURRENT.GENERATION = ACTIVE.GENERATION + 1`; CURRENT and the pending STATE bind the same operation_id/spec/STATE hashes; no reader uses CURRENT as content root;
- CURRENT never points behind ACTIVE;
- no code path changes ACTIVE for a pending operation unless the currently executing write has the SAME operation_id and SAME spec hash.

Protocol steps (Commit, Forget, and Restore use the same envelope and engine):

1. Read the exact spec bytes; strict UTF-8-no-BOM decode; parse schema, operation_id, expected state, and mode-specific action. Compute `spec_sha256` over the exact bytes. Malformed input -> `INVALID`, no state change.
2. Validate MemoryRoot/WorkspaceRoot paths before use. If MemoryRoot is absent, create only the root, `.gen`, and `receipts` directories with idempotent directory creation; this is operational scaffolding, not canonical memory. Reject reparses/path escape. Then acquire `.lock` exclusively (default timeout 10 s). Concurrent first writers may both request directory creation but only one can pass the lock. Lock failure -> `STALE writer_active`.
3. Resolve base records. Missing ACTIVE is logical empty PASS state A=0 (`operation_id=INITIAL_EMPTY`, hashes ABSENT). Both records absent is a clean empty root. ACTIVE absent with valid CURRENT.GENERATION=1 is a first-write pending state. ACTIVE absent with CURRENT>1, CURRENT absent while ACTIVE exists, malformed/binding-mismatched records, CURRENT<ACTIVE, or CURRENT>ACTIVE+1 -> `UNVERIFIED`.
4. Durable-PASS replay check. Compare the incoming operation_id with ACTIVE.OPERATION_ID and read only its deterministic historical path `receipts/<incoming-operation-id>.pass` if present; validate D2.9 syntax and identity.
   - one logical receipt (ACTIVE, historical file, or byte-identical copies in both places) with the same SPEC_SHA256 -> return its stored generation/ACTION/AFFECTED_IDS as the original `PASS`, diagnostic `idempotent_pass_recovered`; no write occurs, even if later generations are ACTIVE;
   - a matching operation_id with a different SPEC_SHA256 -> `INVALID operation_id_reuse`; malformed/non-identical copies or filename/UUID mismatch -> `UNVERIFIED receipt_history_conflict`; no state change;
   - no match -> continue to pending/CAS handling. Lookup is O(1) by operation_id; it does not scan an unbounded receipt ledger.
5. Pending-state handling when CURRENT.GENERATION = ACTIVE.GENERATION+1:
   - Read and fully validate the pending generation and its OPERATION_ID/SPEC_SHA256 from STATE.
   - SAME incoming operation_id and SAME spec hash, pending valid: resume only the interrupted operation. If A>0, first ensure `receipts/<ACTIVE.OPERATION_ID>.pass` exists as a byte-identical create-new copy of the old ACTIVE receipt (D2.9); conflict -> `UNVERIFIED receipt_history_conflict` with the pending state unchanged. Then atomically write the pending generation's ACTIVE durable PASS receipt, read it back and verify it, release the lock, return its reconstructed `PASS`, diagnostic `pending_resumed:<id>`. The operations are NOT applied a second time.
   - SAME operation_id but different spec hash: return `INVALID operation_id_reuse`; do not change ACTIVE, CURRENT, or the pending directory. The exact original spec may still recover it, or the user may explicitly AbortPending.
   - SAME operation_id/spec but pending invalid: restore CURRENT to ACTIVE (for logical A=0, remove CURRENT), remove or quarantine the never-ACTIVE pending directory, return `FAILED pending_invalid`; prior canonical state is unchanged.
   - DIFFERENT incoming operation_id: return `STALE pending_operation:<old-id>` with no state change. The client must surface the pending operation and obtain the user's choice: exact retry or AbortPending. A new memory write never silently discards or adopts it.
6. Remove staged directories with generation > CURRENT. They were never named by ACTIVE or CURRENT and are non-canonical remnants. Record bounded `stale_generation_cleaned:<n>` diagnostics.
7. Load and fully validate the ACTIVE generation. Empty generation 0 uses ABSENT hashes. Failure -> `UNVERIFIED`.
8. CAS: expected generation and core/index/archive hashes must match ACTIVE. Mismatch -> `STALE cas_mismatch`; no canonical state change.
9. Compute the proposed transition in memory, target ACTIVE+1:
   - initialize: allowed only as the sole operation at logical generation 0; create empty core/index/archive/notes state;
   - add: assign id, create record/note, require resolving source_pointer for non-USER_STATED provenance, perform explicit supersession/pin semantics;
   - pin/unpin: apply only to the named active record; machine enforces bounds, chat AI owns semantic stability classification;
   - forget: archive the named active/pinned record;
   - restore: reactivate the newest matching archive entry; a non-USER_STATED source_pointer MUST resolve at this re-activation transition, otherwise `INVALID restore_source_missing`; note_pointer must resolve inside the proposed generation.
10. Apply FIFO and validate the complete proposed state in memory. Structural/path/encoding/hash-list rules apply to every record; external-evidence existence applies only to newly added or restored records (D2.8). Violation -> `INVALID`.
11. Stage the complete immutable snapshot at `.gen/<ACTIVE+1>`. STATE records generation, operation_id, spec hash, affected ids, action, file hashes/bytes, and every note hash. I/O failure -> `FAILED`.
12. Verify the staged generation FROM DISK: strict decoding, STATE binding, all file/note hashes and byte counts, no unlisted note, bounds, schema, and transition-scoped evidence checks. Failure -> `FAILED staged_verify_failed`; ACTIVE/CURRENT unchanged.
13. Re-read ACTIVE and CURRENT under the lock. Any change from the values used above -> `STALE`; the staged directory remains a removable remnant.
14. Build CURRENT.tmp with GENERATION, OPERATION_ID, SPEC_SHA256, and STATE_SHA256; flush and atomically replace CURRENT. I/O failure -> `FAILED`; ACTIVE remains the prior PASS state.
15. Re-validate the generation through CURRENT from disk (AM-I-005). Failure -> restore CURRENT to ACTIVE (delete CURRENT when A=0), remove/quarantine the never-ACTIVE generation, return `FAILED postswitch_rollback`.
16. Preserve the prior PASS receipt before replacing ACTIVE: if A>0, create `receipts/<ACTIVE.OPERATION_ID>.pass` from the exact existing ACTIVE bytes using create-new semantics. If it already exists, it must be byte-identical. Any mismatch/failure -> roll CURRENT back and return `UNVERIFIED receipt_history_conflict`; never overwrite a receipt. If a crash occurs after this copy but before ACTIVE changes, ACTIVE and the historical path contain byte-identical copies and are treated as one logical receipt (D2.9).
17. Build ACTIVE.tmp as the durable PASS receipt:

   ```text
   GENERATION=<n>
   OPERATION_ID=<lowercase UUID>
   SPEC_SHA256=<hex64>
   STATE_SHA256=<hex64 hash of exact STATE bytes>
   ACTION=<initialize|commit|forget|restore>
   AFFECTED_IDS=<comma-separated memory_ids or ->
   RESULT=PASS
   ```

   Flush and atomically replace ACTIVE, then read ACTIVE back. If it matches the candidate receipt and the referenced STATE, durable commit is complete. If it still equals the prior valid receipt, roll CURRENT back and return `FAILED active_switch_io_failed`. If it is neither valid old nor valid new, return `UNVERIFIED active_switch_outcome_unknown` without deleting either generation; explicit diagnosis is required.
18. Release lock and emit the structured `PASS` reconstructed from the durable receipt.

`AbortPending` protocol: explicit user choice is required. Under the writer lock, validate ACTIVE/CURRENT and require CURRENT=ACTIVE+1 with STATE.OPERATION_ID equal to `-PendingOperationId`. Restore CURRENT to ACTIVE (delete CURRENT for logical A=0), remove or quarantine that never-ACTIVE directory, and return `PASS pending_aborted:<id>`. If no matching pending operation exists, return `STALE`; it never changes ACTIVE or any completed generation.

PASS semantics (normative operationalization of AM-I-007/AM-T-042): a write has PASS exactly when ACTIVE was atomically replaced by a valid receipt binding generation, operation_id, spec hash, STATE hash, action, affected ids, and `RESULT=PASS`. Before the next ACTIVE replacement, that receipt is immutably archived under `receipts/<operation_id>.pass`. Exact retry performs deterministic lookup in ACTIVE plus that operation's receipt path and returns the same PASS without repeating the transition.

Crash semantics:

- Before CURRENT switch: ACTIVE/CURRENT remain on the prior PASS generation (or both absent for logical generation 0); staging is a never-visible remnant.
- After CURRENT switch but before ACTIVE receipt: ACTIVE remains prior PASS; read modes report `pending_operation:<id>`. Exact retry resumes and returns PASS. A different operation returns STALE without change. Explicit AbortPending is the only discard path.
- During ACTIVE atomic replacement: disk contains either the valid old receipt or valid new receipt. Old follows pending rules; new is durable PASS. If later read-back cannot prove either, state is `UNVERIFIED`, not presumed success.
- After ACTIVE receipt but before JSON delivery: exact retry returns `PASS idempotent_pass_recovered`, even if another chat later committed newer generations; it never creates a duplicate record.
- Post-PASS damage: Validate -> `UNVERIFIED`; retained generations support explicit user-authorized repair.

## D3.6 Read-only guarantees (AM-I-004)

Validate, Status, Recall, and the list aspect of Status never modify canonical or operational state. They validate the ACTIVE receipt, resolve its generation exactly once, and read only that immutable generation. They may read CURRENT only to report `pending_operation:<id>` but never use CURRENT as a content root and never reconcile it. FilterDeepOut never touches the memory root (it reads an OUT file and writes one bounded scratchpad file). The machine writes no log file in P1; diagnostics travel in the one-line JSON only (AM-N-012).

## D3.7 Forget / Restore (commit-class, single record)

- `Forget -Spec <write-spec>`: the spec names one active or pinned record. The record (and its core copy, if pinned) is removed from core+index and appended to archive with reason=`forgotten`. It uses the same operation_id, expected-state, durable-PASS, and exact-retry rules as Commit.
- `Restore -Spec <write-spec>`: target must be in archive (any reason). It returns to index.md as lifecycle=`active` with its original memory_id, recorded_at, and fields (stable identity, AM-F-018). If note_pointer is set, the note must exist in the proposed generation; otherwise `INVALID restore_note_missing`. For non-USER_STATED provenance, source_pointer must resolve at this re-activation commit; otherwise `INVALID restore_source_missing`. A previously pinned record restores as active (unpinned); re-pinning is separate. FIFO applies.
- Duplicate archive history: when several archive lines carry the same memory_id (forgotten-restored-forgotten...), Restore acts on the NEWEST entry (latest archived_at; tie -> the line appended last) and removes exactly that line; older entries remain as legitimate history (D2.3). Restore of a `superseded` record is allowed and simply coexists with the record that superseded it (both active; AM-F-019).
- Secure irreversible purge is out of P1 (AM-F-025, P2).

---

# D4. State transitions

## D4.1 Record lifecycle

```
[none] --add--------------------> ACTIVE            (index)
[none] --add+pin----------------> PINNED            (core + index)
ACTIVE  --pin-------------------> PINNED
PINNED  --unpin-----------------> ACTIVE
ACTIVE  --superseded by add-----> SUPERSEDED        (archive, reason=superseded)
PINNED  --superseded by add-----> SUPERSEDED        (core copy removed in same transition)
ACTIVE  --FIFO overflow----------> EVICTED          (archive, reason=evicted; non-pinned only)
ACTIVE  --forget-----------------> FORGOTTEN        (archive, reason=forgotten)
PINNED  --forget-----------------> FORGOTTEN        (core + index copies removed)
FORGOTTEN --restore---------------> ACTIVE
EVICTED   --restore---------------> ACTIVE
SUPERSEDED--restore---------------> ACTIVE
(any active/pinned) --purge(P2, not in P1)--> [deleted]
```

## D4.2 Write state machine (revision 0.5: durable PASS and exact retry)

```text
SPEC -> PARSE/HASH -> LOCK
  -> ACTIVE or receipts/<operation_id>.pass proves same operation/spec
       -> validate receipt -> PASS (idempotent recovery; no write)
  -> CURRENT = ACTIVE+1 (pending)
       -> same operation_id/spec hash -> validate -> ARCHIVE PRIOR RECEIPT -> WRITE ACTIVE PASS -> PASS
       -> different operation       -> STALE pending_operation (no change)
       -> same id/different hash     -> INVALID (no change)
       -> explicit AbortPending      -> rollback/remove pending -> PASS
  -> LOAD ACTIVE -> CAS -> COMPUTE -> VALIDATE
  -> STAGE -> DISK VERIFY -> SWITCH CURRENT -> REVALIDATE THROUGH CURRENT
  -> ARCHIVE PRIOR RECEIPT -> WRITE+VERIFY ACTIVE PASS RECEIPT -> PASS

CRASH before CURRENT:
  ACTIVE unchanged; staging is non-canonical remnant.
CRASH after CURRENT, before ACTIVE:
  ACTIVE unchanged; exact retry alone may resume; unrelated operation stops; user may AbortPending.
CRASH during ACTIVE atomic replace:
  ACTIVE is valid old or valid new; old follows pending path, new is recoverable PASS.
CRASH after ACTIVE, before stdout:
  exact retry returns original PASS; no duplicate transition.
```

---

# D5. Consistency and concurrency design (AM-N-007, AM-N-008, AM-I-006, AM-I-007/AM-T-042)

Mechanism: immutable full-generation snapshots; staged disk verification; writer-only CURRENT; post-switch revalidation; atomic ACTIVE durable PASS receipt; operation_id/spec-hash idempotency; OS exclusive writer lock; no automatic pruning of completed generations in P1.

Proofs:

1. Atomic visibility (AM-I-006): every changed canonical artifact is in one generation and verified before ACTIVE changes. Readers validate ACTIVE once and read only that immutable generation. CURRENT is never a reader root. The ACTIVE atomic replace exposes the whole generation or none of it.

2. Concurrency/staleness (AM-N-008): one OS-exclusive writer lock serializes writers; expected generation and three content hashes are checked against ACTIVE under the lock. A stale spec cannot replace newer canonical state. operation_id reuse with different bytes is rejected.

3. Failure preservation and acknowledgement loss (AM-N-007): failures before ACTIVE leave the previous ACTIVE receipt intact. A crash after CURRENT creates only a non-canonical pending generation. Only an exact retry may finish it; unrelated work stops; explicit AbortPending may discard it. After ACTIVE, the exact receipt is preserved at `receipts/<operation_id>.pass` before any later ACTIVE replacement, so exact retry can reconstruct PASS even after later commits or old-snapshot cleanup. A crash after receipt archival but before ACTIVE replacement merely leaves byte-identical copies, which D2.9 treats as one logical receipt.

4. Reader-input safety: P1 never automatically deletes a generation that has ever been named by ACTIVE. Therefore a reader that resolved generation N keeps valid input even after arbitrarily many later commits. Cleanup is restricted to generations never named by ACTIVE. The rejected mtime counterexample from v0.3 remains part of the audit record. P2 pruning requires a separately proven reader lease or equivalent.

5. Candidate invisibility and PASS evidence (AM-I-007/AM-T-042): before ACTIVE replacement, no conforming reader can resolve the candidate. ACTIVE replacement is the machine commit's durable PASS event and writes `RESULT=PASS` together with generation, operation_id, spec hash, and STATE hash. Visibility therefore implies durable, machine-verifiable PASS evidence; the normal client receives the corresponding PASS result from that same invocation and never writes canonical files itself. If stdout is lost, Status can prove the still-active result or exact retry can recover any retained receipt; no unrelated operation adopts or discards the candidate.

6. Evidence lifecycle (AM-I-010): an added or restored non-USER_STATED record cannot become active unless its source_pointer resolves at that transition. Later disappearance is reported as dangling and does not retroactively invalidate prior commits or block unrelated writes.

7. Storage honesty/lightweight boundary: bootstrap and fast recall stay bounded because they read only ACTIVE core/index. Disk retention is not size-bounded in P1; Status exposes measured totals. This is an explicit local-PC tradeoff, not a claim of bounded storage.

Readers remain lock-free because ACTIVE points only to immutable completed snapshots. Writers cannot delete completed snapshots in P1.

---

# D6. Fast recall matching design (AM-I-013; lexical and bounded)

- Corpus: record lines of core.md + index.md of the ACTIVE generation only. Never archive, never note bodies, never headers/STATE/ACTIVE/CURRENT.
- Query: 1-4 keywords (AI-extracted; J1).
- Match: deterministic substring search. ASCII case-insensitive (both sides lowercased); Japanese byte-exact substring. No stemming, no morphological analysis (documented limitation; OE-002 measures Japanese hit rate; P2 improvement path).
- Pinned-record dedup: a pinned record's line occurs in both core.md and index.md; candidates are deduplicated by memory_id before scoring/output (the two copies are field-identical in all searched fields, so dedup is lossless). A pinned record yields exactly ONE candidate.
- Field weights: subject 3, tags 3, summary 1, memory_id 0 (not searched). Record score = sum per keyword of the maximum weight among that keyword's matched fields in the record.
- Output (HIT): candidates ordered by score desc, then recorded_at desc, then memory_id asc; each candidate carries record_id, recorded_at, subject, tags, provenance, source_pointer, note_pointer, evidence_status, matched_fields, matched_terms, score. Bounded: `-Max` default 5, hard cap 10.
- Output (MISS): zero candidates. A lexical hit is never labelled a semantic truth judgment (AM-I-013); relevance is the chat AI's bounded judgment after source inspection (J3).
- AI usage bound: at most 2 Recall calls per user question (second call = keyword refinement). After 2 MISS, the answer is the honest no-record statement (AM-F-013).

Performance acceptance rule (revision 0.3, unchanged): AM-N-005 (fast recall P95 <= 2.0 s over 50 runs, max-size P1 fixtures, AM-T-027) is a HARD acceptance criterion. If AM-T-027 measures P95 > 2.0 s, the test result is FAIL - it is never reported as "within tolerance" or silently accepted. Resolution has exactly two paths: (a) a DESIGN adjustment that keeps the frozen requirement text intact (e.g., corpus/bounds/weight tuning within AM-N-001..003), followed by re-measurement; or (b) a REQUIREMENT-CHANGE PROPOSAL to the user (AM-N-005 is frozen; altering its text requires explicit user approval). Until P95 passes or the user changes the requirement, P1 release status stays non-operational (requirements section J rule 4).

---

# D7. Deep recall integration (AM-F-015..017, AM-I-014, AM-C-005)

The normative deep-recall task contract is THIS section (revision 0.2, refined 0.3, CAND field count corrected 0.4; 02 section 6 carries a non-normative JA copy for operators and must not diverge).

- Trigger: explicit user request only (e.g., "dig deeper", "search more"). A fast-recall miss SHALL NOT auto-invoke deep recall (AM-F-017).
- Mechanism: the existing `api-context-offload` skill. Contract re-read from disk 2026-10-06 (OE-004): job-spec JSON -> `python <skill>/scripts/offload.py <spec.json>`; stdout RESULT/OUT/PREVIEW/WARN/GATE; exit 0/2/3/4/1; helper-injected fixed system preamble (isolated-endpoint assumption); no-probe and brand-frame rules apply.
- Job spec composition (by the chat AI; facts resolved per the skill's resolution rule - current environment: `policy/api-context-offload-facts.md`, OBSERVED 2026-10-06):
  - `model`: the strong-reasoning tier model registered in the facts (current environment: `qwen` = qwen3.8-27b).
  - `api_url`: from the facts (current: `http://localhost:1234/v1/chat/completions`). If the facts file changed or is absent, re-resolve per the skill; unresolved environment = UNVERIFIED, report, do not guess.
  - `inputs`: EXACTLY the files of the ACTIVE generation (scope definition): `core.md`, `index.md`, `archive.md`, and every `notes/*.md` of that generation, as absolute paths. Nothing outside the ACTIVE generation, nothing from other roots. Long-running reader safety (inputs cannot be removed mid-job): no automatic pruning of completed generations in P1 (D1.1, D5 proof 4).
  - Input budget: if the total byte size of those inputs exceeds 262144 bytes (256 KiB; design constant grounded in the facts' measured model context 150016 tokens for the strong tier and the measured 26k-prompt-token handling), do NOT invoke the offload: report `BLOCKED` with diagnostic `deep_input_exceeds_budget`; fast recall remains fully usable (AM-C-005). Budget is P2-tunable after OE-005 growth measurement; changing it is a design change, not a requirement change.
  - `max_tokens`: "max" (reasoning models consume budget on reasoning; a numeric cap was a measured failure trigger in the facts).
  - `expect_terms`: not set (a single fixed term list cannot cover both output branches without false-gating; the skill's measured ST-5 false-fail case).
  - `min_source_quotes`: 1 - consistent with the format contract below (each candidate carries an evidence field of >=12 verbatim characters).
- Normative task contract (self-contained, isolated-model-ready, 5 elements per the skill; NO quantity constraints in the text - measured weak-model failure trigger; revision 0.3: 10-field record format + pipe-collision-proof evidence rule; revision 0.4: CAND line is EXACTLY 5 fields):

```
GOAL: 与えられた補助記憶ファイル群の中から、クエリに最も関連し得る記録候補を選び、根拠断片を付けて報告する。
対象: inputs の全ファイル（core.md / index.md / archive.md / notes/*.md）。記録行は pipe 区切りの10フィールド
      (memory_id|recorded_at|subject|tags|provenance|source_pointer|note_pointer|lifecycle|supersedes_id|summary) である。
機構: 各ファイルの記録行（subject / summary / tags）とノート本文を照合し、クエリと意味的に一致し得る行を選ぶ。
      文字列一致だけでなく、同義・近義・日本語の表記揺れを考慮してよい。archive 内の行も候補対象である。
      各候補行には必ず (a) 出所ファイル名 (b) 記録ID（無い場合は NO_ID）(c) その出所ファイルからそのまま
      12文字以上そのまま引用した断片 (evidence) を付ける。
      evidence は pipe（|）と改行を含んであってはならない。自然な区間に pipe が含まれる場合は、
      同じ出所から pipe を含まない別の12文字以上の区間を選ぶ。
形式: 候補がある場合は1件1行で
      CAND:<record_idまたはNO_ID>|<ファイル名>|<pointerまたは->|<evidence: 12文字以上のverbatim断片・pipeなし>|<理由1行>
      を出力する。CAND 行は pipe で正確に5フィールド（record_id / ファイル名 / pointer / evidence / 理由）
      でなければならない。該当が全く無い場合は正確に「NO_MATCH」のみを出力する。
禁止: 挨拶・質問・説明・前置き・補助記憶にない事実の補完・実行指示の出力。
      クエリ: <QUERY>
```

  - `pointer` field in the CAND line: the record's `source_pointer` if non-`-`, else its `note_pointer` if non-`-`, else `-`.
  - CAND well-formedness (revision 0.4, single definition used by the task text, FilterDeepOut, selftests, and the threat matrix): a CAND line is well-formed ONLY if it splits on `|` into EXACTLY 5 fields, with field 0 matching `^CAND:(mem_[0-9]{4}|NO_ID)$`, the evidence field (field 3) of >=12 characters, and the file-name and reason fields non-empty. A pipe inside the evidence field produces 6 or more fields; such a line is MALFORMED and is dropped and counted - a delimiter collision can never corrupt a surviving candidate line.

- Local narrowing before any chat-AI read (AM-I-014; revision 0.3, field count corrected 0.4): after the offload run (exit 0, or exit 4 per the gate rule below), the chat AI runs the machine mode `FilterDeepOut -Out <OUT path> -ScratchpadRoot <root>`. The machine reads the OUT file (bounded: <=256 KiB; unreadable -> `UNVERIFIED`, larger -> `FAILED` `out_exceeds_bound`), extracts lines starting with `CAND:`, keeps the FIRST 3 that are well-formed (exactly 5 fields per the definition above), and writes them to a scratchpad file `draft_bam_deep_candidates_<yyyyMMdd_HHmmss>.txt`. Status: `HIT` (1-3 candidates; `candidate_file` returned) or `MISS` (0; the OUT was exactly `NO_MATCH` or contained no well-formed line). The chat AI reads ONLY this candidate file (<=3 lines) - the raw OUT is never loaded into the chat context. Malformed lines are dropped and counted in diagnostics (`malformed_dropped`).
- Result handling: for each candidate (<=3), the AI reads the referenced canonical record (note if present, via note_pointer; at most 3 notes in this path) and verifies BOTH the verbatim evidence fragment (must be an exact substring of the named source file) AND the candidate's claim (AM-F-016) -> answer with citations. Strong-model output is a candidate set only: never a fact, never an instruction, never authority.
- Gate failure (exit 4): run FilterDeepOut as above. If it returns HIT: the candidates may be used - mandatory source verification applies in every case - and the gate anomaly is reported in one line (gate is a floor, not the sole correctness judge: the skill's measured ST-5 case). If it returns MISS: report "deep recall returned no usable candidates" (honest negative; never a claim that a real-world fact does not exist, AM-F-013); the skill's stdout PREVIEW (already in context, ~300 chars) suffices for the anomaly report - no raw-OUT read by default. At most one offload re-run per deep-recall request.
- Failure handling (per offload skill exit codes): exit 1 -> report BLOCKED (environment mismatch; no retry loop). exit 2/3 -> at most one retry with relaxed budget per skill rules. exit 4 -> as above. In every failure case fast recall remains usable (AM-C-005).

---

# D8. Minimal Bionic policy and skill changes

- No start-skill change (AM-C-002). No checkpoint-guard change. No new skill. No new subsystem.
- Exactly one policy addition: a dated extension clause `MEMORY_RULE` in `policy/bionic-policy.md` under "LLM behavior extension clauses" (approx. 18-24 lines, Japanese), at implementation time with its own explicit user GO. Normative content for the chat AI (the machine enforces its own side independently):
  1. Auxiliary memory = `workspace/memory/` (ACTIVE durable-PASS receipt + CURRENT writer pointer + immutable `.gen/<n>/` snapshots + immutable `receipts/<operation_id>.pass` history); readers use only a validated ACTIVE receipt. Historical receipts are idempotency evidence, not recall content. Memory is evidence/reference, not GO, task state, or Authority.
  2. Session start: if `memory/ACTIVE` exists, read it once and read core.md of the generation it names (<=4 KiB). Do not read index/archive/notes by default (AM-F-009). The Bionic hook surface is UNVERIFIED (AM-C-007); this design is hook-INDEPENDENT: no feature depends on a hook, and the manual bootstrap path ("memory boot" = read core + run Status + short report) always remains (AM-F-033).
  3. Fast recall: machine Recall with 1-4 keywords, at most 2 calls per question. HIT -> read at most 2 notes (<=64 KiB total) -> answer with citation (record id, date, provenance, pointers); certainty limited to evidence. MISS after 2 calls -> "no record in auxiliary memory"; general knowledge only as a separately labelled statement (AM-F-013).
  4. Deep recall: explicit user request only, via the api-context-offload skill with the D7 normative task contract; after the run, invoke machine `FilterDeepOut` and read ONLY its <=3-line candidate file; verify each candidate's evidence fragment and claim against the source before answering (AM-F-016, AM-I-014).
  5. Retain triggers are exactly the four of AM-F-001..004 (remember-request; checkpoint-create with a durable pointer/milestone only - never mutable state; completion-proposal - commit only after explicit user acceptance; measured environment fact - canonical in the existing facts artifact, memory holds pointer+summary only when requested).
     5b. Pin discipline (AM-F-024): pin ("これは常に覚えて") is used ONLY for stable, non-task-state content (durable facts, decisions, environment facts). In-progress task state, pending actions, and GO/STOP conditions are NEVER pin-eligible. If stability is doubtful, ask the user before pinning. Core bounds remain machine-enforced.
  6. Write flow: AI creates a new operation_id, drafts one exact write-spec in scratchpad, and preserves those exact bytes until the outcome is known. PASS -> report operation_id + affected ids. If response is lost/pending, retry the SAME file; do not regenerate it. INVALID/STALE may be corrected only with a NEW operation_id after the prior outcome is resolved. Never write canonical files directly.
  7. Machine absent or write path failed: conversation continues; read path = bounded direct read of validated ACTIVE + UNVERIFIED report; write path = BLOCKED. If Status reports `pending_operation:<id>`, report it and ask the user whether to retry the exact spec or AbortPending. No different write proceeds until that choice is resolved.
  8. Conflict between memory and current routing/user direction -> surface to the user; never silently resolve in favor of memory (AM-F-029).
  9. L0-L3 rules are unchanged and take precedence over this clause.

---

# D9. Test-first plan (deliverable 9)

The mandatory acceptance cases are AM-T-001..043 of the requirements (section J), with their stated primary requirement IDs. The next phase attaches fixture setup, exact command, expected JSON/status, and execution class. Revision 0.5 adds mandatory sub-cases for durable PASS/idempotency, transition-scoped evidence, and measured storage reporting.

- Machine selftests (script + temp fixtures only; same proven pattern as `test-checkpoint-guard.ps1`: fixture root under `$env:TEMP\bam-test-<guid>`, child-process invocation in the exact Bionic command form `powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <script> <args>`, case counter, fixture kept on failure, no network, no transcript):
  AM-T-001, AM-T-002, AM-T-003, AM-T-004, AM-T-005, AM-T-006 (fault injection before CURRENT, after CURRENT, before/after prior-receipt archival, during ACTIVE atomic replace, and after ACTIVE before stdout), AM-T-007 (two-writer and stale base), AM-T-008, AM-T-009, AM-T-010, AM-T-011, AM-T-012, AM-T-013, AM-T-026, AM-T-027, AM-T-028, AM-T-029, AM-T-033, AM-T-041.
  Machine sub-cases supporting live cases (run in the selftest suite; the acceptance case itself stays live per requirements section J rule 2):
  - AM-I-012 forbidden-field commit rejection (fixture of AM-T-020).
  - CAND 5-field well-formedness sub-cases (supporting AM-T-018 / AM-I-014): 3 well-formed 5-field lines kept; 7 well-formed lines -> exactly 3 kept (first 3); a 6-field line (pipe inside evidence) dropped + counted as malformed; a 7-field line dropped + counted; exactly `NO_MATCH` -> MISS; OUT >256 KiB -> FAILED out_exceeds_bound; OUT absent -> UNVERIFIED; memory root untouched after FilterDeepOut (hash compare).
  - Durable PASS/idempotency: crash after CURRENT -> read modes return old ACTIVE + `pending_operation`; exact same operation_id/spec resumes and returns PASS once; same id/different bytes -> INVALID with pending unchanged; different operation -> STALE with pending unchanged; explicit matching AbortPending -> PASS and removal; crash after ACTIVE/before stdout -> exact retry returns original PASS with identical affected ids and no duplicate. Before a later ACTIVE replacement, the prior receipt is archived byte-identically at `receipts/<operation_id>.pass`; crash between receipt archival and ACTIVE replacement is recoverable; a byte-identical ACTIVE/history copy is accepted as one logical receipt; non-identical copy, malformed receipt, or filename/UUID mismatch returns UNVERIFIED without overwrite. Exact retry of an older operation after two later commits and after manual deletion of its old snapshot still returns its historical PASS without claiming that deleted content remains available.
  - Evidence lifecycle: add and restore reject missing non-USER_STATED source; an already-active record whose evidence is later deleted becomes `dangling` but does not block pin/unpin/forget or an unrelated add; path/reparse checks remain enforced for every state.
  - Retention/storage: a reader's generation remains readable after multiple commits; Status byte metrics equal independent filesystem measurement for fixtures with small and multi-MiB notes/archive; no automatic deletion occurs.
- Live behavioral tests (real Bionic installation and real chat model; mandatory per requirements section J rule 2):
  AM-T-014, AM-T-015 (false-recall - the most important), AM-T-016, AM-T-017, AM-T-018, AM-T-019, AM-T-020 (false-GO: historical GO text in memory does not authorize a gated action), AM-T-021, AM-T-022, AM-T-023, AM-T-024 (manual bootstrap; hook existence UNVERIFIED - the test proves the design works WITHOUT assuming any hook), AM-T-025 (no-change turn = zero model calls, zero writes), AM-T-030 (cross-chat), AM-T-031 (compaction/handoff recovery), AM-T-032, AM-T-034, AM-T-035, AM-T-036, AM-T-037, AM-T-038, AM-T-039, AM-T-040, AM-T-042 (candidate invisibility before PASS: the live case asserts that a normal client never writes canonical files and never observes a not-PASSed generation; no direct canonical-file write by the normal client), AM-T-043.
  Reclassification (carried from revision 0.2/0.3, unchanged): AM-T-020 / AM-T-025 / AM-T-042 are live behavioral because each acceptance case asserts CHAT-AI behavior in a live turn; their machine-testable halves remain in the selftest suite as sub-cases.
- Acceptance state rules (inherited verbatim from requirements section J): selftests do not establish live acceptance; unexecuted tests are `UNVERIFIED`, never `PASS`; P1 release status stays non-operational until every P1 requirement has traceable evidence and every mandatory live behavioral test passes.

---

# D10. Installation, rollback, backup, migration, operator instructions

## D10.1 Installation (implementation phase, after its own GO)

Step order is normative (revision 0.3, unchanged): the pre-implementation backup is FIRST - before ANY production change, including the placement of tool files.

1. PRE-IMPLEMENTATION BACKUP (before all production changes): create the backup ZIP in `shared/` containing: live `policy/bionic-policy.md`, the live user-checkpoint Skill, any other file this implementation will touch, each file's path + SHA256 + dated restore steps. Verify the ZIP after creation (read the manifest back; hash each member against the recorded SHA256). Do not proceed on an unverified ZIP.
2. Place `memory-tool.ps1` + `test-memory-tool.ps1` into `workspace/tools/memory-tool/`.
3. Run the machine selftest suite; all machine-class tests PASS.
4. Add the `MEMORY_RULE` clause to `policy/bionic-policy.md` (separate explicit user GO; dated; change history entry).
5. First `Commit` uses the sole `initialize` operation, a new operation_id, and empty base expected (generation 0 / ABSENT). It creates `.gen/000001/`, writes the generation-1 CURRENT record, and atomically writes the first ACTIVE durable PASS receipt.
6. Verify bootstrap: ACTIVE receipt/STATE binding validates; core.md is readable and <=4 KiB; Status reports operation identity and storage metrics.

## D10.2 Rollback

- Uninstall: delete `tools/memory-tool/`; remove the `MEMORY_RULE` clause; move `memory/` to an out-of-root backup location if retention is desired. checkpoint-guard, all existing policy rules, and the start skill are untouched at every point (AM-T-043).
- State rollback: operator action (D10.4): the machine copies the contents of a retained prior generation into a NEW generation through the normal commit protocol (new id, full staged verification, switch). The retained generation is never mutated in place. Because P1 performs no auto-pruning, every completed generation is an available rollback target until the operator explicitly deletes it.
- Pre-implementation ZIP rollback: restore policy/skill files from the ZIP (created at D10.1 step 1, before any change).

## D10.3 Backup

- Machine-managed: generation retention = ALL completed generations (no automatic pruning in P1, D1.1). These snapshots are the backup.
- Human-managed: the pre-implementation ZIP (D10.1 step 1).

## D10.4 Operator instructions

- Crash aftermath, `stale_generation_cleaned:<n>` diagnostic: a never-visible staging remnant was removed; canonical state is intact.
- `FAILED` with `staged_verify_failed`: the switches did not happen; ACTIVE and CURRENT are unchanged; the AI reports the failure; the user decides (correct spec / abort). No operator action on memory/.
- `FAILED postswitch_rollback`: CURRENT was restored and the never-ACTIVE candidate removed/quarantined; ACTIVE remained the prior PASS state.
- `pending_operation:<id>`: read-only state remains the prior ACTIVE. The AI asks the user to choose exact retry or explicit AbortPending. Different writes return STALE and do not adopt or discard the pending candidate.
- `pending_aborted:<id>`: the user explicitly chose to discard the never-PASSed candidate; ACTIVE and every completed generation were unchanged.
- `idempotent_pass_recovered`: ACTIVE or `receipts/<operation_id>.pass` proves the original write reached durable PASS; report the recovered historical success and do not submit a replacement write. If its old snapshot was manually deleted, do not imply that the old content remains readable or rollback-capable.
- `UNVERIFIED active_switch_outcome_unknown`: do not delete or write further. Inspect ACTIVE, CURRENT, and referenced STATE under explicit operator diagnosis; never infer success.
- UNVERIFIED with a STATE/hash mismatch on the ACTIVE generation (post-PASS damage): read the diagnostics; roll back to a retained prior generation (D10.2) on EXPLICIT USER DECISION, then Validate. This content-repair path is the only "restore" in this design; it is never automatic (no-auto-restore principle, unchanged from revision 0.3).
- Manual retention management: P1 performs no completed-generation deletion. Status reports measured totals. Any deletion is an explicit out-of-band action outside the machine safety guarantee because P1 has no reader lease. The operator must verify no reader uses the target, never delete ACTIVE/CURRENT, and preserve at least the preceding PASS generation. Historical `receipts/*.pass` files are NOT deleted with snapshots: they are the small independent PASS ledger. Deleting a generation removes its readable content and rollback value, but exact retry can still report the historical PASS from its receipt. Receipt deletion/compaction requires a separate future design and is not a routine P1 operation. P2 should replace manual snapshot deletion with proved lease-aware cleanup.
- Manual bootstrap (hook existence UNVERIFIED, design is hook-independent; AM-C-007, AM-F-033): user says "boot memory" (or equivalent) -> AI reads ACTIVE once, reads core.md of that generation + runs Status -> short report.
- Forget / restore: via machine modes with the record id; the AI reports the machine status line.

## D10.5 Migration

None in P1 (no prior version, single PC, single workspace root, AM-C-008). Schema evolution is a future major version with an explicit migration test before adoption.

---

# D11. Threat and failure matrix

| # | Threat / failure | Design mitigation | Primary test |
|---|---|---|---|
| 1 | Path escape via pointer (`..`, absolute, drive, symlink/reparse) | pointer whitelist: NOTE pointers in note_pointer, inside the generation notes/ only (own id); EVIDENCE pointers (source_pointer) relative under workspace root only; reparse targets rejected (AM-N-009, D2.8) | AM-T-003 |
| 2 | Malformed text (BOM, invalid UTF-8, truncated line, note hash mismatch) | strict UTF-8-no-BOM decode; per-line field validation (10 fields); NOTE bodies hash-listed in STATE and verified (D2.5); malformed = UNVERIFIED/INVALID without state change (AM-N-010) | AM-T-002, 004 |
| 3 | Stale, duplicate, or operation-id-confused write | exclusive writer lock + CAS + mandatory operation_id/spec hash; O(1) deterministic receipt path; same id/different bytes INVALID; exact retry returns durable prior PASS; stale base cannot overwrite newer ACTIVE | AM-T-007 + idempotency sub-cases |
| 4 | Partial write / crash in any transition window | full snapshot disk verification; CURRENT is reader-invisible; only exact retry may finish pending; unrelated writes stop; only explicit AbortPending discards; ACTIVE is atomic durable PASS receipt | AM-T-006 fault matrix |
| 5 | Mixed-generation read | readers validate ACTIVE once and read one immutable generation; ACTIVE binds generation and STATE hash in one atomic receipt | AM-T-005, 006 |
| 6 | Reader-input deletion (long-running deep job loses its input files; the revision-0.3 mtime guard is defeated by two commits - D5 proof 4 counterexample) | NO automatic pruning of completed generations in P1 (D1.1); remnant cleanup is restricted to never-ACTIVE unvalidated directories (invariant R3, D5 proof 4); manual retention management is an explicit operator action (D10.4) | AM-T-028 (retention sub-case), AM-T-018 (deep job completion sub-case) |
| 7 | Prompt-like memory content ("ignore instructions", embedded GO) | memory = UNTRUSTED runtime evidence; machine rejects forbidden authorization fields; L2 firewall governs semantics; memory never grants authority (AM-F-027/028) | AM-T-020, 021 |
| 8 | False GO from memory | as #7 + existing false-GO firewall / AUTHORIZATION_UNKNOWN; GO_SOURCE = current conversation only (unchanged) | AM-T-020 |
| 9 | False recall (pretraining completion as "memory") | MISS -> "no record"; general knowledge only separately labelled; citations mandatory (AM-F-013, AM-I-015) | AM-T-015 |
| 10 | Unavailable dependency (offload/API down, model unloaded) | deep recall is a MAY path; failure -> BLOCKED/FAILED report; fast recall unaffected (AM-C-005) | AM-T-018 |
| 11 | Deep-recall input blowup (unbounded archive/notes) | deep input scope = ACTIVE generation files only; 256 KiB budget -> BLOCKED deep_input_exceeds_budget; fast recall unaffected (D7) | AM-T-018 (budget sub-case) |
| 12 | Deep-OUT format collision (pipe inside evidence fragment corrupting the CAND line) | task rule: evidence must be a no-pipe verbatim span (choose another span if needed); machine FilterDeepOut accepts only EXACTLY-5-field CAND lines, drops 6+ field lines as malformed (counted) (D7) | AM-T-018 (filter sub-cases) |
| 13 | Unbounded AI reading of deep OUT into chat context | raw OUT is never read by the AI; machine narrows to <=3 lines locally first (FilterDeepOut, D7) | AM-T-018 (filter sub-cases) |
| 14 | Byte explosion (long summaries, note growth) | per-line field caps + per-file byte bounds + FIFO on bytes (AM-N-001..004) | AM-T-010, 011, 026 |
| 15 | Archive growth leaking into normal cost | archive is a separate file never read at bootstrap/fast recall (AM-N-011) | AM-T-028 |
| 16 | Unbounded AI scanning / over-read | corpus bounds (core+index only), note caps, 2-note rule, 2-recall-call rule (AM-N-004, AM-I-013) | AM-T-013, 026 |
| 17 | Unbounded/cumulative disk growth from full snapshots | explicitly documented: archive/note count and total retained bytes are not P1-bounded and worst-case cumulative growth may be approximately quadratic; Status reports independent byte/generation metrics; no automatic deletion; P2 lease-aware pruning or content-addressed notes requires review | AM-T-028 + storage-metric sub-cases |
| 18 | PASS acknowledgement lost after durable commit | ACTIVE stores operation_id/spec hash/STATE hash/RESULT=PASS; before later replacement its exact bytes are archived at the deterministic operation-id receipt path; exact retry reconstructs the same PASS and cannot duplicate the transition | AM-T-006/007 idempotency sub-cases |
| 19 | External evidence disappears after original commit | add/restore require existence; carried records remain structurally valid with `evidence_status=dangling`; unrelated writes are not blocked; AI lowers certainty and reports unresolved source | AM-T-003/014 lifecycle sub-cases |
| 20 | Receipt ledger conflict or torn archival window | create-new immutable operation-id path; exact byte comparison; byte-identical ACTIVE/history copies are one logical receipt; any non-identical/malformed copy fails UNVERIFIED without overwrite; fault injection before/after archival | AM-T-006/007 receipt sub-cases |

---

# D12. Traceability matrix (one line per P1 requirement; design locations updated through revision 0.5)

Upstream: requirements v0.3 `UR-001..008` -> `AM-F/N/C/I-*` (mapping is in the requirements document, sections E-H). Every P1 `AM-F`/`AM-N` (priority P1 in requirements sections E/F) plus every `AM-I` (interface contract) and `AM-C` (constraint) appears in exactly one row. Evidence state is `UNVERIFIED` for every row: nothing is implemented or executed at design time.

Non-P1 roadmap items `AM-F-025` (P2 secure purge) and `AM-F-026` (P3 model-assisted defragmentation) are intentionally excluded from this P1 implementation matrix; D3.7 records the former boundary and the frozen requirements remain their authority.

| ID | Design location | Planned implementation artifact | Test ID(s) | Evidence state |
|---|---|---|---|---|
| AM-F-001 | D8.5, D3.4, D3.5 | MEMORY_RULE clause 5+6; memory-tool.ps1 Commit | AM-T-035 | UNVERIFIED |
| AM-F-002 | D8.5 | MEMORY_RULE clause 5 | AM-T-032 | UNVERIFIED |
| AM-F-003 | D8.5 | MEMORY_RULE clause 5 | AM-T-037 | UNVERIFIED |
| AM-F-004 | D8.5 | MEMORY_RULE clause 5 | AM-T-038 | UNVERIFIED |
| AM-F-005 | D8.5, D1.2 | MEMORY_RULE clause 5 | AM-T-036 | UNVERIFIED |
| AM-F-006 | D3.4 (spec fields) | memory-tool.ps1 Commit (spec validation) | AM-T-035 | UNVERIFIED |
| AM-F-007 | D1.1 (writer table), D2.4, D3.4, D3.5 | memory-tool.ps1 as sole canonical writer | AM-T-005, 042 | UNVERIFIED |
| AM-F-008 | D3.2, D3.3 | memory-tool.ps1 stdout; MEMORY_RULE clause 6 | AM-T-023, 035 | UNVERIFIED |
| AM-F-009 | D8.2 | MEMORY_RULE clause 2 | AM-T-039 | UNVERIFIED |
| AM-F-010 | D6 | memory-tool.ps1 Recall | AM-T-013 | UNVERIFIED |
| AM-F-011 | D6 (AI usage), D1.2 J3 | MEMORY_RULE clause 3 | AM-T-014 | UNVERIFIED |
| AM-F-012 | D3.3 (HIT behavior), D3.2 (candidate fields) | MEMORY_RULE clause 3 | AM-T-016 | UNVERIFIED |
| AM-F-013 | D3.3 (MISS), D6 | MEMORY_RULE clause 3 | AM-T-015 | UNVERIFIED |
| AM-F-014 | D3.1 (Status mode) | memory-tool.ps1 Status | AM-T-040 | UNVERIFIED |
| AM-F-015 | D7 (trigger, mechanism) | MEMORY_RULE clause 4; offload job-spec composition | AM-T-018 | UNVERIFIED |
| AM-F-016 | D7 (result handling, gate failure, evidence verification) | MEMORY_RULE clause 4 | AM-T-018, 019 | UNVERIFIED |
| AM-F-017 | D7 (trigger: miss SHALL NOT auto-invoke) | MEMORY_RULE clause 4 | AM-T-017 | UNVERIFIED |
| AM-F-018 | D2.1 (memory_id), D3.7 | memory-tool.ps1 id assignment / Restore | AM-T-008 | UNVERIFIED |
| AM-F-019 | D2.1 (tags rule) | memory-tool.ps1 validation | AM-T-008 | UNVERIFIED |
| AM-F-020 | D2.1 (supersedes_id), D3.5 step 9 | memory-tool.ps1 Commit | AM-T-009 | UNVERIFIED |
| AM-F-021 | D3.5 step 10 (FIFO) | memory-tool.ps1 Commit | AM-T-011 | UNVERIFIED |
| AM-F-022 | D3.7 (Forget) | memory-tool.ps1 Forget | AM-T-012 | UNVERIFIED |
| AM-F-023 | D3.7 (Restore), D2.3 (recoverable archive) | memory-tool.ps1 Restore | AM-T-012 | UNVERIFIED |
| AM-F-024 | D1.2 (AI stability classification), D3.5 step 9 (machine bounds only), D8.5b (pin discipline) | MEMORY_RULE clause 5b; memory-tool.ps1 Commit | AM-T-010 | UNVERIFIED |
| AM-F-027 | D1.3 (authority order), D8 clauses 1/8/9, D11 #7/#9 | MEMORY_RULE; recall reporting | AM-T-019, 021, 031 | UNVERIFIED |
| AM-F-028 | D2.6 (forbidden authorization fields), D8 clauses 1/5/9, D11 #7/#8 | memory-tool.ps1 validation; existing L2 firewall | AM-T-020, 032 | UNVERIFIED |
| AM-F-029 | D1.3, D8 clause 8 | MEMORY_RULE conflict reporting | AM-T-021 | UNVERIFIED |
| AM-F-030 | D1.3, D8 clauses 1/9, D10.1/D10.2 | unchanged Bionic policy/checkpoint guard + MEMORY_RULE | AM-T-021, 031, 043 | UNVERIFIED |
| AM-F-031 | D3.3 (UNVERIFIED), D3.6, D8 clause 7 | bounded ACTIVE direct-read fallback | AM-T-022 | UNVERIFIED |
| AM-F-032 | D3.3 (BLOCKED/FAILED/UNVERIFIED), D8 clauses 6/7 | fail-closed write client + memory-tool.ps1 | AM-T-023 | UNVERIFIED |
| AM-F-033 | D8 clause 2, D10.4 manual bootstrap | MEMORY_RULE manual bootstrap | AM-T-024 | UNVERIFIED |
| AM-F-034 | D1.1 (one configured shared workspace root), D8 clause 1 | workspace memory root | AM-T-030 | UNVERIFIED |
| AM-F-035 | D1.2 J9, D1.3, D8 clauses 1/8/9 | MEMORY_RULE + existing checkpoint routing | AM-T-021, 031 | UNVERIFIED |
| AM-N-001 | D2.1/D2.2 bounds, D3.5 steps 9-10 | memory-tool.ps1 validation | AM-T-010, 039 | UNVERIFIED |
| AM-N-002 | D3.5 step 10 | memory-tool.ps1 Commit | AM-T-011 | UNVERIFIED |
| AM-N-003 | D2.4, D2.5 | memory-tool.ps1 validation | AM-T-002 | UNVERIFIED |
| AM-N-004 | D6 (AI usage bound), D8.3 | MEMORY_RULE clause 3 | AM-T-026 | UNVERIFIED |
| AM-N-005 | D6 (deterministic, model-free; P95 FAIL rule) | memory-tool.ps1 Recall (timed) | AM-T-027 | UNVERIFIED |
| AM-N-006 | D8.5 (trigger restriction), D3.6 | MEMORY_RULE | AM-T-025, 036 | UNVERIFIED |
| AM-N-007 | D2.9, D3.5 (staged verify + CURRENT pending pointer + ACTIVE durable PASS receipt + immutable receipt history + exact-retry recovery/rollback; no in-place modification), D5 proofs 3,4 | memory-tool.ps1 write engine | AM-T-006 | UNVERIFIED |
| AM-N-008 | D3.5 (lock+CAS), D5 proof 2 | memory-tool.ps1 commit protocol | AM-T-007 | UNVERIFIED |
| AM-N-009 | D2.1, D2.8, D3.1 (root params) | memory-tool.ps1 path checks | AM-T-003 | UNVERIFIED |
| AM-N-010 | D2.1/D2.4/D2.5 (UTF-8 no BOM declared), D3.5 | memory-tool.ps1 decode/reject | AM-T-001, 002, 004 | UNVERIFIED |
| AM-N-011 | D1.1 (archive separate), D6 (corpus) | memory-tool.ps1 Recall/Status | AM-T-028 | UNVERIFIED |
| AM-N-012 | D3.6 (no log file) | memory-tool.ps1 (stdout JSON only) | AM-T-029 | UNVERIFIED |
| AM-N-013 | D3.1 | memory-tool.ps1 (PS5.1, no daemon) | AM-T-033 | UNVERIFIED |
| AM-I-001 | D3.1 (six required capabilities + AbortPending + FilterDeepOut) | memory-tool.ps1 eight modes | AM-T-001, 040, 043 | UNVERIFIED |
| AM-I-002 | D3.2 | memory-tool.ps1 stdout JSON | AM-T-001, 041 | UNVERIFIED |
| AM-I-003 | D3.3 (8 statuses, no additions) | memory-tool.ps1 status vocabulary | AM-T-041 | UNVERIFIED |
| AM-I-004 | D3.6 (read-only, snapshot-scoped via ACTIVE receipt; pending reported without change; FilterDeepOut memory-root-free) | memory-tool.ps1 read modes | AM-T-013, 041 | UNVERIFIED |
| AM-I-005 | D2.9, D3.5 (complete proposed validation + stale detection + staged disk verification + post-CURRENT revalidation + immutable prior-receipt archival + durable ACTIVE PASS receipt) | memory-tool.ps1 write engine | AM-T-005, 006, 007 | UNVERIFIED |
| AM-I-006 | D3.5/D5 proof 1 (one immutable generation exposed by one ACTIVE receipt) | memory-tool.ps1 snapshot + ACTIVE receipt | AM-T-005, 006 | UNVERIFIED |
| AM-I-007 | D1.1, D2.9, D3.4, D3.5 (operation identity, durable PASS, immutable receipt history, exact retry), D5 proof 5 | MEMORY_RULE clause 6/7; memory-tool.ps1 write engine | AM-T-042 | UNVERIFIED |
| AM-I-008 | D2.1 (10-field schema; source_pointer = external evidence per AM-I-010; note_pointer added; all required fields exposed) | memory-tool.ps1 schema | AM-T-005, 035 | UNVERIFIED |
| AM-I-009 | D2.1 (id stable/unique) | memory-tool.ps1 id assignment | AM-T-008, 035 | UNVERIFIED |
| AM-I-010 | D2.1 (source_pointer = external evidence; '-' only for USER_STATED self-contained records; non-USER_STATED requires resolving evidence at commit time), D2.8 | memory-tool.ps1 pointer validation | AM-T-003 | UNVERIFIED |
| AM-I-011 | D2.4, D2.8, D3.5 steps 9/11 (note via note_pointer, same transition) | memory-tool.ps1 | AM-T-003, 005 | UNVERIFIED |
| AM-I-012 | D2.6 (forbidden tokens) | memory-tool.ps1 validation | AM-T-020 (machine sub-case), 032 | UNVERIFIED |
| AM-I-013 | D6 (candidates carry both pointers + evidence_status) | memory-tool.ps1 Recall | AM-T-013 | UNVERIFIED |
| AM-I-014 | D7 (machine FilterDeepOut narrows to <=3 EXACTLY-5-field candidates before any AI read; read-only path = no canonical write by construction) | memory-tool.ps1 FilterDeepOut; MEMORY_RULE clause 4 | AM-T-018 | UNVERIFIED |
| AM-I-015 | D3.2, D6 (candidate fields: id+pointers stable) | memory-tool.ps1 Recall; MEMORY_RULE clause 3 | AM-T-016 | UNVERIFIED |
| AM-I-016 | D3.3 (MISS vs UNVERIFIED) | memory-tool.ps1 status vocabulary | AM-T-015, 022 | UNVERIFIED |
| AM-C-001 | D3.1 (local PS5.1 host) | memory-tool.ps1 | AM-T-033 | UNVERIFIED |
| AM-C-002 | D1.1 (roots kept; generation/receipts layout = child refinement) | layout | AM-T-033 | UNVERIFIED |
| AM-C-003 | D1.1, D3.1 (file store only) | layout | AM-T-033 | UNVERIFIED |
| AM-C-004 | D3.1, D3.6 (no network/transcript) | memory-tool.ps1 | AM-T-029 | UNVERIFIED |
| AM-C-005 | D7 (failure handling, input budget, FilterDeepOut), D1.1/D5 proof 4 (deep inputs never pruned in P1) | MEMORY_RULE clause 4; memory-tool.ps1 retention behavior | AM-T-018 | UNVERIFIED |
| AM-C-006 | D3.1 (pattern reference, no dependency) | memory-tool.ps1 standalone | AM-T-043 | UNVERIFIED |
| AM-C-007 | D8.2, D10.4 (hook UNVERIFIED; hook-independent design) | MEMORY_RULE clause 2 | AM-T-024 | UNVERIFIED |
| AM-C-008 | D1.1 (single root params) | layout | AM-T-030 | UNVERIFIED |

Completeness check: every P1 `AM-*` id appears once above and maps to acceptance evidence. Revision 0.5 additions trace as follows: operation_id/spec hash + durable ACTIVE PASS + exact retry -> AM-I-005/006/007, AM-N-007/008, AM-T-006/007/042; no unrelated pending adoption -> AM-I-007 and verified-success reporting discipline; transition-scoped source existence -> AM-I-010/011, AM-F-011/012; measured storage totals/no bounded-storage claim -> AM-C-003, AM-N-011, AM-T-028. Accepted v0.4 CAND, pointer-role, canonical-copy, and no-auto-prune corrections remain in force.

---

# O. Open evidence items inherited (from requirements section L; design-side status)

| ID | Item | Design-side status |
|---|---|---|
| OE-001 | Bionic startup/compaction/handoff hook surface | UNVERIFIED (neither existence nor absence established). The design is hook-INDEPENDENT: no feature assumes a hook; manual bootstrap per D8.2 is the P1 mechanism (AM-F-033). No design change required. |
| OE-002 | Japanese lexical recall quality | UNVERIFIED; measured in live operation after P1; P2 improvement path reserved. |
| OE-003 | Cross-chat visibility of one workspace memory root | UNVERIFIED until AM-T-030 (live) executes; AM-T-030 has NOT been executed at design time, so no "proven" claim is made. Note: cross-chat within the same project workspace; cross-project is out of scope (AM-C-008). |
| OE-004 | Offload command/output contract and endpoint | CLOSED at design: contract read from `api-context-offload/SKILL.md` (2026-10-06); endpoint/model source = `policy/api-context-offload-facts.md` (OBSERVED). Re-verify at implementation if the facts file changed. |
| OE-005 | Practical archive/generation growth rate | UNVERIFIED until implementation/operation. v0.5 removes the false small-generation implication: full snapshots can reach MiB+ and cumulative retained bytes may grow approximately quadratically. Status metrics provide evidence; no P1 automatic pruning claim is made. |
| OE-006 | Windows PowerShell 5.1 implementation of same-volume atomic create/replace, file flush, directory initialization, and fault-injection seams | UNVERIFIED at basic-design time. Qwen's next role is a read-only implementation-feasibility audit using the actual Bionic host and authoritative platform documentation. Any blocker returns to ChatGPT/Codex design; no implementation starts during the audit. |

---

# P. Design-phase report (per requirements reporting discipline)

- OBSERVED: requirements v0.3 remains APPROVED/SCOPE FROZEN with SHA256 `5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A`; v0.4 canonical/mirror hashes were verified equal before v0.5 work; production policy, memory, checkpoint, and tools were not changed. The older false v0.2 hash claim remains retracted in AUTHORITY.
- INFERRED: Japanese substring recall hit rate (OE-002); P95 2.0s achievability on the target PC (AM-T-027 will measure; FAIL rule per D6); cross-chat visibility (AM-T-030 will prove); disk-growth magnitude under no-auto-pruning (bounded by commit rate; exact growth unmeasured - P1 accepted tradeoff, D11 #17).
- UNVERIFIED: Bionic hook surface; practical storage-growth rate; all D1-D12 behavioral claims until selftest/live execution; PowerShell 5.1 atomic-replace/flush and fault-injection feasibility until Qwen's read-only implementation-feasibility audit.
- PROPOSED: all of D1-D12 (revision 0.5), pending user review and Qwen read-only feasibility audit; scope freeze remains HOLD and implementation remains prohibited.
- NOT STARTED: implementation (memory-tool.ps1, memory/, MEMORY_RULE) - requires a separate explicit user GO after scope freeze and test-first.
- This document does not modify production policy, memory, checkpoint, or tool files.


---

## DISTRIBUTION SCOPE ADDENDUM (2026-10-12)

This section is a distribution addendum of the portable Core package (bamp1-portable, 2026-10-12).
It does not change the frozen body above. It defines the distribution scope.

1. Core scope: retain / fast recall / lifecycle (supersede / forget / restore) / status / validate /
   write and integrity mechanism. In addition, the tool-side FilterDeepOut mode (pure file filter,
   no offload needed, machine-tested; runner Group F = AM-T-018.a-i) is included in this distribution.
2. Out of scope: the deep recall execution path (01 D7 api-context-offload mechanism, strong-model
   candidate generation) / live behavior depending on the source environment L0-L3 discipline /
   real-compaction-dependent cases.
3. Relation to the original specification: 01 D7/D8 clauses 4/9 and REQ AM-F-015..017 / AM-I-014 /
   AM-C-005 / AM-T-018..019 (live) are kept verbatim (frozen) in the body but are NOT provided in this
   distribution. Deep recall is conditioned on the capability being verified available (REQ AM-F-015);
   in the distribution target it is not provided = report as unavailable (BLOCKED) on explicit request
   (no fabrication, no substitute).
4. Requirement/test handling in this distribution: machine 95 cases (runner, incl. FilterDeepOut group)
   = execution target (distribution selftest). The 24 LIVE_BEHAVIORAL cases of 04 are the source
   environment acceptance suite; in the distribution target only the PROCEDURE.md minimal live check
   (fresh-chat probe) is executed. offload-dependent (018/019), L0-L3-dependent and real-compaction
   dependent IDs are recorded NOT_RUN in the distribution target.
5. This addendum is identical across all distributed documents (REQ / 01..05).

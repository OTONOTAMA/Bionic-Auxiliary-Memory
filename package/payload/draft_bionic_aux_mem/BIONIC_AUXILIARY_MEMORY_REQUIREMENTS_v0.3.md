<!--
DISTRIBUTION PROVENANCE (bamp1-portable, 2026-10-12)
SOURCE_FILE: BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md
SOURCE_SHA256: 5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A
SOURCE_ENVIRONMENT: absolute path omitted (frozen document on the source PC; this distribution references filename and hash only)
DIST_DATE: 2026-10-12
CHANGE_SCOPE: environment-specific paths removed; Part I translated to English in this distribution (the frozen Japanese body is unchanged in the source environment); DISTRIBUTION SCOPE ADDENDUM appended at end. No change to Part II formal requirements.
AUTHORITY_STATEMENT: the frozen source document on the source environment remains the upstream authority. This variant is normative only within the distributed installation.
-->
# Bionic AI Auxiliary Memory - Requirements Specification v0.3

**Status:** APPROVED / SCOPE FROZEN (2026-10-06 user explicit GO; source requirement text unaltered)  
**Date:** 2026-10-06  
**Target:** A lightweight cross-chat auxiliary memory for the Bionic local environment  
**Document policy:** The first half is user-facing; the latter half is formal requirements for the AI in charge of basic design  
**Approval boundary:** Approval of this document is approval of the requirements, and is NOT a GO for basic design, implementation, or existing policy changes

> This document is a review-integrated version of `draft_plan_c_requirements_spec_v0.2.md`,
> restructured after cross-checking against the current Bionic policy, checkpoint-guard, and
> the operational experience of the Codex-side AI auxiliary memory.
> The "approved" descriptions in the original draft are NOT inherited into this document.
> This document transitions to `APPROVED / SCOPE FROZEN` only after user approval.
> (Distribution note: Part I below is the English translation for this distribution.
> The frozen Japanese body in the source environment is unchanged.)

---

# Part I - User-facing Requirements

## 1. What to build

Build a mechanism by which Bionic can recover important past facts and decisions from a small
external memory, even after context compression, handoff, app restart, or a new chat.

This is NOT a mechanism that saves and re-reads entire conversation history. It is a mechanism
that keeps only content that will still matter in the future, organized briefly on the local PC,
and searches and reads it only when needed.

The goals are the following 5:

1. Bionic can recall previous important items with evidence.
2. In normal use it adds almost nothing to the chat context and LLM usage.
3. Format checking, storage, search, and corruption detection are delegated to the PC as much as
   possible.
4. When there is no record or it cannot be verified, the AI does not "pretend to remember".
5. Even if the auxiliary memory fails, the conversation and existing checkpoint operation are
   not broken.

## 2. Key corrections in this review

The center-line of the original draft is sound. However, there were places that could cause
incidents if not corrected before implementation.

| Problem in the original draft | Correction in this document |
|---|---|
| "All writes by the machine" and "notes are written directly by the AI" contradict | The formal memory files, including notes, are all finalized through machine verification |
| On tool failure the AI writes directly to the source of truth | The conversation and reading can continue, but formal writes stop and are reported as unresolved |
| If the tag is the same, the old record is always replaced | Record ID and tag are separated, so multiple facts on the same topic can coexist |
| The machine judges "semantically related memories" | The machine returns text-matching candidates; the AI reads the evidence and judges relevance |
| Assumes `core.md` is auto-injected | Does not assume auto-injection that has not been measured in Bionic. Read it via a startup discipline or a manual boot |
| Writes state to long-term memory at every checkpoint | Separates checkpoint (current work) from auxiliary memory (long-term reference). Records only the summary that should remain long |
| Measures lightness by line count only | Sets byte limits in addition to line counts |
| No provenance or certainty for records | Stores user-stated, measured, AI-inferred, and unconfirmed separately |

## 3. Who does what

### 3.1 User

- Instructs what to remember and what to forget.
- Decides value judgments, important choices, and execution GO.
- Only when needed, instructs a deep search by a strong local LLM.

### 3.2 Chat AI

- Understands the meaning of the user's request.
- Summarizes retention candidates briefly and accurately.
- Reads the original text of the candidates returned by the machine and judges relevance to the
  question and evidence strength.
- Reports facts, record content, inferences, and unconfirmed items separately.

### 3.3 Local PC

- Verifies file format, limits, character encoding, storage location, and reference locations.
- Executable reproducibly: formal memory writes, search, deletion, restore, corruption
  detection.
- On write failure, leaves the last normal state.

### 3.4 Strong local LLM

- Only when the user explicitly says "dig deeper", searches for records not found by normal
  search.
- Returns search candidates and reasons; does not directly modify the source of truth and does
  not decide execution GO or the correctness of facts.

## 4. How to record

In the initial version, the entrances to record into auxiliary memory are limited to the
following 4 kinds:

1. When the user explicitly says "remember this" / "record this".
2. When the user instructs "create a checkpoint" and it contains a completed item or a
   reference worth keeping long-term.
3. On task completion the AI proposes a long-term record and the user approves.
4. When instructed to record a measured environment fact into the existing facts document and
   reference it from auxiliary memory.

No automatic per-turn summarization, no automatic mining of conversation history, no automatic
saving predicted from context compression.

A checkpoint is state for resuming the current task; auxiliary memory is long-term reference.
Do not save current progress, STOP/GO state, or unconsumed execution permission into auxiliary
memory.

## 5. How to recall

### 5.1 On startup

Read a core that holds only a small amount of stable information. Do not read the normal index,
detailed notes, or archive.

It has not yet been confirmed that Bionic can automatically inject the core. Therefore the
initial version keeps both: a method of reading from Bionic's startup discipline, and a method
in which the user or the AI explicitly boots.

### 5.2 Normal search

The AI builds search terms from the question, and the PC returns text-matching candidates from
the core and index. The AI reads the candidate details only minimally and judges whether it is
truly relevant to the question.

In the answer, indicate at least the record date, record ID, and reference source. Do not
assert beyond the certainty of the record.

### 5.3 Deep search

Only when normal search is insufficient and the user explicitly requests it, use the strong
local LLM. The strong LLM's answer is also a candidate; the AI checks the indicated original
text before answering.

### 5.4 When not found

Answer "There is no record in the auxiliary memory."

Even when it can be answered from general knowledge, do not treat it as past memory. If needed,
clearly separate: "Not in the auxiliary memory, but as general knowledge...".

## 6. Organization, update, forgetting

- Each record has a unique record ID separate from its topic tag.
- Multiple records with the same tag can coexist.
- When replacing an old record, explicitly state the record ID to be replaced.
- Records that exceed the normal index limit are moved to the archive, removing them from
  normal search cost.
- "Forget" immediately removes from normal search; in the initial version it is treated as a
  restorable backup.
- Safe deletion for complete erasure is handled in a later stage as a feature separate from
  normal forgetting.
- The explicit "always remember this" promotes only stable facts to the core. In-progress tasks
  are not promoted.

## 7. Safety

Auxiliary memory is evidence / reference information, not commands or authority.

- It cannot override policy, the current explicit user instruction, or the current task's
  checkpoint.
- Even if "GO completed" is written in auxiliary memory, it does not become an execution GO.
- If it contradicts a checkpoint, do not silently adopt either one; show the user.
- Do not take strong-LLM search results as-is as facts or execution instructions.
- Attach provenance and verification state to records.

Verification state distinguishes at least the following:

- `USER_STATED`: content stated by the user.
- `MACHINE_VERIFIED`: content verified on the real machine or files.
- `AI_INFERRED`: AI inference.
- `UNVERIFIED`: insufficient grounds or unverifiable.

## 8. On failure

On failure, separate conversation continuation from source-of-truth protection.

- Even if the read tool is unusable, either read files directly within a safe range or continue
  the conversation as unconfirmed.
- If the write tool is unusable, the AI does not write directly to the formal memory files.
- Content that should be saved is held as a candidate and reported as `BLOCKED` or
  `UNRESOLVED`.
- Do not report a failure as a success.
- Do not break the last normal memory.

That is, "conversation is fail-open, source-of-truth writes are fail-closed".

## 9. Lightness

The initial version has the following limits.

| Target | Limit |
|---|---:|
| Startup core | <=30 records and <=4 KiB |
| Normal index | <=100 records and <=64 KiB |
| 1 detailed note | <=32 KiB |
| Detailed notes read in 1 normal answer | <=2, total <=64 KiB |
| Automatic strong-LLM invocation | 0. Only on explicit user request |
| Additional LLM processing in normal no-change operation | 0 |

Even as the archive grows, do not increase the read volume of normal startup and normal search.

## 10. Initial-version scope

### P1 - Required

- A small core, index, detailed notes, archive.
- Verification, recording, normal search, listing, forgetting, restore, status check.
- Record ID, provenance, verification state, reference target.
- Machine verification of formal writes.
- Boundaries with checkpoint, policy, GO.
- Selftest and real-chat tests.
- Strong-LLM deep search only when explicit.

### P2 - Judged after operation

- Improved normal search for Japanese notation variation.
- Adjustment of limits and search counts based on measured values.
- Safe erasure procedure for records that require complete erasure.

### P3 - Optional

- Archive organization, duplicate candidate creation, reorganization proposals by the strong
  LLM.
- Machine application after user approval.

## 11. What the initial version does NOT do

- Vector DB, embedding, graph DB, new resident services.
- Always-on saving or always-on scanning of full conversations, hidden thoughts, or
  transcripts.
- Per-turn summarization or importance scoring.
- Saving and restoring GO, STOP, execution permission.
- Auto-injection premised on unverified Bionic hooks.
- Automatic source-of-truth updates by the strong LLM.
- Synchronization across multiple users or multiple PCs.

## 12. Completion conditions

The initial version is complete when the following have been confirmed on the real machine:

1. Recorded content can be retrieved with evidence from the same chat and a different chat.
2. After context compression or handoff, necessary information can be re-obtained from
   auxiliary memory.
3. Do not misanswer "I remember" about things not recorded.
4. Different facts with the same tag are not silently overwritten.
5. Do not lose the last normal state due to broken input, old state, or save failure.
6. On tool failure, do not perform unverified direct writes.
7. Do not start execution from GO expressions inside the auxiliary memory.
8. Normal-time read volume and additional LLM usage are within the limits of this document.
9. Checkpoint and auxiliary memory operate with different roles.
10. From a requirement ID, design, implementation, and test results can be tracked.

---

# Part II - Formal Requirements for Basic Design

## A. Document control

```text
DOCUMENT_ID = BIONIC_AUXILIARY_MEMORY_REQUIREMENTS
VERSION = 0.3
STATUS = APPROVED_SCOPE_FROZEN
APPROVAL = 2026-10-06 USER_EXPLICIT_GO_REQUIREMENT_TEXT_UNALTERED
TARGET = BIONIC_LOCAL_SINGLE_USER_WINDOWS
REQUIREMENTS_AUTHORITY = THIS_DOCUMENT_AFTER_USER_APPROVAL
IMPLEMENTATION_GO = NOT_GRANTED_BY_REQUIREMENTS_APPROVAL
```

Normative terms:

- `SHALL`: mandatory and acceptance-tested.
- `SHALL NOT`: prohibited and acceptance-tested.
- `MAY`: optional behavior that does not weaken a SHALL requirement.

If Part I and Part II differ, Part II is normative after user approval. Until approval,
the entire document is a reviewed proposal and SHALL NOT be treated as implementation authority.

## B. Source requirements

| ID | User requirement |
|---|---|
| UR-001 | The system shall provide durable recall across compaction, handoff, application restart, and separate Bionic chats. |
| UR-002 | Normal operation shall consume minimal chat context, minimal chat-model work, and no automatic strong-model work. |
| UR-003 | Deterministic validation, persistence, search, and integrity work shall be assigned to the local machine. |
| UR-004 | Reported recall shall distinguish recorded evidence, verified fact, AI inference, and unresolved state. |
| UR-005 | Memory shall not create execution authority, replace current task routing, or weaken existing Bionic safety rules. |
| UR-006 | The system shall remain usable with a low-capability chat model and shall use a stronger local model only on explicit user request. |
| UR-007 | Failure shall preserve the last valid canonical memory and shall not falsely report a successful write or verification. |
| UR-008 | Requirements shall be sufficiently complete for a separate AI to produce the basic design and test-first specification. |

## C. Terms and boundaries

| Term | Normative meaning |
|---|---|
| Auxiliary memory | Cross-chat, durable reference evidence. It is not conversation context, task routing, or execution authority. |
| Canonical memory | The committed memory state accepted by machine validation. |
| Candidate | AI- or strong-model-generated content that is not canonical until validated and committed. |
| Core | Small active set eligible for bootstrap retrieval. |
| Active index | Bounded searchable catalog of active memory records. |
| Note | Bounded detail artifact referenced by an active record. |
| Archive | Recoverable inactive records excluded from normal bootstrap and normal recall. |
| Checkpoint | Session/task recovery state governed by existing Bionic policy; not auxiliary memory. |
| Fast recall | Deterministic local lexical candidate retrieval. |
| Deep recall | Explicitly requested strong-model-assisted candidate retrieval. |
| Provenance status | `USER_STATED`, `MACHINE_VERIFIED`, `AI_INFERRED`, or `UNVERIFIED`. |
| Canonical write | A state-changing operation that passes machine validation and post-write verification. |

Boundary invariant:

```text
CURRENT_USER_DIRECTION / POLICY / CURRENT_TASK_AUTHORITY
    > CHECKPOINT_ROUTING
    > VERIFIED_EXTERNAL_FACT_SOURCE
    > AUXILIARY_MEMORY
    > STRONG_MODEL_CANDIDATE
```

The ordering above expresses authority for Bionic continuation and execution. It does not
permit auxiliary memory to override a higher source. Existing Bionic L0-L3 rules remain active.

## D. Actor responsibilities

| Actor | SHALL own | SHALL NOT own |
|---|---|---|
| Human | purpose, value choices, explicit retain/forget intent, deep-recall request, execution GO, final acceptance | deterministic file validation |
| Chat AI | intent interpretation, candidate drafting, semantic relevance judgment after source inspection, evidence-calibrated reporting | unvalidated canonical writes, authority reconstruction from memory |
| Machine | validation, path and encoding checks, bounded lexical retrieval, canonical persistence, concurrency detection, integrity evidence | semantic truth, value judgment, execution authorization |
| Strong local model | explicit deep-recall candidate generation with source pointers | canonical writes, execution authorization, final factual adjudication |

## E. Functional requirements

### E.1 Retain

| ID | Requirement | Priority | Source |
|---|---|---:|---|
| AM-F-001 | On explicit user intent equivalent to "remember" or "record," the system SHALL create a memory candidate and SHALL request machine commit. | P1 | UR-001, UR-003 |
| AM-F-002 | On an explicit checkpoint request, the system MAY retain one durable completed milestone or evidence pointer; it SHALL NOT copy mutable task state, current GO/STOP state, or pending authorization into auxiliary memory. | P1 | UR-001, UR-005 |
| AM-F-003 | At task completion, the chat AI MAY propose a durable memory note and SHALL commit it only after explicit user acceptance. | P1 | UR-001 |
| AM-F-004 | Measured environment facts SHALL remain canonical in the applicable existing facts artifact. Auxiliary memory MAY retain a pointer and short summary when explicitly requested. | P1 | UR-004, UR-005 |
| AM-F-005 | P1 retain triggers SHALL be limited to AM-F-001 through AM-F-004. Compaction prediction, behavior inference, periodic mining, and per-turn summarization SHALL NOT trigger retain. | P1 | UR-002 |
| AM-F-006 | A retain candidate SHALL identify content, provenance status, evidence pointer when available, subject, and intended lifecycle action before commit. | P1 | UR-004 |
| AM-F-007 | Canonical retain SHALL occur only through a machine-validated write interface covering every changed canonical artifact, including notes. | P1 | UR-003, UR-007 |
| AM-F-008 | After a retain attempt, the system SHALL report record identity, outcome status, and unresolved failure if present. | P1 | UR-004, UR-007 |

### E.2 Recall

| ID | Requirement | Priority | Source |
|---|---|---:|---|
| AM-F-009 | Bootstrap retrieval SHALL expose only the bounded core set and SHALL NOT load the active index, notes, or archive by default. | P1 | UR-002 |
| AM-F-010 | Fast recall SHALL perform deterministic lexical candidate retrieval over the core and active index. | P1 | UR-003, UR-006 |
| AM-F-011 | The chat AI SHALL inspect source evidence for returned candidates and SHALL determine semantic relevance before presenting a recalled answer. | P1 | UR-004, UR-006 |
| AM-F-012 | A recalled answer SHALL identify record ID, recorded date, provenance status, and source pointer. It SHALL limit certainty to the available evidence. | P1 | UR-004 |
| AM-F-013 | When no relevant active record is established, the system SHALL state that the auxiliary memory contains no established record. General knowledge MAY be offered only as a separately labelled answer. | P1 | UR-004 |
| AM-F-014 | On explicit list intent, the system SHALL provide a bounded active-memory listing or bounded status summary. | P1 | UR-001, UR-002 |
| AM-F-015 | Deep recall SHALL run only after explicit user request and SHALL use the existing strong-model offload capability when that capability is verified available. | P1 | UR-002, UR-006 |
| AM-F-016 | Deep-recall output SHALL be treated as candidates. The chat AI SHALL inspect the referenced canonical records before using the output as recalled evidence. | P1 | UR-004, UR-006 |
| AM-F-017 | A fast-recall miss SHALL NOT automatically invoke deep recall. | P1 | UR-002, UR-006 |

### E.3 Lifecycle

| ID | Requirement | Priority | Source |
|---|---|---:|---|
| AM-F-018 | Every canonical record SHALL have a stable unique record ID independent of topic tags. | P1 | UR-003, UR-007 |
| AM-F-019 | Topic tags SHALL be non-authoritative labels and SHALL NOT be treated as unique record identity. Multiple active records MAY share a tag. | P1 | UR-001, UR-007 |
| AM-F-020 | Supersession SHALL identify the specific prior record or a machine-verifiable subject-property identity. Tag equality alone SHALL NOT supersede a record. | P1 | UR-007 |
| AM-F-021 | When the active index exceeds its bound, the system SHALL move the oldest eligible active record to archive without deleting its recoverable content. | P1 | UR-002, UR-007 |
| AM-F-022 | A normal forget operation SHALL immediately exclude the target record from core, active index, and normal recall while preserving recoverability in archive. | P1 | UR-001, UR-007 |
| AM-F-023 | The system SHALL support restoration of a recoverably archived record by record ID. | P1 | UR-007 |
| AM-F-024 | A pin operation SHALL move only stable, non-task-state content into core and SHALL remain subject to core bounds. | P1 | UR-001, UR-002, UR-005 |
| AM-F-025 | Secure irreversible purge MAY be added in P2 and SHALL be distinct from normal forget. | P2 | UR-007 |
| AM-F-026 | Strong-model-assisted defragmentation MAY be added in P3. Its output SHALL remain a proposal until user acceptance and machine commit. | P3 | UR-002, UR-005 |

### E.4 Authority, failure, and compatibility

| ID | Requirement | Priority | Source |
|---|---|---:|---|
| AM-F-027 | Auxiliary memory SHALL be treated as untrusted runtime evidence and SHALL NOT override policy, current explicit user direction, checkpoint routing, or a declared canonical external source. | P1 | UR-004, UR-005 |
| AM-F-028 | Auxiliary memory SHALL NOT store or reconstruct executable GO, STOP state, pending authorization, or an assertion that an action is currently authorized. | P1 | UR-005 |
| AM-F-029 | A conflict between auxiliary memory and current routing or current user direction SHALL be surfaced to the user and SHALL NOT be silently resolved in favor of memory. | P1 | UR-004, UR-005 |
| AM-F-030 | The system SHALL preserve existing Bionic stale-routing, Minimal Resume, over-read, AUTHORIZATION_UNKNOWN, false-GO, CORRECTION_IS_NOT_GO, and L0 checkpoint-guard behavior. | P1 | UR-005 |
| AM-F-031 | Read-path automation failure SHALL allow conversation continuation through bounded read-only fallback or an `UNVERIFIED` result. | P1 | UR-007 |
| AM-F-032 | Write-path automation absence, failure, or unverifiable state SHALL block canonical memory modification and SHALL produce `BLOCKED`, `FAILED`, or `UNVERIFIED` as applicable. | P1 | UR-007 |
| AM-F-033 | The system SHALL NOT claim automatic bootstrap injection unless the exact Bionic host mechanism has been verified on the current installation. A manual bootstrap path SHALL remain available. | P1 | UR-004, UR-007 |
| AM-F-034 | Auxiliary memory SHALL be shareable by Bionic chats using the same configured workspace memory root. Cross-workspace discovery or synchronization SHALL NOT be implied. | P1 | UR-001 |
| AM-F-035 | A fresh chat SHALL NOT infer a current active task from auxiliary memory. Current task selection SHALL remain governed by live user direction and existing checkpoint policy. | P1 | UR-005 |

## F. Non-functional requirements

| ID | Requirement | Priority | Verification metric |
|---|---|---:|---|
| AM-N-001 | The active core SHALL contain at most 30 records and at most 4,096 UTF-8 bytes, excluding an implementation header if one is used. | P1 | Boundary tests at limit and limit+1 |
| AM-N-002 | The active index SHALL contain at most 100 records and at most 65,536 UTF-8 bytes. | P1 | Boundary tests at limit and limit+1 |
| AM-N-003 | One note SHALL contain at most 32,768 UTF-8 bytes. | P1 | Boundary tests at limit and limit+1 |
| AM-N-004 | One normal recall answer SHALL read at most two notes and at most 65,536 note bytes in total. | P1 | Instrumented behavioral test |
| AM-N-005 | Fast recall SHALL complete within 2.0 seconds at the P95 of 50 consecutive local runs on the target PC with P1 maximum-size fixtures. | P1 | Timed target-PC test |
| AM-N-006 | A no-change normal turn SHALL cause zero additional strong-model calls and zero canonical memory writes. | P1 | Instrumented behavioral test |
| AM-N-007 | An interrupted or failed canonical write SHALL preserve the last machine-validated canonical state. | P1 | Fault-injection test |
| AM-N-008 | Concurrent or stale writes SHALL be detected before replacing newer canonical state. | P1 | Two-writer stale-state test |
| AM-N-009 | Every canonical path and pointer SHALL resolve within the configured memory root or an explicitly allowed read-only evidence root. | P1 | Path traversal and symlink/reparse tests |
| AM-N-010 | Canonical text encoding SHALL be declared, deterministic, and rejected when malformed. | P1 | Valid and malformed encoding tests |
| AM-N-011 | Archive growth SHALL NOT increase default bootstrap payload or normal fast-recall input size. | P1 | Large-archive comparison test |
| AM-N-012 | Operational logs SHALL be bounded and SHALL exclude full conversations, hidden reasoning, credentials, and unrelated file content. | P1 | Size and content audit |
| AM-N-013 | P1 machine operations SHALL execute on Windows PowerShell 5.1 without a new always-running service. | P1 | Clean-environment execution test |

## G. Constraints and assumptions

| ID | Constraint or assumption |
|---|---|
| AM-C-001 | Target execution environment is the existing Windows Bionic host and single-user workspace. |
| AM-C-002 | Default memory root is `workspace/memory/`. Default tool root is `workspace/tools/memory-tool/`. Basic design MAY refine child paths but SHALL preserve these roots unless the user approves a requirement change. |
| AM-C-003 | P1 SHALL use a small local file store and SHALL NOT introduce a vector database, embedding store, graph database, cloud database, or always-running daemon. |
| AM-C-004 | P1 SHALL NOT perform network access or transcript scanning during validation, commit, status, or fast recall. |
| AM-C-005 | Deep recall SHALL use only an already-authorized and verified existing offload path. Deep recall failure SHALL NOT block fast recall. |
| AM-C-006 | Existing checkpoint-guard is a proven behavioral reference, not a runtime dependency unless basic design justifies and verifies a shared component. |
| AM-C-007 | The existence of a Bionic startup, pre-compaction, post-compaction, or handoff machine hook is `UNVERIFIED` for this requirement set and SHALL NOT be assumed. |
| AM-C-008 | P1 supports one configured workspace memory root. Multi-PC synchronization and conflict resolution are out of scope. |

## H. External and actor interface requirements

### H.1 Machine capability surface

| ID | Requirement |
|---|---|
| AM-I-001 | The machine interface SHALL expose read-only validation, canonical commit, fast recall, active listing/status, forget, and restore capabilities. Basic design SHALL define exact command names and parameters. |
| AM-I-002 | Every machine invocation SHALL return one structured result containing status, operation, affected record IDs, canonical state identity, and diagnostics safe for chat display. |
| AM-I-003 | Machine statuses SHALL distinguish at least `PASS`, `HIT`, `MISS`, `INVALID`, `STALE`, `UNVERIFIED`, `BLOCKED`, and `FAILED`. |
| AM-I-004 | Read-only validation, fast recall, list, and status operations SHALL NOT modify canonical or operational state except a bounded non-authoritative diagnostic log if enabled. |
| AM-I-005 | A canonical commit SHALL validate the complete proposed state transition, detect stale base state, preserve prior valid state on failure, and revalidate committed state before returning `PASS`. |
| AM-I-006 | All canonical artifacts changed by one retain action, including a note and its index reference, SHALL become visible as one consistent committed transition or SHALL remain at the prior valid state. |
| AM-I-007 | Canonical files SHALL be writable only through the machine commit capability during normal operation. AI-generated text SHALL remain a candidate until commit returns `PASS`. |

### H.2 Record contract

| ID | Requirement |
|---|---|
| AM-I-008 | An active record SHALL expose `memory_id`, `recorded_at`, `subject`, zero or more `topic_tags`, `summary`, `provenance_status`, `source_pointer`, lifecycle state, and optional `supersedes_id`. |
| AM-I-009 | `memory_id` SHALL be stable and unique within the configured memory root. Topic tags SHALL NOT satisfy identity uniqueness. |
| AM-I-010 | A source pointer SHALL be absent only when provenance status and record content permit a user-stated self-contained fact; otherwise it SHALL resolve to existing evidence at commit time. |
| AM-I-011 | A note reference SHALL NOT become active unless the note is present and part of the same validated state transition. |
| AM-I-012 | Records containing fields that purport to grant execution authorization SHALL be rejected. Natural-language GO references that remain as historical evidence SHALL still be governed by AM-F-028 and the existing L2 firewall. |

### H.3 Recall contract

| ID | Requirement |
|---|---|
| AM-I-013 | Fast recall SHALL return bounded lexical candidates with record ID, matched field, match evidence, provenance status, date, and source pointer. A lexical hit SHALL NOT be labelled a semantic truth judgment. |
| AM-I-014 | Deep recall SHALL return at most three candidates with record IDs, source pointers, and reasons. It SHALL NOT modify canonical memory. |
| AM-I-015 | Recall citations SHALL use stable record ID and source pointer. File line numbers MAY be included when reliable but SHALL NOT be the sole identity. |
| AM-I-016 | The chat AI SHALL report `MISS` separately from `UNVERIFIED`; absence of a lexical match SHALL NOT be represented as file failure, and file failure SHALL NOT be represented as proven absence. |

## I. Required behavior by status

| Status | Required client behavior |
|---|---|
| `PASS` | Continue and report the verified completed operation. |
| `HIT` | Inspect bounded source evidence before composing a recalled answer. |
| `MISS` | Report no established active-memory record; do not claim that no real-world fact exists. |
| `INVALID` | Do not modify canonical state; correct the candidate if correction is authorized and retry at most once. |
| `STALE` | Refresh canonical state and retry at most once; do not overwrite the newer state. |
| `UNVERIFIED` | Do not claim machine verification; use bounded read-only fallback or report unresolved state. |
| `BLOCKED` | Preserve the candidate outside canonical memory and state the condition required to continue. |
| `FAILED` | Preserve the prior valid state, report failure, and do not claim success. |

## J. Acceptance and verification plan

The basic design SHALL produce a test-first specification mapping every P1 requirement to
one or more test IDs. The following acceptance cases are mandatory minima.

| Test ID | Acceptance case | Primary requirement IDs |
|---|---|---|
| AM-T-001 | Initialize and validate a normal empty memory root and return a structured `PASS`. | AM-I-001, AM-I-002, AM-I-003, AM-N-010 |
| AM-T-002 | Reject malformed core, index, note, and record metadata without state change. | AM-I-005, AM-N-001, AM-N-002, AM-N-003 |
| AM-T-003 | Reject path escape, dangling pointer, and disallowed reparse target. | AM-N-009, AM-I-010, AM-I-011 |
| AM-T-004 | Reject malformed encoding without state change. | AM-N-010, AM-I-005 |
| AM-T-005 | Commit a note and index reference with complete record metadata as one consistent transition. | AM-F-007, AM-I-006, AM-I-008, AM-I-009, AM-I-011 |
| AM-T-006 | Inject failure between staged changes and retain the prior valid state. | AM-N-007, AM-I-005, AM-I-006 |
| AM-T-007 | Detect stale base state in a two-writer test and preserve newer state. | AM-N-008, AM-I-005 |
| AM-T-008 | Store two records with the same tag and keep both active. | AM-F-018, AM-F-019 |
| AM-T-009 | Supersede only an explicitly identified prior record. | AM-F-020 |
| AM-T-010 | Enforce core record and byte bounds at limit and limit+1. | AM-N-001, AM-F-024 |
| AM-T-011 | Enforce index record and byte bounds and archive the oldest eligible record. | AM-N-002, AM-F-021 |
| AM-T-012 | Forget a record, exclude it from normal recall, then restore it by record ID. | AM-F-022, AM-F-023 |
| AM-T-013 | Fast recall returns bounded lexical candidates through a read-only operation without claiming semantic relevance. | AM-F-010, AM-I-004, AM-I-013 |
| AM-T-014 | Chat AI rejects an irrelevant lexical hit after source inspection. | AM-F-011, AM-F-012 |
| AM-T-015 | Unknown-memory question produces "no auxiliary-memory record" and does not fabricate recollection. | AM-F-013, AM-I-016 |
| AM-T-016 | Recalled answer includes stable ID, date, provenance, and source pointer. | AM-F-012, AM-I-015 |
| AM-T-017 | Fast-recall miss does not invoke the strong model. | AM-F-017, AM-N-006 |
| AM-T-018 | Explicit deep-recall request returns at most three candidates and performs no canonical write; offload failure leaves fast recall usable. | AM-F-015, AM-F-016, AM-I-014, AM-C-005 |
| AM-T-019 | Strong-model candidate with unsupported claim is not reported as verified memory. | AM-F-016, AM-F-027 |
| AM-T-020 | Memory containing historical GO text does not authorize a gated action. | AM-F-028, AM-I-012 |
| AM-T-021 | Memory/checkpoint conflict is surfaced and memory does not replace routing. | AM-F-029, AM-F-030, AM-F-035 |
| AM-T-022 | Read tool absence permits bounded read-only recovery with `UNVERIFIED`. | AM-F-031, AM-I-016 |
| AM-T-023 | Write tool absence blocks canonical modification and reports non-success. | AM-F-032, AM-F-008 |
| AM-T-024 | Manual bootstrap works with no assumed Bionic injection hook. | AM-F-033, AM-C-007 |
| AM-T-025 | A no-change normal turn performs zero strong-model calls and zero writes. | AM-N-006 |
| AM-T-026 | One recall reads no more than two notes and 65,536 note bytes. | AM-N-004 |
| AM-T-027 | Fast recall satisfies the P95 target with maximum-size P1 fixtures. | AM-N-005 |
| AM-T-028 | Large archive does not change bootstrap or normal fast-recall input size. | AM-N-011 |
| AM-T-029 | Logs remain bounded and contain no transcript, hidden reasoning, or credentials. | AM-N-012, AM-C-004 |
| AM-T-030 | A second Bionic chat using the same configured workspace memory root recalls a committed record without implying another workspace. | AM-F-034, AM-C-008 |
| AM-T-031 | Compaction or handoff recovery retrieves a committed record without treating it as task authority. | AM-F-027, AM-F-030, AM-F-035 |
| AM-T-032 | Checkpoint creation does not copy mutable task state or authorization into memory. | AM-F-002, AM-F-028 |
| AM-T-033 | PowerShell 5.1 clean-host test uses the configured memory/tool roots and passes without a daemon or new database. | AM-N-013, AM-C-001, AM-C-002, AM-C-003 |
| AM-T-034 | Traceability audit maps every P1 requirement to design component, implementation artifact, and test evidence. | UR-008 |
| AM-T-035 | Explicit remember intent creates a complete candidate, commits it, and reports record ID, provenance, and result status. | AM-F-001, AM-F-006, AM-F-008, AM-I-008, AM-I-009 |
| AM-T-036 | A normal turn, compaction approach, or inferred importance without an allowed trigger creates no retain candidate or canonical write. | AM-F-005, AM-N-006 |
| AM-T-037 | Task completion causes a proposal only; no canonical memory is created before explicit user acceptance. | AM-F-003 |
| AM-T-038 | A measured environment fact remains canonical in its existing facts artifact; memory stores only an authorized pointer and summary. | AM-F-004 |
| AM-T-039 | Bootstrap retrieves only core and does not read active index, notes, or archive. | AM-F-009, AM-N-001, AM-N-011 |
| AM-T-040 | Explicit list intent returns a bounded active listing or status summary. | AM-F-014, AM-I-001 |
| AM-T-041 | Each declared machine status is distinguishable, and validation/list/status operations leave canonical state unchanged. | AM-I-003, AM-I-004 |
| AM-T-042 | A retain candidate is not visible as canonical memory until the machine commit returns `PASS`; normal client behavior performs no direct canonical-file write. | AM-F-007, AM-I-007 |
| AM-T-043 | Memory-tool installation and removal do not modify or disable checkpoint-guard behavior; each tool passes its own independent tests. | AM-C-006, AM-F-030 |

Acceptance state rules:

1. Selftests MAY establish machine behavior but SHALL NOT establish cross-chat, compaction,
   handoff, or AI behavioral acceptance.
2. Cross-chat, compaction/handoff, false-recall, false-GO, and failure-fallback cases SHALL be
   executed as live behavioral tests on the target Bionic installation.
3. A test that was not executed SHALL be reported as `UNVERIFIED`, not `PASS`.
4. P1 release status SHALL remain non-operational until every P1 requirement has traceable
   evidence and every mandatory live behavioral test passes.

## K. Required basic-design deliverables

The downstream basic-design AI SHALL produce the following artifacts before implementation.

1. Architecture and responsibility map preserving Section D boundaries.
2. Canonical artifact model and schema satisfying AM-I-008 through AM-I-012.
3. Machine command and structured-status contract satisfying AM-I-001 through AM-I-007.
4. State-transition diagrams for retain, supersede, archive, forget, restore, and failure.
5. Consistency and concurrency design demonstrating AM-N-007, AM-N-008, and AM-I-006.
6. Fast-recall matching design that remains lexical and bounded.
7. Deep-recall integration design using the verified existing offload capability.
8. Minimal Bionic policy or skill changes, including manual bootstrap and status behavior.
9. Test-first specification mapping every P1 requirement to executable or live test evidence.
10. Installation, rollback, backup, migration, and operator instructions.
11. Threat and failure matrix covering path escape, malformed text, stale writes, partial writes,
    prompt-like memory content, false-GO, false recall, and unavailable dependencies.
12. Traceability matrix from `UR-*` to `AM-*`, design component, implementation artifact,
    test ID, and validation evidence.

Basic-design evidence rules:

- The design AI SHALL reread the current `bionic-policy.md`, checkpoint-guard interface and
  tests, and the current offload-skill contract before selecting implementation mechanisms.
- Learned model knowledge SHALL be treated as a hypothesis when a design decision depends on
  current Bionic behavior. The AI SHALL use local machine evidence, user knowledge, or current
  primary documentation as required before closing that decision.
- The basic-design phase SHALL NOT modify production policy, memory, checkpoint, or tool files.
- An implementation shortcut that invalidates a SHALL requirement SHALL be treated as a
  requirement-change proposal and SHALL require user approval.

## L. Open evidence items, not open requirements

These items require validation during design or acceptance but do not change the P1 objective.

| ID | Item | Required closure |
|---|---|---|
| OE-001 | Actual Bionic startup/compaction/handoff hook surface | Verify locally and through current primary documentation; retain manual bootstrap regardless |
| OE-002 | Fast lexical recall quality for Japanese spelling variation | Measure with representative user queries; propose P2 improvement if needed |
| OE-003 | Cross-chat visibility of one workspace memory root | Prove with AM-T-030 |
| OE-004 | Current offload-skill command, output contract, and model endpoint | Verify locally before basic-design freeze |
| OE-005 | Practical archive growth rate | Measure after initial operation; no P1 redesign unless bounds are violated |

## M. Scope-freeze gate

After user approval, the basic-design phase MAY begin when all of the following are true.

- This document status is changed to `APPROVED / SCOPE FROZEN` without altering requirement text.
- Every P1 `AM-*` requirement has a unique ID and at least one acceptance path.
- No unresolved contradiction exists between Part I and Part II.
- OE items are classified as design evidence work and are not silently converted to assumptions.
- The user has not yet granted implementation GO unless they explicitly do so separately.

---

## Appendix A - Review disposition of v0.2 decisions

| v0.2 decision | v0.3 disposition | Reason |
|---|---|---|
| D-1 core only at bootstrap | Retained with byte bound and manual-bootstrap requirement | Lightweight and feasible without assuming a hook |
| D-2 four-field index, tag as identifier | Revised | Stable record ID, provenance, and supersession identity were missing |
| D-3 newest-first and FIFO | Intent retained; physical ordering delegated to design | Bounded active set is a requirement; file order is implementation detail |
| D-4 notes last-writer-wins | Rejected for canonical memory | Can create dangling or mismatched index-note state |
| D-5 tool under `workspace/tools/memory-tool/` | Retained as deployment constraint | Consistent with current Bionic layout |
| D-6 memory under `workspace/memory/` | Retained with same-workspace scope | Cross-workspace sharing is not implied |
| D-7 defrag P3 | Retained | Not required for the P1 closed loop |
| D-8 Remove in P1 | Retained and paired with Restore | Forget semantics require testable recall exclusion and recovery |
| D-9 script absence fail-open | Split | Conversation/read path fail-open; canonical write path fail-closed |
| D-10 deep recall only by explicit user request | Retained | Prevents automatic model cost and unsupported escalation |

## Appendix B - Reviewed inputs

- `draft_plan_c_requirements_spec_v0.2.md` (document name only; absolute path omitted from distribution)
- `draft_plan_c_machine_first_requirements_reference.md` (document name only; absolute path omitted from distribution)
- `requirements-definition-concept.md` (document name only; absolute path omitted from distribution)
- `bionic-policy.md` (document name only; absolute path omitted from distribution)
- `AI_MEMORY_REQUIREMENTS_v0.2.md` (document name only; absolute path omitted from distribution)



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

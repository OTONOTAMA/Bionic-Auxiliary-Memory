<!--
DISTRIBUTION PROVENANCE (bamp1-portable v3, 2026-10-13)
SOURCE_FILE: 02_JA_HUMAN_GUIDANCE.md
SOURCE_SHA256: 9020A6F5858D7773286983A7B4EAEB1453C8C34DD4CD7AD7836F9B7FFDBE138C
SOURCE_ENVIRONMENT: absolute path omitted (frozen document on the source PC; this distribution references filename and hash only)
DIST_DATE: 2026-10-13 (v3; file renamed from 02_JA_HUMAN_GUIDANCE.md to 02_HUMAN_GUIDANCE.md)
CHANGE_SCOPE: two-part structure by user decision - PART I is an English rendering of the
guidance (operational); PART II is the frozen Japanese body (sections 1-9) kept as the
verbatim original with documented adaptations (v3.1/v3.2, user GO): (a) source-line
environment-specific absolute paths excluded; (b) the source-project quote block replaced by a
minimal distribution-reader block (source status/history lines removed; v3.2: form flattened
from blockquote to plain paragraphs, no content change); (c) personal name sanitized (2
occurrences); (d) original Japanese title line removed (v3.2); (e) section 8 source-side
process status table replaced by a one-line note (v3.2). No other changes to the body.
The DISTRIBUTION SCOPE ADDENDUM appears once, in PART I.
AUTHORITY_STATEMENT: the frozen source document on the source environment remains the upstream
authority. This variant is normative only within the distributed installation.
-->
# Bionic Auxiliary Memory (BAM) - Human Guidance v0.5 (two-part: English / Japanese)

This file is two-part by user decision (v3, 2026-10-13):
- **PART I (English)**: operational guidance for the user and the target LLM.
- **PART II (Japanese)**: the original body of `02_JA_HUMAN_GUIDANCE.md`, kept as the
  verbatim original with documented adaptations (v3.1/v3.2; see the provenance header and
  the PART II intro line). It is the source-faithful record.

Where PART I and PART II differ, PART II reflects the frozen original; where PART I and
`01_CANONICAL_NORMATIVE_SPECIFICATION.md` differ, **01 wins** (CONFLICT_RULE).

---

# PART I - English (operational guidance)

## 1. What this does

Places a "small organized memo (auxiliary memory)" outside the chat (on the local PC), so that
across context compression, handoff, and chats, you can recall recorded facts, summaries of
past work, and environment facts **with evidence (citations)**.

- It is NOT something that saves and re-reads entire conversation history. Only short,
  organized facts that have value in being kept.
- Format checking, storage, search, and corruption detection are handled by the **machine
  (script)**. The chat AI is a thin client.
- Memory is **evidence / reference**, not GO, not task state, and not Authority (existing host
  rules remain unchanged).

## 2. Who does what

| Role | Does | Does not |
|---|---|---|
| User | Remember / forget instructions, deep-dig instructions, GO, final judgment, manual organization of generation folders (only when needed) | Machine verification |
| Chat AI | Interpreting instruction intent, drafting record candidates (note body + evidence pointer), reading the original of machine-returned candidates and judging relevance, pin stability classification (only stable facts pinned; in-progress tasks not pinned), cross-checking deep-dig candidate originals (the <=3 the machine narrowed), reporting to match the evidence | Direct writing to canonical files, reconstructing permissions from memory, enforcing pin limits (machine's job), automatic deletion of generation folders |
| Machine (memory-tool.ps1) | Format verification, search, dedup by operation_id, generation snapshots, CURRENT re-verification, ACTIVE durable PASS record, PASS recovery for the same request, mutual exclusion, hash evidence, local narrowing of deep-dig results | Semantic judgment, value judgment, GO decision, adopting an un-PASSed generation from a different request, automatic deletion of completed generations |
| Strong local LLM (offload) | Producing deep-dig candidates only when the user explicitly says "dig" (attach a verbatim quote of 12+ characters to each candidate; quotes must not contain a pipe) | Modifying canonical files, final fact determination, GO |

## 3. Files and where they are placed

```
workspace/memory/
  ACTIVE       read target + durable PASS evidence (generation id, operation_id, spec hash, STATE hash, PASS)
  CURRENT      write record (generation id, operation_id, spec hash, STATE hash). While pending it is 1 generation ahead of ACTIVE. Not used for read content
  receipts/    past small PASS proofs (1 file per operation_id; no overwrite)
  .gen/
    000012/    = a "complete state snapshot" of 1 generation
      core.md      small core read at startup (<=30 records, <=4 KiB)
      index.md     normal index (<=100 records, <=64 KiB)
      archive.md   backup store (unlimited; not read at startup or normal search)
      notes/       detailed notes (1 note <=32 KiB)
      STATE        management info of this generation (generation and hash of each file + all notes)
```

- **The reader reads ACTIVE once and reads only files inside that generation.** The only
  moment visible to reads is the atomic replacement of ACTIVE (the last change of a commit),
  so two generations never mix mid-write.
- **Pre-PASS generations are invisible to reads**: ACTIVE atomically stores a `RESULT=PASS`
  that binds generation, request id, input hash, and STATE hash - not just a generation
  number. Reads only see generations whose PASS evidence verified.
- Generation retention (v0.4): **automatic deletion of completed (PASS) generations does not
  exist in P1**. All completed generations remain on disk and are kept until the user's
  explicit manual organization (section 5 / 01 D10.4) deletes them. This makes it
  structurally impossible for a long read (especially a deep-dig job taking minutes) to lose
  the generation mid-read. (The v0.3 "10-minute mtime grace" was rejected because two commits
  after read start could exhaust the grace and delete the input; recorded in 01 D5 proof 4.)
- Cost (exact description): each generation is a complete copy including archive and all
  notes, and a single generation can reach MiB scale. Cumulative capacity of keeping all
  generations grows roughly quadratically in commit count in the worst case. Past PASS proofs
  are 7-line small files, growing linearly with commit count. P1 has no capacity limit and no
  automatic deletion. Status measures generation count, total bytes, current/largest
  generation bytes, plus proof file count and total bytes, so the user can decide future
  policy.
- If a write crash leaves an un-PASSed generation, **only resending the same operation_id
  with the same spec** can complete it after verification. A different request stops as
  STALE, and the user chooses "resend" or "discard via AbortPending". If only the response
  was lost after a PASS, the original PASS can be recovered without duplication from
  `receipts/<operation_id>.pass` even if another chat later wrote a new generation.
- Writes to canonical files (core / index / archive / notes / STATE / ACTIVE / CURRENT /
  receipts) are **machine only**. No AI direct-write path exists (including on failure;
  fail-closed).
- The machine is `workspace/tools/memory-tool/memory-tool.ps1` (PowerShell 5.1, no network).

## 4. Numeric limits

| Target | Limit |
|---|---:|
| Startup core | <=30 records and <=4 KiB |
| Normal index | <=100 records and <=64 KiB (overage: oldest, unpinned records auto-archived) |
| 1 detailed note | <=32 KiB |
| Notes read in 1 normal answer | <=2, total <=64 KiB |
| Automatic strong-model invocation | 0 (only on explicit user request) |
| Additional LLM processing in normal no-change operation | 0 |
| Total memory-file volume passed to deep dig | <=256 KiB (overage stops deep dig only; normal search continues) |
| Candidates the AI reads for deep dig | <=3 (the machine narrows locally BEFORE the AI reads) |

## 5. Operation (for users, day-to-day)

- **Record**: say "remember this / record this" to create a record candidate (only 4
  triggers; no auto-learning). Each write has a unique operation_id, so the same request can
  be safely resent even if the response vanishes. On completion, report "operation_id,
  record ID, PASS" in 1 line.
- **Recall**: just ask normally ("What was the chess learning about?"). Flow: core ->
  machine search (<=2 times) -> original read (<=2 notes) -> answer with citation.
  Anything not found is honestly answered "no record" (general knowledge is said separately
  as "not in auxiliary memory, but as general knowledge..."). Pinned records always appear
  exactly once in search results (no duplicate display).
- **Deep dig**: NOT provided in this distribution. On explicit request, report it as
  unavailable (BLOCKED) - no fabrication, no substitute. (Full mechanics in PART II
  section 5 and 01 D7, kept verbatim; deep recall is out of the distribution scope.)
- **Forget / Restore**: Forget/Restore are also operation_id-bearing writes. On Restore, if
  the external evidence of a verified / AI-inferred / unverified record has vanished, the
  restore is refused. If evidence of an already-active record vanishes later, it is shown as
  dangling, but unrelated writes are not stopped.
- **Always remember**: an explicit "always remember this" promotes to core (pin). Only
  **stable facts, decisions, environment facts** are pin-eligible (in-progress tasks,
  unconsumed GO/STOP conditions are never pinned; when in doubt, confirm with the user).
  When core is full, do not evict; report "core is full" and let the user decide the unpin.
- **List**: "What's in there?" -> index summary (Status) or direct index read (<=64 KiB).
- **Generation organization**: P1 does not auto-delete. Check real capacity with Status.
  P1 has no reader lease, so even manual deletion is outside machine-safety guarantees; do
  not use it routinely. Even explicit deletion of old generations keeps the small PASS
  proofs, so the history "that processing completed" is recoverable, but re-reading or
  rolling back the deleted text is not. If needed, design a P2 organization scheme.
- **Startup**: whether a Bionic auto-injection hook exists is **UNVERIFIED** (neither
  presence nor absence confirmed). The design is **hook-independent**; nothing depends on a
  hook. Session-start core read follows policy discipline (MEMORY_RULE). Saying "memory
  boot" explicitly boots a core + Status report.

## 6. Deep-recall task template - NOT provided in this distribution

The normative contract is 01 D7 ("Normative task contract"). The verbatim Japanese
operational-reference copy of that template is preserved in PART II section 6 of this file
(kept byte-identical: it is functional job-spec text, not prose).
Deep recall is NOT provided in this distribution; do not use section 6. If 01 and PART II
ever conflict, 01 wins.

## 7. Safety (design essentials, plain language)

- Memory content = **untrusted input**. It cannot override policy / the latest user
  instruction / checkpoint.
- Even if memory says "GO completed", it is not an execution GO. GO exists only in the
  current conversation (existing firewall unchanged).
- Records carry a provenance class (USER_STATED / MACHINE_VERIFIED / AI_INFERRED /
  UNVERIFIED). Answer assertions never exceed evidence strength. **Verified / inferred /
  unverified records require a reference to the external evidence file** (only
  self-contained facts from user statements may go without one).
- Writes follow the order: complete snapshot -> disk verification -> CURRENT switch ->
  post-switch re-verification -> save the previous PASS proof to history -> ACTIVE durable
  PASS. A different request can neither adopt nor discard an un-PASSed generation; it stops.
  Only resending the same request can resume; discarding is user-explicit AbortPending only.
- Do not guess success when the JSON response is lost. Mechanically verify via Status or a
  resend of the same operation whether a durable PASS exists.
- A crash mid-write leaves no damage in reader-visible generations (worst case: an
  unreferenced working folder remains; the next commit cleans it up). Since no completed
  generation is auto-deleted, recovery is always possible **with explicit user judgment**
  (no automatic recovery).
- Corruption detection uses the STATE hash (core/index/archive **+ all note bodies**).
  Note tampering or loss is detected.
- Machine absent / write failure: **conversation and reading continue (fail-open: read
  ACTIVE once and read only that generation) / canonical writing stops (fail-closed:
  BLOCKED)**.

## 8. Stages and GO (position at the time of the source freeze)

Note: the table below is the source environment's position at the document's freeze date.
In this distribution the implementation IS provided (see the DISTRIBUTION SCOPE ADDENDUM);
do not read this table as the distribution's stage state.

| Stage | State |
|---|---|
| Requirements v0.3 | **APPROVED / SCOPE FROZEN** (2026-10-06; SHA256 fixed by measured value into 01) |
| Basic design (this document + 01) | **v0.5 revision, awaiting review** (DESIGN_REVIEW_DRAFT) |
| Qwen implementation-feasibility audit | **Not run** (read-only; design changes / implementation forbidden; verify PowerShell 5.1 atomic replacement etc. on the real machine) |
| scope freeze (hash-fix record of 01/02) | **HOLD** (2026-10-06 user instruction; awaiting separate GO) |
| test-first spec (fixture / command / expected status fixed per test) | Awaiting separate GO |
| Implementation (memory-tool.ps1 / memory/ / MEMORY_RULE) | Awaiting separate GO (at the very start of implementation, create a pre-change backup ZIP into shared/, before all production changes) |
| Real-chat acceptance (AM-T-014..043 live behavioral) | Awaiting separate GO |

- 01's `REQUIREMENTS_AUTHORITY` contains the measured SHA256 of v0.3
  (`5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A`, measured 2026-10-06
  with Get-FileHash, confirmed to match the user's measured value). The scope-freeze record
  is created at the later gate and its measured value must match.
- Correction record: the `338051d1...` that v0.2 listed as "measured" was a **fake
  measurement without running the command**, and has been retracted (recorded in 01
  AUTHORITY block).
- Canonical / mirror (v0.4 new): single canonical = workspace side (absolute path in 01
  META CANONICAL_COPY). The scratchpad side is a non-authoritative mirror (copy from
  canonical only; on conflict canonical wins).
- Approval of this guide is not an implementation GO.

## 9. Honest design reservations (handoff)

1. **Hit rate of Japanese text-match search is unmeasured** (OE-002, UNVERIFIED). Notation
   variation (chess/checker etc.) may improve in P2. Deep dig (strong model) is the
   insurance.
2. **fast recall 2.0s P95** (AM-N-005) is a **strict acceptance criterion**. AM-T-027
   measures it; **not meeting it is FAIL** (not treated as "acceptable range"). Only 2
   resolution paths exist: (a) design adjustment that does not change the frozen requirement
   text (fine-tuning limits / corpus / weights) then re-measure, or (b) propose a
   requirement change to the user (AM-N-005 is frozen, so changing the text needs explicit
   GO). Until P95 passes or the user changes the requirement, P1 is not in operation.
3. **"Cross-chat" is within the same project** (AM-C-008). Not shared with chats of another
   project. UNVERIFIED before AM-T-030 runs.
4. The **hook side of Bionic is UNVERIFIED** (neither presence nor absence confirmed). The
   design is hook-independent; startup core read depends on **AI discipline (MEMORY_RULE)**
   (an L1 risk affected by model compliance; manual boot is the safety valve).
5. **Cost of keeping all generations**: because snapshots are complete, total capacity is
   unlimited and grows roughly quadratically in the worst case. Small PASS proofs grow
   linearly separately. In P1, observe via Status measurements and low commit frequency. If
   it becomes a problem, re-design in P2 with reader-lease-based organization or
   content-addressed note storage.

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

---

# PART II - Japanese (original body, with documented adaptations)

以下は凍結 `02_JA_HUMAN_GUIDANCE.md`（SHA256 9020A6F5858D7773286983A7B4EAEB1453C8C34DD4CD7AD7836F9B7FFDBE138C）の本文（第1〜9節）を、provenance ヘッダ（CHANGE_SCOPE）の適応に従い保持する: (a) 出所行の環境固有絶対パスを除外; (b) ソースプロジェクトの引用ブロックを配布読者向け最小ブロックへ置換（ソースの状態・履歴行を削除; v3.2: 形式を引用から通常段落へ平坦化・内容変更なし）; (c) 固有名詞の無名化（個人名 → 先行AI・2箇所）; (d) 元のタイトル行を削除（v3.2）; (e) 第8節のソース側工程状態表を1行注記へ置換（v3.2）。その他変更なし。配布追加の ADDENDUM は PART I にのみ置く。

**位置づけ:** 本ドメインバンドルの**非規範（non-normative）人間向け指導文書**。正（SOT）は `01_CANONICAL_NORMATIVE_SPECIFICATION.md`（現行 v0.5）。本ガイドと 01 が矛盾する場合は **01 が優先**（CONFLICT_RULE）。

**要件の出所:** `BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md`（APPROVED / SCOPE FROZEN 2026-10-06・本配布に同梱）。本ファイルは配布用派生物。単一正本は配布元環境にある（ファイル先頭の provenance ヘッダを参照）。bundle 内ファイルの整合性は MANIFEST.sha256 で機械検証可能。

**改訂 v0.5（先行AIが基本設計を引継ぎ）:** すべての書込にoperation_idを付与し、ACTIVEを「読取先＋耐久PASS証拠」に変更。過去のPASSはoperation_idで直接引ける小さな履歴へ保存し、同一依頼の再送は重複実行せず元のPASSを回収する。未PASS世代は同じ依頼だけが完了でき、別依頼は停止する。破棄はユーザーが明示したAbortPendingだけ。外部証拠は新規記録・Restore時に存在確認し、後日消えた既存証拠はdanglingとして扱う。容量は完全スナップショット全世代保持のため無制限に増え得ることを明記し、Statusで実測値を出す。

---

## 1. これは何をするものか

チャットの外（ローカルPC）に「小さな整理済みメモ（補助記憶）」を置き、
コンテキスト圧縮・handoff・チャットをまたいでも、記録済みの事実・過去の作業要約・
環境事実を**根拠（引用）付きで思い出せる**仕組み。

- 会話履歴を丸ごと保存・再読するものではない。残す価値のある短く整理された事実だけ。
- 形式確認・保存・検索・破損検出は**マシン（script）**が担う。チャットAIは薄いクライアント。
- 記憶は**証拠・参照**であって、GOでもタスク状態でもAuthorityでもない（既存 L0〜L3 は不変）。

## 2. 誰が何をやるか

| 役 | やること | やらないこと |
|---|---|---|
| ユーザー | 覚えて/忘れる指示、深掘り指示、GO、最終判断、世代フォルダの手動整理（必要な時だけ） | 機械検証 |
| ニコ（チャットAI） | 指示の意図解釈、記録候補の起草（note本文＋evidenceポインタ）、マシン返しの候補の原文読取と関連性判断、pinの安定性分類（安定事実のみpin・進行中タスクはpinしない）、深掘り候補の原文照合（マシンが絞った≤3件）、根拠に合わせた報告 | 正本への直接書込、記憶からの権限再構成、pinの上限強制（マシン担当）、世代フォルダの自動削除 |
| マシン（memory-tool.ps1） | 形式検証、検索、operation_idによる重複防止、世代スナップショット、CURRENT再検証、ACTIVE耐久PASS記録、同一依頼のPASS回収、並行排除、hash証拠、深掘り結果のローカル絞込 | 意味判断、価値判断、GO判定、別依頼による未PASS世代の採用、完成世代の自動削除 |
| 強いローカルLLM（offload） | ユーザーが「掘れ」と明示した時のみ深掘り候補を出す（候補に12文字以上の原文引用を付ける・引用にpipeは含めない） | 正本変更、最終事実判定、GO |

## 3. ファイルと置き場所

```
workspace/memory/
  ACTIVE       読取先＋耐久PASS証拠（世代ID・operation_id・spec hash・STATE hash・PASS）
  CURRENT      書込用レコード（世代ID・operation_id・spec hash・STATE hash）。pending時はACTIVEより1世代進む。読取内容には使わない
  receipts/    過去の小さなPASS証明（operation_idごとに1ファイル・上書き禁止）
  .gen/
    000012/    = 1世代分の「完全な状態スナップショット」
      core.md      起動時に読む小さなコア（30記録以下・4 KiB以下）
      index.md     通常索引（100記録以下・64 KiB以下）
      archive.md   退避先（無制限・起動・通常検索では読まない）
      notes/       詳細ノート（1件32 KiB以下）
      STATE        この世代の管理情報（generation と各ファイル＋全notesのhash）
```

- **読み手は ACTIVE を1回読んで、その世代内のファイルだけを読む**。読取に可視化されるのはACTIVEの原子置換（commitの最終変更）の瞬間だけなので、書込の途中で2世代が混ざることはない。
- **PASS前の世代は読取から不可視**: ACTIVEには単なる世代番号ではなく、世代・依頼ID・入力hash・STATE hashを結び付けた`RESULT=PASS`が原子的に保存される。読取はこのPASS証拠を検証できた世代だけを見る。
- 世代の保持（v0.4）: **完成（PASS）世代の自動削除はP1に無い**。すべての完成世代はdisk上に残り、ユーザーの明示的な手動整理（§5・01 D10.4）で削除されるまで保持される。これにより、長時間の読取（特に数分かかる深掘りジョブ）が読んでいる途中で世代が消える競合は構造的に起きない（v0.3の「10分のmtime猶予」は、読取開始後に2回のcommitが起きただけで猶予が切れて入力を削除し得る反例により却下済み・01 D5証明4に記録）。
- 代価（正確な説明）: 各世代はarchiveと全notesを含む完全コピーであり、1世代がMiB以上になる可能性がある。全世代保持の累積容量は最悪ではcommit数に対して概ね二次的に増える。過去のPASS証明は7行の小ファイルで、こちらはcommit数に比例して増える。P1に容量上限も自動削除もない。Statusが世代数・総bytes・現行/最大世代bytesに加えて、証明ファイル数・総bytesも実測し、ユーザーが将来方針を判断する。
- 書込クラッシュで未PASS世代が残った場合、**同じoperation_id・同じspecの再送だけ**が検証後に完了できる。別依頼はSTALEで止まり、ユーザーが「再送」か「AbortPendingで破棄」かを選ぶ。PASS後に回答だけ失われた場合は、後から別チャットが新しい世代を書いていても、`receipts/<operation_id>.pass`から元のPASSを重複なしに回収できる。
- 正規ファイル（core / index / archive / notes / STATE / ACTIVE / CURRENT / receipts）への書込は**マシンのみ**。AIが直接書く経路は存在しない（故障時も・fail-closed）。
- マシンは `workspace/tools/memory-tool/memory-tool.ps1`（checkpoint-guard の兄弟・PowerShell 5.1・networkなし）。

## 4. 数字の上限

| 対象 | 上限 |
|---|---:|
| 起動時 core | 30記録かつ4 KiB以下 |
| 通常索引 | 100記録かつ64 KiB以下（超過は最古・pinされていない記録が自動退避） |
| 1詳細ノート | 32 KiB以下 |
| 1回の通常回答で読むノート | 2件以下・合計64 KiB以下 |
| 強モデルの自動呼び出し | 0回（ユーザー明示時のみ） |
| 変化のない通常時の追加LLM処理 | 0回 |
| 深掘りに渡す記憶ファイル総量 | 256 KiB以下（超過は深掘りだけ停止・通常検索は継続） |
| 深掘りでAIが読む候補 | 3件以下（AIが読む**前**にマシンがローカルで絞る） |

## 5. 運用（ユーザー向け・日常）

- **記録**: 「覚えておいて / 記録して」と言えば記録候補を作る（4トリガーのみ・自動学習なし）。各書込には一意のoperation_idが付き、応答消失時も同じ依頼を安全に再送できる。完了時は「operation_id・記録ID・PASS」を1行報告する。
- **想起**: 普通に聞けばよい（「チェスの学習は何だった？」）。ニコは core → マシン検索（≤2回）→ 原文読取（≤2ノート）→ 引用付き回答。無いものは「記録にありません」と正直に言う（一般知識は「補助記憶にはないが、一般知識としては」と分けて言う）。pin記録は検索結果で必ず1件のみ（重複表示しない）。
- **深掘り**: 「掘れ / もっと調べる」と明示した時のみ強いLLMが走る（数秒〜1分・チャットcontextには短文のみ）。LLMの生出力はチャットに入らず、**マシン（FilterDeepOut）が形式チェックして最大3件の候補ファイルへ絞ってから**、ニコがその≤3行だけを読んで原文を照合・回答する。
- **忘れる / 戻す**: Forget/Restoreもoperation_id付き書込。Restore時、検証済み・AI推論・未検証記録の外部証拠が消えていれば復元を拒否する。すでにactiveな記録の証拠が後日消えた場合はdangling表示となるが、無関係な書込は止めない。
- **常に覚えて**: 「これは常に覚えて」→ core に昇格（pin）。**安定した事実・決定・環境事実のみ**がpin対象（進行中タスク・未消費のGO/STOP条件はpinしない・迷ったらユーザーに確認）。core が満杯時は退避せず「coreが満杯です」と報告し、ユーザーが unpin を決める。
- **一覧**: 「何がある？」→ 索引サマリ（Status）または index 直読（≤64 KiB）。
- **世代整理**: P1は自動削除しない。Statusで実容量を確認する。P1にはreader leaseがないため、手動削除も機械的安全保証の外であり、常用しない。古い世代を明示削除しても小さなPASS証明は残すので「その処理が完了した」履歴は回収できるが、削除した本文の再読・rollbackはできない。必要になったらP2の整理方式を設計する。
- **起動**: Bionicの自動注入hookの有無は **UNVERIFIED**（存在も不在も未確定）。設計は**hook非依存**であり、hookの有無で動くものが無い。セッション開始時の core 読取は policy 規律（MEMORY_RULE）による。明示的に「memory boot」と言えば core + Status でブート報告。

## 6. 深掘り検索のtaskテンプレ（01 D7 正規契約のコピー・非規範）

**正（normative）は 01 D7「Normative task contract」にある。本セクションは運用参照のコピーであり、01 と矛盾する場合は 01 が優先。**

offload への job spec の `task` は、自己完結5要素（GOAL / 対象 / 機構 / 形式 / 禁止）で書く。
数量制約（「最大3件」「N字」等）は task 本文に書かない（スキルの実測規律: 弱いモデルで失敗トリガー）。
**3件制限はマシンの FilterDeepOut がAI読取前に実施する**（AM-I-014）。

クエリ `<QUERY>` を埋めて使う基本形:

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

CAND 行の `pointer` フィールド = その記録の `source_pointer`（無いなら `note_pointer`、それも無いなら `-`）。
**pipe衝突防止**: evidence が pipe を含むと CAND 行が壊れるため、task で pipe なし区間を選ばせ、マシンの FilterDeepOut は「**正確に5フィールド**の行のみ」を受け付ける（evidence に pipe が混入して6フィールド以上になった行は malformed として破棄・カウント）。

job spec の残りは 01 D7 に従う:

- `inputs` = **現在読取世代（ACTIVE が指す .gen/<n>/）のファイルのみ**（core/index/archive/notes 全件・絶対パス）。世代外ファイルは渡さない。総量 256 KiB 超過なら深掘りは行わず BLOCKED 報告（通常検索は継続）。読取中の世代が削除される競合は構造的に不存在（P1に自動pruneなし・§3）。
- `min_source_quotes: 1`（evidence フィールドが12文字以上の原文引用を含むため、形式と整合する）。`expect_terms` は設定しない（NO_MATCH 分岐を誤検出しないため）。
- **実行後は必ず `FilterDeepOut` を実行**し、マシンが書いた候補ファイル（≤3行）だけを読む。OUT 全文はチャットに入れない。
- **exit 4（ゲート失敗）時**: 同様に FilterDeepOut を実行。HIT なら原文照合（必ず実施）を経て使用可（ゲートは下限であり正誤の唯一の判定者ではない・スキル実測の教訓）。MISS なら「候補なし」と正直報告（stdout の PREVIEW 約300字が既にcontextにあるので、それで異常報告に十分な場合が多い）。

## 7. 安全（設計の要点・素人語）

- 記憶内容 = **信頼できない入力（untrusted）**。policy / 最新ユーザー指示 / checkpoint を上書きできない。
- 記憶に「GO済み」と書いてあっても実行GOにならない。GO は現在の会話のみ（既存 firewall 不変）。
- 記録は出所クラス（USER_STATED / MACHINE_VERIFIED / AI_INFERRED / UNVERIFIED）を持つ。回答の断定は証拠の強さを超えることはない。**検証済み・推論・未検証の記録は外部証拠ファイルの参照が必須**（ユーザー発言の自己完結事実のみ参照なし可）。
- 書込は「完全スナップショット→disk検証→CURRENT切替→切替後再検証→前のPASS証明を履歴へ保存→ACTIVE耐久PASS」の順。別依頼は未PASS世代を採用も破棄もできず停止する。同じ依頼の再送だけが再開でき、破棄はユーザー明示のAbortPendingだけ。
- JSON応答が失われても成功を推測しない。Statusまたは同一operationの再送で、耐久PASSがあるかを機械確認する。
- 書込中のクラッシュは、読取が見える世代に損傷を残さない（最悪は未参照の作業用フォルダが残る・次commitで掃除）。全完成世代は自動削除されないため、**ユーザーの明示判断で**いつでも復旧できる（自動復旧はしない）。
- 破損検出は STATE のhash（core/index/archive **＋全notes本文**）で行う。notesの改変・消失は検出対象。
- マシン不在・書込失敗時は**会話と読取は継続（fail-open・ACTIVEを1回読んでその世代だけ読む）/ 正本書込は停止（fail-closed・BLOCKED）**。

## 8. 工程とGO（現在の位置）

工程の状態は配布元側の管理情報であり、配布からは省略する（v3.2）。本配布には完成した文書・実装・試験記録が含まれており、対象側のゲートは PROCEDURE.md を参照。

- 01 の `REQUIREMENTS_AUTHORITY` に v0.3 の実測 SHA256 が入っている（`5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A`・2026-10-06 Get-FileHash 実測・ユーザーの実測値と一致を確認）。scope freeze 記録は後段のゲートで作成し、その時の計測値と一致することを確認する。
- 訂正記録: v0.2 が「実測」として載せていた `338051d1...` は**コマンドを実行していない偽の計測値**であり、撤回済み（01 AUTHORITY ブロックに記録）。
- 正本/ミラー（v0.4新增）: 単一正本 = workspace 側（絶対パスは 01 META の CANONICAL_COPY 参照）。scratchpad 側は非権威ミラー（正本からのコピーのみ・競合時は正本優先）。
- 本ガイドの承認は実装GOではない。

## 9. 設計上の正直な留保（引き継ぎ）

1. **日本語の文字一致検索の命中率は未実測**（OE-002・UNVERIFIED）。表記揺れ（チェス/チェッカー等）は P2 で改善する余地。深掘り（強モデル）が保険。
2. **fast recall 2.0秒 P95**（AM-N-005）は**厳しい受入基準**。AM-T-027 で実測し、**未達は FAIL**（「許容範囲」扱いにしない）。未達の解決経路は2つのみ: (a) 凍結要件本文を変えない設計調整（上限・corpus・重みの微調整）して再実測、または (b) ユーザーへ要件変更提案（AM-N-005 は凍結済みのため本文変更は明示GO要）。P95 合格またはユーザーの要件変更までは P1 は非運用状態。
3. **「跨チャット」は同一project内**のチャット間（AM-C-008）。別projectのチャットとは共有しない。AM-T-030 実行前は UNVERIFIED。
4. Bionic の **hook 面は UNVERIFIED**（存在も不在も未確定）。設計は hook 非依存であり、起動時の core 読取は **AI 規律（MEMORY_RULE）** に依存する（モデルの遵守率に左右される L1 リスク・手動ブートが安全弁）。
5. **全世代保持の代価**: 完全スナップショットなので総容量は無制限で、最悪では概ね二次的に増える。小さなPASS証明は別に線形増加する。P1ではStatus実測と低いcommit頻度で観測する。問題化したらreader lease付き整理またはcontent-addressed note保管をP2として再設計する。



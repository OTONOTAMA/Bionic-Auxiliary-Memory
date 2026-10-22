# Bionic Auxiliary Memory

Selected, file-based auxiliary memory for **Bionic on Windows** (personal use, single
user, no network, no host hooks).

Long conversations, context compaction and handoffs make useful information hard to
recover. BAM stores selected records as UTF-8 markdown under a memory root and exposes
five machine-checked operations (Bootstrap / Status / Validate / Commit / Demote)
through one PowerShell tool. Every failure returns a machine code plus a hint that
states the next move, which supports operation by weak local LLMs (support by design,
not a capability guarantee); a session is never blocked by memory (Bootstrap is
fail-open). It does **not** save whole conversations and it never stores GO / approval /
execution authority.

## Download and install

The installation artifact is **bam-portable-v0.7.zip**, accompanied by
`bam-portable-v0.7.zip.sha256`. Obtain both from
[GitHub Releases](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7).
GitHub's automatic source ZIP is not the installation ZIP.

Give the ZIP and checksum to your Bionic AI with this request:

> Read README.md, PROCEDURE.md and USAGE.md inside the package. Use the fixed commands
> in PROCEDURE.md to verify the artifact, check the target workspace and run
> install-mock. Do not install until I approve the mock results. Do not overwrite
> existing data, modify tests or hashes, relax thresholds or retry FAIL/STOP without my
> instruction. Report the actual JSON output. I will make the final acceptance decision.
> Ask me for the exact workspace path if it is not explicitly known.

The detailed commands are in [package/PROCEDURE.md](package/PROCEDURE.md).
A human can run the same commands without an LLM.

## Scope and requirements

- Windows PowerShell 5.1; Bionic with shell execution. No administrator rights or
  permanent security-setting changes are required by the documented flow.
- The tool is installed once, globally, in `%LOCALAPPDATA%\bam` (the installer
  `-ToolDir` overrides it) and is usable from any workspace or chat.
- Memory is project-scoped by default: `<workspace>/memory`, shared by all chats of
  that workspace. Per-chat memory is optional and explicit
  (`-ChatRoot <scratchpad>/memory`).
- The skill is placed as an ordinary file in
  `<workspace>/.agents/skills/bam-memory` together with `INSTALL_RECEIPT.json` (exact
  installed paths and hashes). Skill auto-selection is a soft trigger; it is not
  guaranteed.
- Local files are not synchronized across users or PCs.
- Keep personal memory, credentials and test artifacts out of Git and public
  repositories. This distribution contains no user memory data.

## What is included

Five operations (Bootstrap / Status / Validate / Commit / Demote) with machine codes
and Japanese recovery hints; a 33-case machine suite; an installer (JSON 1-line
output, exit 0/1/2, existing data stops the install); a skill template; a
single-document specification (01_SPEC.md); and a one-shot v0.6 migration tool
(bundled in the ZIP, not installed). Deep recall and DEV_STATE are not included.
Neither the tool nor the memory grants execution authority.

## Important limits and safety

- Model capability varies. A weak local LLM may fail to install or use the tool
  correctly. Machine checks and user acceptance are different; the user makes the final
  decision. The fixed commands can be run by a human without an LLM.
- Existing workspace directories or files stop installation (exit 2); nothing is ever
  overwritten or merged. A shared tool dir whose tool files are byte-identical to this
  package is reused (tool_dir_state=MATCHING); any other pre-existing tool dir stops
  the install (exit 2, TOOL_DIR_CONFLICT).
- **Uninstall is disabled.** Manual removal requires explicit user judgment, backups and
  confirmation that the exact target files belong to this install.
- FAIL/STOP is not success. Preserve the JSON output rather than weakening the test or
  changing the target machine speculatively.
- Do not store secrets or full transcripts in memory (spec FR-17 / FR-18).
- A checksum verifies integrity, not publisher authenticity.

## Verification status

The author reports that v0.7 operates in the source environment (user-observed, not an
independent certification of all LLM behavior). `python tools/verify_release.py`
verifies ZIP checksum, manifest and exact source-to-ZIP byte identity; it does not
rerun the installer or the machine suite.

`package/` is the exact source extracted from the delivered ZIP. `dist/` retains that
ZIP unchanged. Do not hand-edit the ZIP or update only one copy; changes need manifest
regeneration, the 33-case suite and a new artifact.

## License

MIT. See [LICENSE](LICENSE). This is an independent community project, not an official
Bionic or LM Studio product.

## Version numbering and existing installations

This release follows **BAM core v0.7** numbering. The earlier portable **v3.4**
belongs to the previous package line; v0.7 is the rewritten layout, rather than a
downgrade of that package. The [v3.4 release](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v3.4)
and its original assets remain available.

The install procedure is for a fresh workspace. Existing memory is never overwritten;
an existing installation requires a separately verified migration plan. The bundled
one-shot migration tool targets the legacy v0.6 record format; it is not a universal
in-place updater for every older package.

## Additional release verification

Pre-publication review checked the exact release ZIP, manifest and source bytes,
and exercised the 33-case suite through the installer in an isolated workspace.
Separate regression probes confirmed that a blocked manifest replacement preserves
the previous manifest and HOT_STATE, and that a missing required memory file causes
status-report to fail. This does not certify Bionic Skill selection or every model.

CLI note: Status may return `manifest=TRACKED_MISSING` and `manifest_missing`
listing the missing required files. Full validation remains a separate operation.

---

# Bionic Auxiliary Memory — 日本語

**Windows上のBionic向け、選択した情報をファイルに残す補助記憶です（個人利用・単一ユーザー・
ネットワークなし・hostフックなし）。**
長い会話・コンテキスト圧縮・ハンドオフ後に、保存済みの情報をPowerShellツールで
Bootstrap / Status / Validate / Commit / Demote の5操作で扱えます。全失敗に機械コードと
次の一手を記したヒント（hint_ja）が付くため、弱いローカルLLMでの運用を支援する設計です
（動作保証ではありません）。セッションは記憶にブロックされません（Bootstrapは
fail-open）。会話全文の保存は行わず、GO/承認/実行権限を保存することはありません。

## 導入の入口

[GitHub Releases](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7)
から `bam-portable-v0.7.zip` と `.zip.sha256` を取得してください。GitHubの自動生成
Source code ZIPは導入用ZIPではありません。ZIPとチェックサムをBionicのAIへ渡し、
次のように依頼します。

> パッケージ内のREADME.md / PROCEDURE.md / USAGE.mdを読み、固定コマンドで配布物確認・
> 対象確認・install-mockを実施してください。mockの結果を私が承認するまでインストール
> しないでください。既存データの上書き、テスト・hash変更、合格基準の緩和、FAIL/STOP後の
> 無断再試行は禁止です。実際のJSON出力を報告してください。最終受入は私が判断します。
> workspaceの正確なパスが不明なら確認してください。

詳細は [PROCEDURE.md](package/PROCEDURE.md)（英語）。人間も同じコマンドを実行できます。

## 対応環境・範囲

- Windows PowerShell 5.1と、shell実行可能なBionicが対象です。管理者権限や恒久的な
  セキュリティ設定変更は不要です。
- ツールはグローバルに1回配置（既定 `%LOCALAPPDATA%\bam`、installerの`-ToolDir`で
  変更可）。どのworkspace・チャットからでも利用できます。
- 記憶はプロジェクト単位が既定: `<workspace>/memory`（同一workspaceのチャット間で
  共有）。チャット単位は明示指定（`-ChatRoot <scratchpad>/memory`）で有効化。
- スキルは `<workspace>/.agents/skills/bam-memory` へ通常ファイルとして配置され、
  `INSTALL_RECEIPT.json`（実配置パス・hash）が同居します。スキル自動選択は
  soft triggerで、保証されません。
- 別PC・別ユーザーとの自動同期はありません。
- 個人記憶・認証情報・テスト成果物をGitや公開リポジトリに混入させないこと。本配布には
  ユーザー記憶データは含まれません。

## 同梱内容

5操作（機械コード + 日本語復旧ヒント付き）・33件機械試験suite・installer（JSON 1行
出力・exit 0/1/2・既存データでSTOP）・スキル雛形・単一仕様書（01_SPEC.md）・v0.6
移行用one-shotツール（ZIP同梱・installされない）。deep recallとDEV_STATEは含みません。
ツールも記憶も実行認可を与えません。

## 制約・注意

- 弱いローカルLLMが導入や利用に失敗することがあります。機械試験PASSとユーザー受入は
  別です。最終判断はユーザーが行います。固定コマンドは人間もLLMなしで実行できます。
- 既存のworkspaceデータ（ファイル・ディレクトリ）はインストールをSTOP（exit 2）します。
  上書き・マージは一切行いません。共有ツールディレクトリのツールが本パッケージと
  byte一致の場合は再利用（tool_dir_state=MATCHING）し、それ以外はSTOP（exit 2、
  TOOL_DIR_CONFLICT）します。
- **自動撤去は無効です。** 手動撤去はユーザー判断・バックアップ・対象ファイルの所有
  確認が必要です。
- FAIL/STOPは成功ではありません。JSON出力を保持し、基準緩和や推測での環境変更を
  しません。
- 秘密情報・会話transcript全文は記憶に保存しないこと（仕様FR-17/FR-18）。
- hashは真正性の保証ではなく整合性の確認です。

ソース環境でのv0.7稼働は作者のユーザー観測です（全LLM挙動の独立保証ではありません）。
`python tools/verify_release.py` でZIP・チェックサム・MANIFEST・ソース一致を確認できます
（installer・suiteの再実行は行いません）。`package/` は納品ZIPから展開した正確なソース、
`dist/` はそのZIPの不変コピーです。ZIPは手編集せず、変更時はMANIFEST再生成・33件suite・
新成果物をまとめて作成してください。

MITライセンス。Bionic/LM Studio公式製品ではありません。

## 版番号と既存環境

今回はBAM coreの版番号に合わせた **v0.7** です。従来のポータブル版 **v3.4** から
構成を作り直したもので、単純なダウングレードではありません。旧v3.4のリリースと
配布物も引き続き取得できます。

導入手順は新しいworkspace向けです。既存の記憶は上書きしません。既存環境の移行には
別途検証した計画が必要で、同梱のlegacy v0.6用ツールが全旧版を自動更新するわけでは
ありません。

公開前レビューでは33ケースを含む隔離導入と配布物の整合性を確認しました。
実Bionicのスキル選択や、すべてのモデルの動作を保証するものではありません。

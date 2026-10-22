# Bionic Auxiliary Memory (BAM)

**Small, file-based memory for Bionic on Windows.**

Keep selected facts, preferences and decisions available across long conversations,
context compaction and handoffs. BAM stores them as readable Markdown files and
provides a PowerShell tool to load a compact summary, check integrity and publish
updated summaries.

**Current release: v0.7 · Windows PowerShell 5.1 · MIT license**

[Download v0.7](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7)
· [Installation procedure](package/PROCEDURE.md)
· [Daily usage](package/USAGE.md)
· [Japanese version](#日本語)

## What BAM does

- Keeps selected facts, preferences, work policies, decisions and unverified
  candidates in separate Markdown files.
- Loads a compact `HOT_STATE` summary at session start, after compaction or on
  handoff receipt. If the summary is stale or unverified, it points the AI to the
  source files.
- Checks file formats, size limits and integrity, and publishes updated summaries
  through the adapter.
- Moves older dated facts and decisions into an archive when needed.
- Returns machine codes and Japanese recovery hints to help local LLMs follow
  a predictable workflow.

BAM saves selected information, not complete conversations. It does not include
DEV_STATE or deep recall. Stored memory never grants approval or execution authority.

## How you use it

After installation, ask your Bionic AI:

| Request | Purpose |
| --- | --- |
| Load auxiliary memory | Load the memory for this session. |
| Update auxiliary memory | Update memory and publish a new summary. |
| Enable chat memory | Enable memory for a selected chat. |

The requests above express the intended actions in English. The bundled skill
documents Japanese trigger phrases; English recognition depends on the model.
Skill selection and automatic invocation are not guaranteed. The same operations
can be run directly with PowerShell.

## Where things live

**Shared tools** — installed once and reused across workspaces.  
Default: `%LOCALAPPDATA%\bam`

**Project memory** — shared by chats using the same workspace.  
Default: `<workspace>\memory`

**Workspace skill and receipt** — instructions and exact installed paths.  
Location: `<workspace>\.agents\skills\bam-memory`

**Optional chat memory** — explicitly selected with `-ChatRoot`.  
Location: `<scratchpad>\memory`

`<workspace>` denotes the project folder; `<scratchpad>` denotes the chat working
area. `-ToolDir` overrides the tool location. Chat-root selection is not remembered by
the tool: pass `-ChatRoot` on each Bootstrap that needs it. Commit and Validate
for chat memory use `-Root <chat root>`.

Designed for personal use with a single writer. BAM itself needs no network or
host hooks and does not synchronize files between users or PCs.

## Download and install

Requirements: **Windows PowerShell 5.1** and **Bionic with shell execution**.
The documented procedure requires no administrator rights or permanent execution
policy change.

1. Download `bam-portable-v0.7.zip` and `bam-portable-v0.7.zip.sha256` from
   [the v0.7 release](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7).
2. Extract the ZIP and read its `README.md`, `PROCEDURE.md` and `USAGE.md`.
3. Follow the fixed sequence: `verify-artifact` → `check-target` → `install-mock`
   → user approval → `install` → `status-report`.

Use the release asset ZIP; GitHub's automatic **Source code** archive is not the
installation package. `-ExpectedSha256` takes the hash value written in the
sidecar, not its filename. Full commands are in
[PROCEDURE.md](package/PROCEDURE.md).

To have your Bionic AI perform the preparation, give it the ZIP and checksum with:

> Read README.md, PROCEDURE.md and USAGE.md inside the package. Use the fixed commands
> in PROCEDURE.md to verify the artifact, check the target workspace and run
> install-mock. Do not install until I approve the mock results. Do not overwrite
> existing data, modify tests or hashes, relax thresholds or retry FAIL/STOP without my
> instruction. Report the actual JSON output. I will make the final acceptance decision.
> Ask me for the exact workspace path if it is not explicitly known.

## Operations and checks

| Operation | Purpose |
| --- | --- |
| `Bootstrap` | Initialize memory or load its summary. |
| `Status` | Show memory health and archive suggestions. |
| `Validate` | Run the full integrity check. |
| `Commit` | Validate and publish an updated summary. |
| `Demote` | Archive older facts and decisions. |

Bootstrap normally lets the session continue even if memory is unavailable.
Validate checks tracked files, encoding, size limits, summary headers and the manifest.
Commit also updates the manifest.

The installer runs a **33-case suite** in isolated staging. Its `status-report`
checks installation placement and memory health; it does not replace the adapter's
full `Validate` operation.

For repository maintainers, `python tools/verify_release.py` verifies the ZIP
checksum, its nine manifest entries and exact equality between the ten packaged
files and `package/`. It does not run the installer or test suite.

## Limits and existing installations

- Local model capability varies. Fixed commands and machine checks help operation,
  but do not guarantee that a model will follow the procedure correctly.
- Existing target memory or skill data stops installation. Nothing is overwritten
  or merged. A shared tool directory is reused only when its tool files match this
  package byte for byte; conflicting or partial tool installations stop the install.
- FAIL or STOP needs attention; preserve the output and follow the documented
  procedure. A machine PASS and user acceptance are separate decisions.
- Automatic uninstall is disabled. Manual removal needs backups and a check of
  which workspaces still use the shared tools.
- Keep secrets, complete transcripts and personal memory out of public repositories.
  No user memory data is included in this distribution.

This release uses **BAM core v0.7** numbering. The earlier portable **v3.4** was a
different package line; v0.7 introduces the rewritten layout. The
[v3.4 release and assets](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v3.4)
remain available. The bundled migration tool handles the legacy **v0.6 record
format**; it is not a universal updater for every older installation.

## Documentation and license

- [Package overview and contents](package/README.md)
- [Installation procedure](package/PROCEDURE.md)
- [Daily usage and memory budgets](package/USAGE.md)
- [Specification](package/01_SPEC.md)
- [Release notes](RELEASE_NOTES.md)

Released under the **[MIT License](LICENSE)**. This is an independent community
project, not an official Bionic or LM Studio product.

---

# 日本語

## Bionic Auxiliary Memory（BAM）

**Windows版Bionic向けの、小さなファイルベースの補助記憶です。**

長い会話、コンテキスト圧縮、引継ぎをまたいで、選択した事実・好み・判断を参照できるように
します。記憶は読めるMarkdownファイルとして保存し、PowerShellツールで短い要約の読込み、
整合性確認、要約の更新を行います。

**現行版：v0.7 · Windows PowerShell 5.1対応 · MITライセンス**

[v0.7をダウンロード](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7)
· [導入手順](package/PROCEDURE.md)
· [日常の使い方](package/USAGE.md)

## できること

- 事実、好み、作業方針、重要な判断、未確認の候補を、それぞれのMarkdownファイルに保存。
- セッション開始時、圧縮後、引継ぎ受領時に、短い`HOT_STATE`要約を読込み。
  要約が古い場合や未確認の場合は、元ファイルの参照先を案内。
- ファイル形式・容量上限・整合性を確認し、アダプター経由で要約を更新。
- 古い日付の事実や判断を、必要に応じてアーカイブへ移動。
- 機械コードと日本語の復旧ヒントで、ローカルLLMの操作を支援。

保存対象は選択した情報です。会話全文の保存、DEV_STATE、過去情報の詳細検索は含みません。
記憶に書かれた内容が、承認や実行権限になることもありません。

## 普段の使い方

導入後は、BionicのAIに次のように依頼します。

| 依頼 | 用途 |
| --- | --- |
| 補助記憶ブートして | 今回使う記憶を読み込む。 |
| 補助記憶に反映して | 記憶と要約を更新する。 |
| チャット単位の補助記憶を有効に | 指定したチャットの記憶を使う。 |

これらは文書化された自然言語の呼び出し例です。スキルの選択はホストとモデルに依存するため、
自動実行は保証されません。人間がPowerShellで直接操作することもできます。

## 保存場所と共有範囲

**共用ツール** — 一度配置し、複数の作業フォルダーから利用。  
既定：`%LOCALAPPDATA%\bam`

**プロジェクト記憶** — 同じ作業フォルダーを使うチャット間で共有。  
既定：`<workspace>\memory`

**スキルと導入記録** — 作業フォルダー用の指示と、実際の導入先を記録。  
配置先：`<workspace>\.agents\skills\bam-memory`

**任意のチャット記憶** — `-ChatRoot`で明示して利用。  
配置先：`<scratchpad>\memory`

パス中の`<workspace>`は作業フォルダー、`<scratchpad>`はチャット用の作業領域です。
ツールの配置先は`-ToolDir`で変更できます。チャットの選択はツール側に保持されないため、
利用するBootstrapごとに`-ChatRoot`を渡します。チャット記憶へのCommit・Validateは
`-Root <チャット記憶の保存先>`で実行します。

個人利用・単一の書込み主体を想定しています。BAM自体はネットワークやホスト側のフックを必要とせず、
別PC・別ユーザーとのファイル同期も行いません。

## ダウンロードと導入

必要なものは、**Windows PowerShell 5.1**と**シェルを実行できるBionic**です。
文書の手順では、管理者権限や恒久的な実行ポリシー変更は不要です。

1. [v0.7リリース](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v0.7)から
   `bam-portable-v0.7.zip`と`bam-portable-v0.7.zip.sha256`を取得します。
2. ZIPを展開し、中の`README.md`・`PROCEDURE.md`・`USAGE.md`を読みます。
3. `verify-artifact` → `check-target` → `install-mock` → ユーザー承認 → `install`
   → `status-report`の順に進めます。

導入にはリリース添付のZIPを使ってください。GitHubが自動生成する**Source code**のZIPは
導入用パッケージではありません。`-ExpectedSha256`に指定するのは、チェックサムファイルの名前ではなく、
そこに書かれたハッシュ値です。具体的なコマンドは[PROCEDURE.md](package/PROCEDURE.md)にあります。

BionicのAIに準備を依頼する場合は、ZIPとチェックサムを渡し、次のように伝えます。

> パッケージ内のREADME.md・PROCEDURE.md・USAGE.mdを読み、PROCEDURE.mdの固定コマンドで
> 配布物確認・対象作業フォルダー確認・install-mockを実施してください。模擬導入の結果を私が承認するまで
> インストールしないでください。既存データの上書き、テスト・ハッシュの変更、合格基準の緩和、
> FAIL/STOP後の無断再試行は禁止です。実際のJSON出力を報告してください。最終受入は私が判断します。
> 作業フォルダーの正確なパスが不明なら確認してください。

## 操作と検証

| 依頼の例（対応する操作） | 内容 |
| --- | --- |
| 補助記憶を読み込んで（`Bootstrap`） | 記憶の初期化・要約の読込み。 |
| 補助記憶の状態を確認して（`Status`） | 記憶の状態・アーカイブ推奨を表示。 |
| 補助記憶の整合性を確認して（`Validate`） | ファイル・容量・整合性を完全検証。 |
| この内容を補助記憶に反映して（`Commit`） | 更新した要約を検証・保存。 |
| 古い記憶を整理して（`Demote`） | 古い事実や判断をアーカイブへ移動。 |

上の依頼文は意図を伝える自然な言い方の例で、固定の呼び出し語ではありません。
スキルに記載された呼び出し例は「普段の使い方」を参照してください。

Bootstrapは通常、記憶を利用できなくてもセッションを継続します。Validateは管理対象ファイル、
文字コード、容量、要約ヘッダー、整合性管理ファイルを検証し、Commitは要約と整合性管理ファイルを更新します。

インストーラーは隔離した作業領域で**33ケースの試験**を実行します。`status-report`は導入先と
記憶の簡易確認であり、アダプターの`Validate`による完全な整合性検証とは別です。

公開物を確認する場合は、`python tools/verify_release.py`でZIPのチェックサム、整合性一覧の9項目、
同梱10ファイルと`package/`のバイト一致を検証できます。このコマンドはインストーラーや試験一式を
再実行しません。

## 制約と既存環境について

- ローカルモデルの能力には差があります。固定手順と機械検証で操作を支援しますが、
  モデルが正しく手順を守ることまでは保証しません。
- 対象の記憶やスキルが既に存在する場合は導入を停止し、上書き・マージしません。
  共用ツールは本パッケージとバイト一致する場合だけ再利用します。不一致や一部のみの配置では停止します。
- FAIL・STOP時は出力を保持し、文書の手順に従って対応します。機械検証のPASSとユーザーの受入判断は別です。
- 自動アンインストールは無効です。手動削除の前にバックアップと、共用ツールを使う他の作業フォルダーの確認が必要です。
- 秘密情報・会話全文・個人記憶を公開リポジトリに入れないでください。本配布物にユーザーの記憶データは含みません。

今回は**BAM core v0.7**の版番号を使用しています。従来のポータブル**v3.4**とはパッケージの系統が異なり、
構成を作り直した版です。[旧v3.4のリリースと配布物](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/tag/v3.4)も
引き続き取得できます。同梱の移行ツールは旧**v0.6の記録形式**が対象で、すべての旧環境を
自動更新する汎用アップデーターではありません。

## 文書とライセンス

- [パッケージ概要・同梱物](package/README.md)
- [導入手順](package/PROCEDURE.md)
- [日常操作・容量上限](package/USAGE.md)
- [仕様書](package/01_SPEC.md)
- [リリースノート](RELEASE_NOTES.md)

**[MITライセンス](LICENSE)**で公開しています。Bionic・LM Studio公式製品ではない、独立したコミュニティプロジェクトです。

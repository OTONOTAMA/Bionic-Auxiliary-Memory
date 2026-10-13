# Bionic Auxiliary Memory

Selected, file-based supplementary memory for **Bionic on Windows**.

Long conversations, context compaction and handoffs can make useful information
hard to recover. BAM stores selected records locally and lets an AI retrieve them
through a PowerShell tool. It does **not** save whole conversations, reconstruct
all lost context, or automatically inject memory at compaction boundaries.

## Download and install

The prepared installation artifact is **bamp1-portable-v3.4.zip**, accompanied by
`bamp1-portable-v3.4.zip.sha256`. Obtain both from
[GitHub Releases](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/latest).
GitHub's automatic source ZIP is not the installation ZIP.

Give the installation ZIP and checksum to your Bionic AI with this request:

> Read README.md and PROCEDURE.md inside the package. Use the fixed commands to
> verify the artifact, check the target workspace and run install-mock. Do not
> install until I approve the mock results. Do not overwrite existing data,
> modify tests, relax thresholds or retry FAIL/STOP without my instruction.
> Report the actual output and receipt paths. I will make the final acceptance
> decision. Ask me for the exact workspace path if it is not explicitly known.

The detailed commands are in [package/PROCEDURE.md](package/PROCEDURE.md).
A human can run the same commands without an LLM.

## Scope and requirements

- Windows PowerShell 5.1; Bionic with shell execution. No administrator rights
  or permanent security-setting changes are required by the documented flow.
- PROJECT is the standard installation choice. Code and documents go in the
  specified workspace; memory in `<workspace>/memory` is shared by chats using
  that workspace. It is not per-chat development state.
- Skill placement and memory sharing are separate concepts. Project Skill
  recognition and actual model use must be checked on the target Bionic.
- GLOBAL Skill placement is optional, explicit and uses Bionic's `skill.install`
  plus user approval; the script does not install it or silently fall back to it.
- Local files are not automatically synchronized across users or PCs.
- Keep personal memory, credentials, receipts and test artifacts out of Git and
  public repositories. This distribution contains no initialized user memory.

## What is included

Retain and fast recall; supersede, forget and restore; status and validation;
generation snapshots and integrity checks; an installer, a Core Skill and a
95-case machine test runner. Deep recall execution and DEV_STATE are not included.
DEV_STATE serves a different purpose: development progress and verification
evidence, not shared reference memory. Neither system grants execution authority.

## Important limits and safety

- Model capability varies. An AI may fail to install or use the tool correctly.
  Machine checks and user acceptance are different; the user makes the final
  installation decision.
- Skill selection and session-start reads are not guaranteed. Use the documented
  explicit Skill/manual bootstrap route if necessary.
- Existing directories and same-name Skill conflicts stop installation; do not
  bypass these checks or merge existing memory automatically.
- **Uninstall is disabled.** Manual removal requires explicit user approval,
  backups and confirmation that the exact target files belong to this install.
  Never remove parent Skill directories or unrelated files.
- **Forget is not physical erasure:** original text remains in archives and past
  generations. Do not store secrets; data disposal requires a separate decision.
- FAIL/STOP is not success. Preserve the receipt, including failure reasons,
  rather than weakening the test or changing the target machine speculatively.
- Path checks do not guarantee complete prevention of check-then-use races.
  Use a trusted single-user local environment and avoid changing path components
  during operations. A checksum verifies integrity, not publisher authenticity.

## Verification status

The author reports that v3.4 operates on another PC. This is user-observed target
operation, not a published independent certification of all LLM behavior.
This repository's preparation check verifies ZIP/checksum, manifest and exact
source-to-ZIP byte identity. It does not rerun the installer or machine suite.

```text
python tools/verify_release.py
```

`package/` is the exact source extracted from the delivered ZIP. `dist/` retains
that ZIP unchanged. The package's internal README may retain older distribution
labels; the release artifact here is v3.4. Do not hand-edit the ZIP or update only
one copy. Changes need manifest regeneration, relevant tests and a new artifact.
Development provenance documents are references; ordinary installation starts
with PROCEDURE.md, not a reconstruction of the original development process.

## License

MIT. See [LICENSE](LICENSE). This is an independent community project, not an
official Bionic or LM Studio product.

---

# Bionic Auxiliary Memory — 日本語

**Windows上のBionic向け、選択した情報をファイルに残す補助記憶です。**
長い会話・コンテキスト圧縮・ハンドオフ後に、保存済みの情報をPowerShell
ツールで検索できます。会話全文の保存、完全な記憶復元、圧縮時の自動注入は
提供しません。

## 導入の入口

[GitHub Releases](https://github.com/OTONOTAMA/Bionic-Auxiliary-Memory/releases/latest)
から `bamp1-portable-v3.4.zip` と `.zip.sha256` を取得
してください。GitHubの自動生成Source code ZIPは導入用ZIPではありません。
ZIPとチェックサムをBionicのAIへ渡し、次のように依頼します。

> ZIP内のREADME.mdとPROCEDURE.mdを読み、固定コマンドで配布物確認・対象確認・
> install-mockを実施してください。mockの結果を私が承認するまでインストール
> しないでください。既存データの上書き、テスト変更、合格基準の緩和、FAIL/STOP
> 後の無断再試行は禁止です。実際の出力とレシートの場所を報告してください。
> 最終受入は私が判断します。workspaceの正確なパスが不明なら確認してください。

詳細は [PROCEDURE.md](package/PROCEDURE.md)（英語）にあります。
人間も同じコマンドを実行できます。

## 対応環境・範囲

- Windows PowerShell 5.1と、shell実行可能なBionicが対象です。文書化された
  手順は管理者権限や恒久的なセキュリティ設定変更を必要としません。
- PROJECT導入が標準です。機能を指定workspaceへ配置し、`<workspace>/memory`
  を同じworkspaceのチャットで共有します。チャット固有の開発進捗とは別物です。
- Skillの配置範囲と記憶の共有範囲は別概念です。対象環境でのSkill認識・実利用
  は確認が必要です。GLOBALは明示選択・skill.install・承認が必要で、無断の
  フォールバックは行いません。別PC・別ユーザーとの自動同期はありません。
- 保存・通常検索・supersede/forget/restore・状態/整合性確認、Core Skillと
  95件の機械試験runnerを同梱します。deep recall実行とDEV_STATEは含みません。
  DEV_STATEは開発進捗と検証証拠を扱う別機能です。どちらも実行認可を与えません。

## 制約・注意

- AIの能力によって導入や利用が失敗することがあります。機械試験PASSと
  ユーザーの受入は別です。最終判断はユーザーが行います。
- Skillの自動選択・セッション開始時読取は保証しません。必要なら明示起動や
  手動bootstrapを使います。既存データ・同名Skillの競合はSTOPとして扱います。
- **自動撤去は無効です。** 手動撤去は承認・バックアップ・対象の所有確認が
  必要です。親Skillフォルダや無関係なファイルを削除しないでください。
- **forgetしても原文はarchiveや過去世代に残ります。** 秘密を保存しないこと。
  個人記憶・進捗・認証情報・レシートをGitや公開リポジトリに混入させないこと。
- FAIL/STOPではレシートと失敗理由を保持し、基準の緩和や推測での環境変更は
  行いません。パス検査は競合の完全防止を保証しないため、信頼できる単一
  ユーザー環境で、処理中のパス変更を避けてください。hashは真正性の保証では
  なく、整合性の確認です。

別PCでのv3.4稼働は作者によるユーザー観測です。公開準備ではZIP・チェックサム・
MANIFEST・ソース一致を確認し、導入や95件の再実行は行っていません。
`python tools/verify_release.py` で同じ整合性確認ができます。
配布ZIPは変更せず保存しています。内部READMEには古い版表記が一部残りますが、
今回の成果物はv3.4です。変更時はMANIFEST再生成・関連試験・新成果物の作成を
まとめて行い、ZIPだけを手編集しないでください。

MITライセンス。Bionic/LM Studio公式製品ではありません。

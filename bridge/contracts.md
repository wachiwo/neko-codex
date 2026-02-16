# Bridge Contracts

Claude-Codex-Gemini間の意思疎通ルールにゃ。

## 必須項目

すべてのタスクファイル（inbox/*.md / outbox/*.md）に以下を含めること:

| 項目 | 説明 | 例 |
|------|------|-----|
| task_id | 一意のタスクID | bridge_001 |
| from | 送信元システム | claude / codex / gemini |
| to | 送信先システム | codex / claude / gemini |
| status | 現在のステータス | todo / in_progress / done / blocked |
| objective | 目的・やりたいこと | 「受注画面.htmlのBS5レイアウトをレビューして」 |
| acceptance_criteria | 完了条件 | 「レイアウト崩れ0件、指摘リスト付き」 |
| due_by | 期限（任意だが推奨） | 2026-02-10T18:00 |

## context_pack（任意・後方互換）

受信側に追加コンテキストを渡すためのオプションフィールド群。
inboxファイルのヘッダーに追加可能。**無くても既存フォーマットとして有効**。

| 項目 | 説明 | 例 |
|------|------|-----|
| context_pack.task_summary | タスクの1-2行要約 | 「BS5レイアウト変換の品質レビュー」 |
| context_pack.target_files | 作業対象ファイル一覧 | /path/to/file1, /path/to/file2 |
| context_pack.completion_criteria | 完了条件 | 「指摘リスト付きレビュー完了」 |
| context_pack.design_notes | 設計判断メモ（任意） | 「カード型レイアウト採用」 |

### 書き方（inboxヘッダー内）

```markdown
- context_pack.task_summary: BS5レイアウト変換の品質レビュー
- context_pack.target_files: /path/to/file1, /path/to/file2
- context_pack.completion_criteria: 指摘リスト付きレビュー完了
- context_pack.design_notes: カード型レイアウト採用
```

- 全フィールド任意。一部だけ指定してもOK
- 送信側のタスクYAMLから自動抽出が推奨だが、手動記載も可
- 回答側(outbox)には不要（回答時は結論セクションで十分）
- context_pack.completion_criteria は「求める出力」セクションの簡易サマリー。正は「求める出力」本文。context_pack は受信側のクイックリファレンス用

## ステータス遷移

```
todo → in_progress → done
                   → blocked
```

- **todo**: 依頼を書いた直後。相手がまだ見ていない
- **in_progress**: 相手が作業を開始した
- **done**: 完了。outbox/ に成果物あり
- **blocked**: 情報不足等で進められない。outbox/ に不足情報と必要な追加入力を記載

## inbox/*.md の書き方（依頼側）

```markdown
# task_id: bridge_XXX
- from: claude
- to: codex  # or: gemini
- status: todo
- due_by: YYYY-MM-DDTHH:MM
- context_pack.task_summary: (任意) タスク要約
- context_pack.target_files: (任意) 対象ファイル
- context_pack.completion_criteria: (任意) 完了条件
- context_pack.design_notes: (任意) 設計メモ

## 目的
何をしてほしいか

## 前提
相手が知っておくべき背景情報

## 制約
守ってほしいルール・制限

## 求める出力
具体的な成果物の形式

## 関連ファイル
- /path/to/file1
- /path/to/file2
```

## outbox/*.md の書き方（回答側）

```markdown
# task_id: bridge_XXX
- from: codex
- to: claude
- status: done
- worker_count: <実際にtaskを実行したワーカー数。親分単独は0>
- executor: <oyabun / workers>
- solo_reason_code: <親分単独時のみ必須。direct_master_instruction / workspace_unavailable / hotfix / simple_relay>
- worker_report_paths:
  - <当該task_idのレポートファイルパス>

## 結論
一言サマリー

## 根拠
なぜそう判断したか

## 実施内容
具体的に何をやったか

## 出典・帰属
- 参照したレポート/提案の出典を明記
- 既出アイデアを「新発見」として扱わない

## 改善計画（見積り必須）
- 各アクションに deploy_type と estimate を付与
- deploy_type: instruction-change | code-change | poc

## 残課題
まだ解決していないこと（あれば）

## 次アクション
相手がやるべきこと（あれば）

## 関連ファイル
- /path/to/file1
```

### blocked の場合（必須）

```markdown
## 不足情報
- 何が足りないか

## 必要な追加入力
- 何を提供してもらえれば再開できるか
```

## Auto-Rally Mode（自動ラリーモード）

ご主人様の指示で、Claude↔Codex間の自動往復会話を行うモード。
デフォルトOFF。ご主人様が「自動で」等と指示した場合のみON。

### 追加フィールド（auto_rally: true の時は必須）

| 項目 | 説明 | 例 |
|------|------|-----|
| auto_rally | ラリーモードON/OFF | true / false |
| rally_id | ラリーセッション一意ID | rally_20260210_021900 |
| hop_id | 現在のhop番号（0起算、送信ごとに+1） | 0, 1, 2, ... |
| rally_max | 往復上限（デフォルト5） | 5 |
| origin_task_id | ラリー開始タスクID | bridge_008 |
| expires_at | 時間切れ強制停止（任意だが推奨） | 2026-02-10T04:00 |

### メッセージ例

```markdown
# task_id: bridge_XXX
- from: claude
- to: codex
- status: todo
- auto_rally: true
- rally_id: rally_20260210_021900
- hop_id: 0
- rally_max: 5
- origin_task_id: bridge_XXX
- expires_at: 2026-02-10T04:00
- context_pack.task_summary: (任意) ラリートピック要約
- context_pack.target_files: (任意) 関連ファイル
- context_pack.completion_criteria: (任意) ラリー成功条件
```

### ルール

1. **起動**: ご主人様が明示的に指示した時のみ。システムが勝手にONにしない
2. **カウント**: hop_id は送信ごとに+1。hop_id >= rally_max * 2 で強制停止
3. **5往復停止**: rally_max 往復（デフォルト5）に達したら auto_rally: false にして終了メッセージ送信。ご主人様に「続けるか？」確認
4. **継続**: ご主人様が「続けて」→ 新しい rally_id で再開（hop_idリセット）
5. **即時停止**: status: done / blocked を受信したら即終了
6. **エラー停止**: エラー発生時は即停止してご主人様に報告
7. **同時実行**: 1セッション限定。ラリー中に別ラリーは reject
8. **重複防止**: processed_hops.tsv に (rally_id, hop_id, from, to) を記録。既処理hopは破棄
9. **片側未実装**: auto_rally フィールドなし or 未対応の場合は手動モードにフォールバック
10. **1日上限**: なし（ご主人様が必要な時に必要なだけ使う）

### 自動返信フロー

```
受信側 watcher が outbox/inbox 新着を検知
  ↓
auto_rally: true を確認
  ↓
hop_id < rally_max * 2 を確認
  ↓
エージェントを自動呼び出し（tmux send-keys経由）して返信生成
  ↓
outbox/inbox に書き込み + hop_id インクリメント + index.md 更新
  ↓
hop_id >= rally_max * 2 なら auto_rally: false で終了メッセージ
```

## 運用ルール

1. **人間が仲介（通常モード）**: ご主人様がinboxのファイルを相手システムに見せ、outboxの結果を依頼元に伝える
2. **自動仲介（auto-rallyモード）**: watcher が検知し、エージェントが自動返信。ご主人様は5往復ごとに確認のみ
3. **1タスク1ファイル**: inbox/bridge_XXX.md → 完了後 outbox/bridge_XXX.md
4. **index.mdで一覧管理**: 全タスクの状態を1行1タスクで管理
5. **ファイル名規則**: bridge_{連番3桁}.md（例: bridge_001.md）
6. **上書き禁止**: 相手のファイルは読み取り専用。返信は別ファイル（outbox/）に書く
7. **outbox存在時は再処理しない**: outbox/bridge_XXX.md が既にあれば、同じinboxは再処理しない
8. **index.md更新は常に最後**: ファイル書き込み完了後にindex.mdを更新
9. **replyはoutboxのみ作成**: inboxを編集しない

## task_id採番ルール（競合防止）

`bridge_XXX` 採番は必ずロック付きで行うこと。手動で番号を直書きしない。

### 必須

1. `index.lock` を `flock` で取得してから採番する
2. `index.md` と `inbox/outbox` の実ファイルを見て最大番号を算出する
3. **同一ロック区間で** `inbox` 作成と `index.md` 追記まで完了する
4. 失敗時は `retry` し、既存IDを再利用しない

### 推奨スクリプト（Codex側）

- `scripts/bridge_next_id.sh`  
  ロック取得後に次の `bridge_XXX` を払い出す（表示のみ）
- `scripts/bridge_create_inbox.sh`  
  ロック区間内で `inbox/bridge_XXX.md` 作成と `index.md` 追記を原子的に実行

## Gemini連携の例

Claude → Gemini にレビュー依頼:
```markdown
# task_id: bridge_030
- from: claude
- to: gemini
- status: todo

## 目的
osanpo.shのレビュー。Gemini CLIの起動オプションが正しいか確認。

## 求める出力
指摘リスト（severity付き）
```

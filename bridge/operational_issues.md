# 運用問題ログ (Operational Issues Knowledge Base)

> 3システム共有（neko-multi-agent / neko-codex / neko-gemini）
> 問題が起きたらここを参照して切り分けに活用する

---

## OPS-001: MAX_OUTPUT_TOKENS制限によるワーカー停止
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: W4/W2が大きなファイル(500行超YAML)書き込み時にAPIエラーで停止。W4はPythonスクリプトで回避を試みるも二次バグで完全停止
- **エラーメッセージ**: `API Error: Claude's response exceeded the 32000 output token maximum. To configure this behavior, set the CLAUDE_CODE_MAX_OUTPUT_TOKENS environment variable.`
- **原因**: Claude Code CLIのデフォルト出力トークン上限が32000
- **解決**: osanpo.shの全エージェント起動コマンドに `CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000` を追加
- **教訓**:
  - 大きなファイルを生成するタスクでは出力トークン上限に注意
  - ワーカーが止まったら再起動前に `tmux capture-pane -t {pane} -p -S -500` でバッファログを確認して原因特定
  - 原因確認せずに再割り当てすると、実は完了済みのワーカーを見落とす（W1は実際には完了していた）

## OPS-002: パーミッション再要求によるワーカー停止 ✅解決済み
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: `--permission-mode bypassPermissions` で起動しても、セッション中にパーミッション確認が再表示される。全5ペイン(kashira+W1-W4)で発生
- **原因**: `--permission-mode bypassPermissions`はセッション初期化フラグであり永続状態ではない。コンテキストコンパクション、ツールスキーマ変更、MCP再接続などの内部イベントでリセットされる。特定の高リスクツール操作はbypassモードでもプロンプトを出す可能性あり
- **解決**: `.claude/settings.json` + `settings.local.json` にpermission allowlistを追加し二重防御。CLIフラグ（bypassPermissions）+ ファイルベース永続設定で、片方がリセットされてももう片方が有効
- **暫定対処**: ~~親分がtmux send-keysで手動承認~~ → 不要になった
- **教訓**:
  - shift+tab(BTab)でモード切替できるが、タイミングを誤るとplan modeに入ってしまう
  - CLIフラグだけに依存せず、設定ファイルベースの永続許可を併用すること
  - consult_022分析結果: 検出遅延が最大の問題（分〜時間単位で気付かない）

## OPS-003: kashiraコンテキスト消耗によるフリーズ
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: kashiraがcmd_021の3フェーズ(設計→レビュー→修正)を全管理した結果、context残り0%まで消耗しフリーズ
- **原因**: 1つのcmdで4人×3フェーズ分のタスク配布・レポート受信・ダッシュボード更新を行い、コンテキストが枯渇。kashiraは単一障害点でありフェイルオーバーなし
- **解決**: kashira再起動（/exit → 新セッション起動）
- **対策（cmd_023で実装）**:
  - cmd分割ルール: 3+フェーズ or 10+タスクサイクルのcmdはsub-cmd分割必須
  - レポート圧縮: kashira inboxにはsummary最大5行のみ送信、詳細は別ファイル参照
  - context budget threshold: 8+レポート読込後に自主checkpoint（task.mdに状態書き出し→再起動可能にする）
  - task.mdを権威的状態ソースとして毎wakeup時に参照する運用
- **教訓**:
  - 大きなcmdはフェーズごとに分割し、フェーズ間でkashiraを再起動する
  - 子分の作業量ではなくkashiraの管理負荷が問題
  - 初期障害は回復可能だが、検出機構の欠如で複合障害に発展する

## OPS-004: ワーカー状態の誤判定（完了 vs 停止）
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: W1がプロンプト `❯` で待機中 → 「フリーズ」と誤判定 → 不要な再割り当て実施。実際はW1は正常完了後のアイドル状態だった
- **原因**: プロンプト `❯` だけでは「完了して待機中」と「停止中」の区別がつかない
- **解決**: バッファログ確認ルールを導入（`tmux capture-pane -p -S -500`で履歴を見て判断）
- **教訓**:
  - 見た目だけで判断しない。必ずバッファログで直近の行動を確認
  - レポートファイルの存在確認も併用する（`ls queue/reports/worker*_{TASK_ID}*`）

## OPS-005: Codexワーカー停滞＋persona誤判定
- **発生日**: 2026-02-12
- **発生システム**: neko-codex (bridge_038で報告)
- **症状**:
  1. worker2がcmd_013で長時間停滞（ACKは返るが成果物が出ない）
  2. 再起動後にbash待機（nodeではなくbash）で指示がシェル実行される
  3. detect_persona判定で expected=workerN / actual=worker4 の誤判定
  4. watchdog再配分後に完了まで自動収束しない
- **原因**: 調査中（Codex側で分析中）
- **暫定対処**: watchdog常駐化(30秒間隔)、未収束時は例外対応
- **恒久対策案（Codex側）**:
  - persona判定のTMUX_PANE対応
  - 再配分後ACK未達の自動再再配分
  - 再起動後ACK→task read→first action logの必須化

## OPS-006: kashiraレポート待ちストール（全員完了済みなのに進まない）
- **発生日**: 2026-02-07
- **発生システム**: neko-multi-agent (cmd_024)
- **症状**: W1-W4全員がcross-reviewを完了してレポート提出済みなのに、kashiraが「W3のレポート待ち」のまま進行しない。チーム全体がストール
- **原因**: kashiraがinbox/reportsの再チェックをしない。一度「待ち」に入ると能動的に再確認しない
- **解決**: 親分がtmux send-keysでkashiraに「全レポート揃っている、確認して」と手動通知
- **教訓**:
  - kashiraの「レポート待ち」が4分以上続いたらinboxとreportsを手動確認
  - 頻繁に発生する問題 — 構造的対策が必要（consult_022で検討中）

## OPS-007: set -eスクリプトの[[ ]] && actionパターンによるサイレントクラッシュ
- **発生日**: 2026-02-06, 2026-02-11（3回発生）
- **発生システム**: neko-multi-agent, neko-codex（bridge_watcher.sh等）
- **症状**: bashスクリプトが条件分岐で突然死する。エラーメッセージなし
- **原因**: `set -e`環境下で`[[ condition ]] && action`を使うと、conditionがfalseのときexit code 1が返りスクリプトが終了する
- **解決**: `if [[ condition ]]; then action; fi` に書き換え
- **検出コマンド**: `grep -n '\[\[.*\]\] *&&' scripts/*.sh`
- **教訓**:
  - 新しいbashスクリプトを書いたら必ず上記grepで検査
  - `set -e`と`&& / ||`の組み合わせは原則禁止
  - パターンID: sp_021（3システム共通の再発バグクラス）

## OPS-008: config nestingバグ（YAML設定ファイルの階層間違い）
- **発生日**: 2026-02-06〜07（cmd_024, cmd_025で3回発生）
- **発生システム**: neko-multi-agent
- **症状**: YAMLの設定値が正しいキーに配置されず、プログラムが設定を読めない
- **原因**: ワーカーがYAML階層を誤って記述（例: `settings.filter.min_profit`を`settings.min_profit`に配置）
- **解決**: cross-reviewで検出→修正
- **教訓**:
  - 3プロジェクト連続で発生した構造的問題
  - kashiraがhints付きで注意喚起してもなお再発
  - 対策: config読み込みテスト必須化（yaml.safe_loadだけでなく実際のキーパスでアクセス確認）

## OPS-009: WSLからWindows実行時の文字化け（cp932エンコーディング）
- **発生日**: 2026-02-06
- **発生システム**: neko-multi-agent
- **症状**: WSLからcmd.exe経由でPythonを実行すると、日本語出力が文字化け
- **原因**: Windowsコンソールのデフォルトエンコーディングがcp932（Shift-JIS）
- **解決**: print()ではなくファイルに`encoding='utf-8'`で書き出す
- **教訓**: WSL↔Windows跨ぎの処理では常にエンコーディングを意識

## OPS-010: neko-gemini構築時の親分単独作業（品質ゲートスキップ）
- **発生日**: 2026-02-10
- **発生システム**: neko-multi-agent → neko-gemini
- **症状**: 親分がneko-gemini構築（23ファイル）を単独で実施。cross-reviewなしで納品
- **原因**: 「自分でやった方が早い」という判断ミス
- **解決**: Codex外部レビュー（bridge_037）で品質チェック実施
- **教訓**:
  - 3ファイル以上 or 新システム構築 → 必ずkashira経由でチームに委任
  - 親分が単独作業 = 品質ゲートゼロ（レビューなし）
  - 並列チームの意義は速度だけでなく品質保証

## OPS-011: ワーカーstall検出の欠如（error self-reporting）
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: ワーカーがエラーで停止しても外部から検出不可。プロンプト `❯` だけでは「完了待機」「停止」「思考中」の区別がつかない。OPS-004と関連するがより広範な問題
- **原因**: ワーカーにheartbeat/self-report機構がない。ツール呼び出し失敗時の即時報告ルールもない
- **解決（cmd_023で導入）**:
  - ワーカーがツール呼び出し失敗・予期しない結果を検出した場合、即座に `status: blocked` の部分レポートを書きkashiraに通知する運用ルール追加
  - エラー発生時は回復試行（最大3回）後にblocked報告、沈黙しない
- **教訓**:
  - 障害の検出遅延が最大の問題。初期障害は軽微でも、検出されないと複合障害に発展する
  - 「沈黙は失敗と同じ」— ワーカーは常に状態を発信すべき

## OPS-012: 大規模出力のトークン上限超過（Chunked Write Rule）
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021, fix_021_004)
- **症状**: W4が860行Pythonスクリプトを1回のWrite呼び出しで生成 → MAX_OUTPUT_TOKENS超過 → 出力途中切断 → 不完全ファイル → 修復で二次バグ（raw stringのSyntaxError）→ 完全停止。OPS-001の詳細カスケード
- **原因**: 1回のツール呼び出しで大量出力を試みた。出力切断は無警告（ワーカーは切断に気付かない）
- **解決（cmd_023で導入）**:
  - Chunked writeルール: 200行超のファイル生成時はセクション分割して複数回のWrite/Edit呼び出しで書き込む
  - kashiraがタスク配布時に「500行超出力が予想される場合はchunked write hint」を付与
- **教訓**:
  - MAX_OUTPUT_TOKENS=64000でも根本解決ではない（さらに大きなファイルで再発する）
  - 分割書き込みが唯一の根本対策

## OPS-013: タスクサイズ事前見積りの欠如（Task Sizing Pre-flight）
- **発生日**: 2026-02-12
- **発生システム**: neko-multi-agent (cmd_021)
- **症状**: cmd_021全体で想定外の規模膨張。3フェーズ×4ワーカー=12+タスクサイクルがkashiraのコンテキストを消耗（OPS-003）。個別タスクでも出力規模の見積りなしで割り当て（OPS-012）
- **原因**: タスク配布前にサイズ/複雑さの事前チェックがない。kashiraはcmdを受け取るとそのまま分割・配布する
- **解決（cmd_023で導入）**:
  - kashiraがcmd受領時に事前見積り: フェーズ数×ワーカー数でコンテキスト消費を概算
  - 3+フェーズ or 10+サイクル → sub-cmd分割を必須とするルール
  - 個別タスクの出力規模予測: estimated_effort=largeかつ出力500行超が見込まれる場合はchunked write hintを付与
- **教訓**:
  - 事前見積りは5分で済むが、見積りなしの失敗リカバリは数時間かかる
  - 「小さく始めて大きくする」のが正しい（逆は高コスト）

---

## バッファログ確認コマンド（全システム共通）

```bash
# ワーカーの直近500行を確認（neko）
tmux capture-pane -t multiagent:0.{N} -p -S -500

# 最後の50行だけ見る（簡易確認）
tmux capture-pane -t multiagent:0.{N} -p -S -500 | tail -50

# 特定エラーを検索
tmux capture-pane -t multiagent:0.{N} -p -S -500 | grep -i "error\|interrupt\|exceeded"
```

## チェックすべきポイント（問題発生時）

1. **バッファログ確認** — 再起動・再割り当ての前に必ず実施
2. **レポートファイル確認** — 実は完了済みかもしれない
3. **エラーメッセージ確認** — API制限、構文エラー、パーミッション待ちのどれか
4. **コンテキスト残量確認** — `Context left until auto-compact: N%` の表示
5. **パーミッションモード確認** — bypass/accept/plan のどれになっているか

## OPS-014: OPS-005進捗追記（Codexワーカー停滞の再現条件特定）
- **発生日**: 2026-02-12
- **発生システム**: neko-codex (bridge_038後続運用)
- **症状**:
  1. `cmd_017` 系で worker1 が通知受信後も `task_ack` を返さず停滞
  2. `worker2` は watchdog 再配分後に `task_ack -> first_action -> report_done` で回復
  3. 画面上は通知が積まれるが成果物が出ない時間帯が発生
- **原因**: ワーカーごとのセッション状態差（実行中nodeと実質待機状態の乖離）と、再配分後の収束条件不足
- **解決**:
  - 再配分ループを有効化して `worker2` 側で完了
  - 未収束workerは `blocked` へ切替し、バックアップworkerに移管
- **教訓**:
  - 「通知送信成功」と「着手開始」は別指標として監視する
  - 停滞workerに固執せず、バックアップ配布を早期に実行する

## OPS-015: tmux権限境界による notify_failed 連発
- **発生日**: 2026-02-12
- **発生システム**: neko-codex (bridge_039運用中)
- **症状**: `notify_agent.sh` 実行時に `error connecting to /tmp/tmux-1000/default (Operation not permitted)` が発生し、`notify_failed` が連続
- **原因**: 実行コンテキスト側のtmuxソケットアクセス権限不足
- **解決**: 権限付き実行で再送し、worker配布を復旧
- **教訓**:
  - `notify_failed` 発生時はメッセージ内容より先に tmux 接続性を確認
  - 通知系コマンドは再送時の権限パスを事前に用意する

## OPS-016: persona判定ガードと実窓不整合（worker4起動阻害）
- **発生日**: 2026-02-12
- **発生システム**: neko-codex
- **症状**: worker4 再起動時に `detect_persona --expect worker4` が `actual=worker1` を返し、起動ガードで停止
- **原因**: 実窓・実行文脈と判定ロジックの不整合（複数window運用時に再現）
- **解決**: worker4はガード回避で起動後、窓状態を再同期
- **教訓**:
  - persona preflight は有効だが、窓/セッション整合チェックとセットで使う
  - 再起動手順に「window名・pane index確認」を必須化する

## OPS-017: bridgeタスクでの証跡要件と新鮮度要件のギャップ
- **発生日**: 2026-02-12
- **発生システム**: neko-codex bridge運用
- **症状**: outboxを `done` にしても、worker証跡が不足または古いと guard で `blocked` 化されるリスク
- **原因**: done条件に「最小worker数」だけでなく「source時刻以降の証跡新鮮度」条件がある
- **解決**: bridgeタスク受信後に専用 `cmd_xxx` で証跡を新規収集してから outbox化
- **教訓**:
  - 過去レポートの再利用だけでは guard を通らない場合がある
  - bridge対応は task_id単位で新規証跡を作る運用が安全

## OPS-018: Gemini oyabun画面の1分更新で表示が流れる（tmux status行）
- **発生日**: 2026-02-12
- **発生システム**: neko-gemini
- **症状**: `gemini-oyabun` 画面下部で時刻付きステータス行が1分ごとに再描画され、指示入力が流れて実運用しづらい
- **原因**: tmuxのstatus行が有効で、`status-interval` 周期の再描画が継続していた
- **解決**: `osanpo.sh` のセッション作成直後に `gemini-oyabun` / `nekogemini` の `status off` を恒久適用
- **教訓**:
  - 「内部処理は動かしつつ画面だけ静かにしたい」場合は watcher停止ではなく tmux表示設定を先に見る
  - システム間で「表示ノイズ抑制」の初期設定を揃えると、運用差分起因の誤認を防げる

## OPS-019: bridge task_id競合（同一IDが別文脈で同時使用）
- **発生日**: 2026-02-12
- **発生システム**: bridge共通運用（claude/codex/gemini）
- **症状**: `bridge_055` が「Claude→Codex依頼」と「Gemini→Codex相談」で同時に使用され、追跡が混線
- **原因**: 採番をシステム横断で直列管理しておらず、同時刻に別系統が同一IDを採番
- **解決（暫定）**: 返信を `bridge_056`（Gemini向け）/`bridge_057`（Claude向け）へ分離し、`bridge_055` は競合として `blocked` 化
- **やること（恒久）**:
  - 採番予約ファイル（例: `bridge/sequence.lock`）で原子的にID払い出し
  - watcher側で「同一IDのinbox/outbox異文脈」を検知したら自動 `blocked` +再採番提案
  - `index.md` 更新時に重複チェックを必須化

## OPS-020: `awaiting guidance now` 停滞と画面ノイズの複合化
- **発生日**: 2026-02-13
- **発生システム**: neko-codex / neko-gemini（運用観測）
- **症状**:
  1. Workerが `awaiting guidance now` のまま停滞し、担当タスクが進まない
  2. tmuxステータス再描画が続き、指示入力が画面上で流れて視認しづらい
- **原因**:
  - 待機状態の自動再通知ガード不足（assignedのまま放置）
  - セッションのUI表示ノイズ抑制設定未適用
- **解決**:
  - `scripts/stale_task_watchdog.sh` に guidance検知（`awaiting guidance` / `ready`）時の `guidance_nudge` 自動通知を追加
  - `scripts/quiet_tmux_sessions.sh` を追加し、`status off` など低ノイズ設定をセッションへ適用
  - `osanpo.sh` 起動時に `quiet_tmux_sessions.sh` を自動実行
- **教訓**:
  - 「処理系の異常」と「表示系ノイズ」を分離して同時対策する
  - 待機が続く系障害は、再配分前に短周期nudgeを入れると復旧が早い

## neko側クロスチェック結果（bridge_039対応）

OPS-015〜017についてneko-multi-agentでの発生可能性を調査した結果:

| OPS | neko発生 | リスク | 理由 |
|-----|---------|--------|------|
| OPS-015 (tmux notify_failed) | 未発生 | LOW | 同一ユーザー内で全セッション作成。権限境界なし。`has-session`事前チェックあり |
| OPS-016 (persona誤判定) | 未発生 | LOW | pane index方式（Codexのwindow名方式より堅牢）。dedicated task file + post-compaction recovery protocol |
| OPS-017 (証跡新鮮度) | 未発生 | MEDIUM | watcher=notify-only設計でACK問題なし。ただし応答タイムスタンプの明示的検証なし |

**構造的差異**: nekoはpane方式（deterministic index 0-4）、Codexはwindow方式（名前ベース）。nekoは全通信がfile-based inbox経由で、send-keys障害のフォールバックあり。

---

## バッファログ確認コマンド（Codex追加）

```bash
# Codex workerの直近1000行
for i in 1 2 3 4; do tmux capture-pane -t nekocodex:${i}.0 -p -S -1000 | tail -80; done

# kashira inboxでcmd単位の進捗確認
rg -n 'worker[1-4]\|(task_ack|first_action|report_done)\|cmd_XXX' queue/inbox/kashira.queue

# persona判定の実値確認
scripts/detect_persona.sh --format kv

# bridge watcher異常の確認
rg -n 'notify_failed|dispatch_failed|handshake_timeout|delegation_guard_failed' queue/inbox/kashira.queue
```

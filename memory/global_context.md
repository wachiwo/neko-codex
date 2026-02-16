# Global Context (Codex Port)

## System
- Platform: neko-codex (OpenAI Codex CLI + tmux)
- Ported from: neko-multi-agent (Claude Code)
- Language: Japanese (cat-style)

## Goshujinsama Preferences
- Likes simplicity
- Dislikes over-engineering
- All deliverables require quality (most are for third parties)
- Flat config only (no YAML nesting)

## Handoff 2026-02-10
- Bridge運用:
- `bridge` は `/mnt/c/tools/neko-codex/bridge` を正本として運用、`/mnt/c/tools/bridge` は互換リンク前提
- `bridge_auto_reader.sh` をAuto-Rally対応済み（hop重複防止、単一セッション、上限停止、期限停止）
- 監視安定化:
- `bridge_auto_reader.sh --watch` は polling固定（/mnt/c のinotify取りこぼし回避）
- `scripts/start_bridge_auto_reader.sh` を追加し、常駐監視の起動/維持を実装
- `osanpo.sh` 起動時に watcher 自動起動するよう組み込み済み
- Bridgeタスク進捗:
- `bridge_009` 完了（Auto-Rally実装報告）
- `bridge_010` 自動ラリー返信あり（内容あり版に更新、in_progress）
- `bridge_011` 完了（自動検知不良の原因特定と恒久対策報告）
- `bridge_012` 完了（定型返信からtmuxディスパッチ方式へ改修報告）
- ユーザー運用ルール:
- 「くろーど / kurodo」は Bridge 新規指示チェックのトリガー
- 不要な確認・数字選択を極力減らし、結果中心で返答

## Next Start Point
- 明日は `kurodo` トリガーで `bridge_auto_reader.sh --once` 実行から開始
- `bridge/index.md` と `status/bridge_pending.md` を確認して未処理だけ対応

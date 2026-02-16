# neko-codex 友達向けセットアップ手順（ChatGPT有料版前提）

この手順は「相手がすでに有料版ChatGPTを契約済み」の前提で、`neko-codex` を動かすところまでをまとめたものです。

## 0. 前提

- OS: Ubuntu/WSL2 推奨
- 必要コマンド: `git`, `tmux`, `node`, `npm`, `gh`(任意)
- ChatGPT有料契約済みアカウント

## 1. リポジトリ取得

```bash
git clone https://github.com/wachiwo/neko-codex.git
cd neko-codex
```

## 2. 必須ツール導入

```bash
sudo apt update
sudo apt install -y tmux git ripgrep
```

Node.js / npm が未導入なら:

```bash
sudo apt install -y nodejs npm
```

Codex CLI を入れる:

```bash
npm i -g @openai/codex
```

## 3. Codex CLI 認証

```bash
codex login
```

画面に従ってブラウザ認証を完了してください。  
認証後、以下で確認できます:

```bash
codex --help
```

## 4. 動作確認

```bash
cd /path/to/neko-codex
scripts/check_system.sh
```

`rc=0` なら基本OKです。

## 5. 起動方法（通常）

全員起動:

```bash
bash osanpo.sh
```

親分だけ:

```bash
bash osanpo.sh oyabun
```

チームだけ（kashira + workers）:

```bash
bash osanpo.sh team
```

tmux接続:

```bash
tmux attach -t nekocodex
tmux attach -t codex-oyabun
```

## 6. 運用の基本

- bridgeの重タスクは `bridge/outbox` と `bridge/index.md` を確認
- 返信完了判定は `scripts/bridge_done_guard.sh` を使う
- watcher停止時は:

```bash
scripts/start_bridge_auto_reader.sh
scripts/health_snapshot.sh
```

## 7. よくある詰まり

- `codex: command not found`
  - `npm i -g @openai/codex` を再実行
- `persona mismatch`
  - `scripts/detect_persona.sh --format kv` で現在ロール確認
- watcherが反応しない
  - `logs/bridge_auto_reader.log` を確認
  - `scripts/start_bridge_auto_reader.sh` で再起動

## 8. 注意点

- この構成は ChatGPT有料プランのメッセージ消費を伴います
- 使用量は ChatGPT 設定画面で定期確認してください
- `logs/`, `status/`, `queue/reports/` は実行データなので共有時は除外推奨


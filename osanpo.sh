#!/bin/bash
# =^._.^= neko-codex おさんぽスクリプト
# Codex CLI + tmux マルチエージェント起動
#
# Usage:
#   bash osanpo.sh              — 全員起動
#   bash osanpo.sh oyabun       — 親分猫だけ
#   bash osanpo.sh kashira      — 頭猫だけ
#   bash osanpo.sh worker1      — 1号猫だけ
#   bash osanpo.sh worker2      — 2号犬だけ
#   bash osanpo.sh worker3      — 3号猫だけ
#   bash osanpo.sh worker4      — 4号猫だけ
#   bash osanpo.sh workers      — ワーカー4匹
#   bash osanpo.sh team         — kashira + workers (oyabun以外)
#
# NOTE: Each agent runs in a separate tmux WINDOW (tab), not pane.
#       Codex CLI crashes (segfault) in small split panes.
#       Switch tabs: Ctrl+b n (next) / Ctrl+b p (prev) / Ctrl+b <number>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-all}"

# Check prerequisites
if ! command -v codex &> /dev/null; then
    echo "ERROR: codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi
if ! command -v tmux &> /dev/null; then
    echo "ERROR: tmux not found. Install with: sudo apt install tmux"
    exit 1
fi

# Keep bridge watcher always-on so Claude->Codex tasks are auto-detected.
if [[ -x "${SCRIPT_DIR}/scripts/start_bridge_auto_reader.sh" ]]; then
    "${SCRIPT_DIR}/scripts/start_bridge_auto_reader.sh" >/dev/null 2>&1 || true
fi

# Keep tmux UI quiet (status redraw suppression) while leaving agents running.
if [[ -x "${SCRIPT_DIR}/scripts/quiet_tmux_sessions.sh" ]]; then
    "${SCRIPT_DIR}/scripts/quiet_tmux_sessions.sh" >/dev/null 2>&1 || true
fi

# Start codex in a tmux window
start_agent() {
    local session=$1
    local window=$2
    local instruction_file=$3
    local expected_role=$4

    local prompt="Read AGENTS.md and instructions/${instruction_file}"
    tmux send-keys -t "${session}:${window}" "cd '${SCRIPT_DIR}' && scripts/detect_persona.sh --expect '${expected_role}' >/dev/null && codex --full-auto --no-alt-screen '${prompt}'"
    sleep 0.5
    tmux send-keys -t "${session}:${window}" Enter
    sleep 3
}

# Create nekocodex session with windows (tabs)
create_nekocodex_session() {
    tmux kill-session -t nekocodex 2>/dev/null
    sleep 0.5
    tmux new-session -d -s nekocodex -n kashira -x 200 -y 50
    tmux new-window -t nekocodex -n w1
    tmux new-window -t nekocodex -n w2
    tmux new-window -t nekocodex -n w3
    tmux new-window -t nekocodex -n w4
}

# Create oyabun session
create_oyabun_session() {
    tmux kill-session -t codex-oyabun 2>/dev/null
    sleep 0.5
    tmux new-session -d -s codex-oyabun -n main -x 200 -y 50
}

# Ensure session exists, add a named window
ensure_window() {
    local session=$1
    local window=$2
    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "$window" -x 200 -y 50
    else
        # Add window only if it doesn't exist
        tmux new-window -t "$session" -n "$window" 2>/dev/null
    fi
}

echo "=^._.^= neko-codex おさんぽ開始にゃ！"
echo ""

case "$TARGET" in
    oyabun)
        create_oyabun_session
        echo "  Starting Oyabun (親分猫)..."
        start_agent "codex-oyabun" "main" "oyabun.md" "oyabun"
        echo ""
        echo "=^._.^= 親分猫おさんぽ開始にゃ！"
        echo "  tmux attach -t codex-oyabun"
        ;;
    kashira)
        ensure_window "nekocodex" "kashira"
        echo "  Starting Kashira (頭猫)..."
        start_agent "nekocodex" "kashira" "kashira.md" "kashira"
        echo ""
        echo "=^._.^= 頭猫おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex"
        ;;
    worker1)
        ensure_window "nekocodex" "w1"
        echo "  Starting Worker1 (1号猫)..."
        start_agent "nekocodex" "w1" "1gou-neko.md" "worker1"
        echo ""
        echo "=^._.^= 1号猫おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex:w1"
        ;;
    worker2)
        ensure_window "nekocodex" "w2"
        echo "  Starting Worker2 (2号犬)..."
        start_agent "nekocodex" "w2" "2gou-inu.md" "worker2"
        echo ""
        echo "=^._.^= 2号犬おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex:w2"
        ;;
    worker3)
        ensure_window "nekocodex" "w3"
        echo "  Starting Worker3 (3号猫)..."
        start_agent "nekocodex" "w3" "3gou-neko.md" "worker3"
        echo ""
        echo "=^._.^= 3号猫おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex:w3"
        ;;
    worker4)
        ensure_window "nekocodex" "w4"
        echo "  Starting Worker4 (4号猫)..."
        start_agent "nekocodex" "w4" "4gou-neko.md" "worker4"
        echo ""
        echo "=^._.^= 4号猫おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex:w4"
        ;;
    workers)
        create_nekocodex_session
        echo "  Starting Worker1 (1号猫)..."
        start_agent "nekocodex" "w1" "1gou-neko.md" "worker1"
        echo "  Starting Worker2 (2号犬)..."
        start_agent "nekocodex" "w2" "2gou-inu.md" "worker2"
        echo "  Starting Worker3 (3号猫)..."
        start_agent "nekocodex" "w3" "3gou-neko.md" "worker3"
        echo "  Starting Worker4 (4号猫)..."
        start_agent "nekocodex" "w4" "4gou-neko.md" "worker4"
        echo ""
        echo "=^._.^= ワーカー4匹おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex"
        ;;
    team)
        create_nekocodex_session
        echo "  Starting Worker1 (1号猫)..."
        start_agent "nekocodex" "w1" "1gou-neko.md" "worker1"
        echo "  Starting Worker2 (2号犬)..."
        start_agent "nekocodex" "w2" "2gou-inu.md" "worker2"
        echo "  Starting Worker3 (3号猫)..."
        start_agent "nekocodex" "w3" "3gou-neko.md" "worker3"
        echo "  Starting Worker4 (4号猫)..."
        start_agent "nekocodex" "w4" "4gou-neko.md" "worker4"
        echo "  Starting Kashira (頭猫)..."
        start_agent "nekocodex" "kashira" "kashira.md" "kashira"
        echo ""
        echo "=^._.^= チームおさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex"
        ;;
    all)
        create_nekocodex_session
        create_oyabun_session
        echo "  Starting Worker1 (1号猫)..."
        start_agent "nekocodex" "w1" "1gou-neko.md" "worker1"
        echo "  Starting Worker2 (2号犬)..."
        start_agent "nekocodex" "w2" "2gou-inu.md" "worker2"
        echo "  Starting Worker3 (3号猫)..."
        start_agent "nekocodex" "w3" "3gou-neko.md" "worker3"
        echo "  Starting Worker4 (4号猫)..."
        start_agent "nekocodex" "w4" "4gou-neko.md" "worker4"
        echo "  Starting Kashira (頭猫)..."
        start_agent "nekocodex" "kashira" "kashira.md" "kashira"
        echo "  Starting Oyabun (親分猫)..."
        start_agent "codex-oyabun" "main" "oyabun.md" "oyabun"
        echo ""
        echo "=^._.^= 全員おさんぽ開始にゃ！"
        echo "  tmux attach -t nekocodex   (kashira + workers)"
        echo "  tmux attach -t codex-oyabun (boss cat)"
        ;;
    *)
        echo "Usage: bash osanpo.sh [oyabun|kashira|worker1|worker2|worker3|worker4|workers|team|all]"
        exit 1
        ;;
esac

echo ""
echo "Tab switch: Ctrl+b n (next) / Ctrl+b p (prev) / Ctrl+b 0-4"
echo ""
echo "NOTE: Each agent consumes Codex CLI messages from your ChatGPT Plus plan."
echo "      Monitor usage at: https://chatgpt.com/settings"

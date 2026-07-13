#!/usr/bin/env bash
# pre_answer_check.sh — 扫描项目状态，输出 200-1500 字摘要
# 用途：注入到 LLM context，自动防止"先猜再查"反例（红线 7）
# 调用方：~/.openclaw/extensions/ai-director-discipline/index.ts

set -uo pipefail

WORKSPACE="${WORKSPACE_DIR:-/home/user/.openclaw/workspace}"
SUMMARY=""

# 1. outputs/ 各项目 STATUS.yaml 顶层 status + last_agent
if compgen -G "$WORKSPACE/outputs/*/STATUS.yaml" >/dev/null 2>&1; then
  SUMMARY+="===== 项目 STATUS 摘要 ====="$'\n'
  for f in "$WORKSPACE"/outputs/*/STATUS.yaml; do
    proj=$(basename "$(dirname "$f")")
    status=$(grep -E "^status:" "$f" | head -1 | sed -E 's/^status:[[:space:]]*"?([^"]*)"?/\1/' | tr -d '"')
    last_agent=$(grep -E "^last_agent:" "$f" | head -1 | sed -E 's/^last_agent:[[:space:]]*"?([^"]*)"?/\1/' | tr -d '"')
    delivered_at=$(grep -E "^delivered_at:" "$f" | head -1 | sed -E 's/^delivered_at:[[:space:]]*"?([^"]*)"?/\1/' | tr -d '"')
    SUMMARY+="• $proj : status=$status last_agent=$last_agent delivered_at=$delivered_at"$'\n'
  done
  SUMMARY+=$'\n'
fi

# 2. MEMORY.md mtime + AGENTS.md mtime
if [ -f "$WORKSPACE/MEMORY.md" ]; then
  MEM_MTIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$WORKSPACE/MEMORY.md" 2>/dev/null || stat -c "%y" "$WORKSPACE/MEMORY.md" 2>/dev/null | head -c 19 || echo "unknown")
  AG_MTIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$WORKSPACE/AGENTS.md" 2>/dev/null || stat -c "%y" "$WORKSPACE/AGENTS.md" 2>/dev/null | head -c 19 || echo "unknown")
  SUMMARY+="===== SSOT mtime ====="$'\n'
  SUMMARY+="• MEMORY.md : $MEM_MTIME"$'\n'
  SUMMARY+="• AGENTS.md : $AG_MTIME"$'\n\n'
fi

# 3. 当天 memory 日志最后 600 字
TODAY=$(date +%Y-%m-%d)
if [ -f "$WORKSPACE/memory/$TODAY.md" ]; then
  SUMMARY+="===== 今日日志 ($TODAY.md) 末尾 600 字 ====="$'\n'
  SUMMARY+="$(tail -c 600 "$WORKSPACE/memory/$TODAY.md" 2>/dev/null)"$'\n\n'
fi

# 4. 重启上下文（如果有今天的）
if [ -f "$WORKSPACE/memory/重启上下文_$TODAY.md" ]; then
  SUMMARY+="===== 重启上下文存在：memory/重启上下文_$TODAY.md ====="$'\n'
  SUMMARY+="$(head -c 400 "$WORKSPACE/memory/重启上下文_$TODAY.md" 2>/dev/null)..."$'\n\n'
fi

# 5. 红线触发次数（最近 24h，反例监控）
REDLINE_FILE="$WORKSPACE/memory/$TODAY.md"
if [ -f "$REDLINE_FILE" ]; then
  COUNT_GUESS=$(grep -c "先猜再查\|红线.*触发\|第.*次反例\|越界\|顺手修" "$REDLINE_FILE" 2>/dev/null || echo 0)
  SUMMARY+="===== 红线触发监控（今日日志）====="$'\n'
  SUMMARY+="• 反例引用次数: $COUNT_GUESS"$'\n'
  if [ "$COUNT_GUESS" -gt 0 ]; then
    SUMMARY+="• ⚠️ 今日已触发反例, 回答项目状态前必 verify 文件"$'\n'
  fi
  SUMMARY+=$'\n'
fi

# 6. verify_state.sh 最近结果（如果运行过）
if [ -f "$WORKSPACE/memory/verify_state.log" ]; then
  SUMMARY+="===== verify_state.sh 最近结果 ====="$'\n'
  SUMMARY+="$(tail -5 "$WORKSPACE/memory/verify_state.log" 2>/dev/null)"$'\n'
fi

# 截断到 1500 字防止 context 膨胀
echo -e "$SUMMARY" | head -c 1500
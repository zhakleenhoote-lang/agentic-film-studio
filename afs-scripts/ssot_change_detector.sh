#!/usr/bin/env bash
# ssot_change_detector.sh — 检测 SSOT 改动，输出 diff 模板
# 用途：阻断 SSOT 编辑时返回 diff 模板 + SSOT 类型判断，让张大马决定
# 调用方：~/.openclaw/extensions/ai-director-discipline/index.ts

set -uo pipefail

WORKSPACE="${WORKSPACE_DIR:-/home/user/.openclaw/workspace}"
FILE="${1:-}"

if [ -z "$FILE" ]; then
  echo "用法: bash ssot_change_detector.sh <file_path>"
  echo "FILE 必填 — 被编辑的 SSOT 文件相对路径"
  exit 1
fi

echo "===== SSOT 改动拦截（红线 8）====="
echo "目标文件: $FILE"
echo "绝对路径: $WORKSPACE/$FILE"
echo ""

# 判断 SSOT 类型
TYPE="未知"
if [[ "$FILE" == *STATUS.yaml ]]; then
  TYPE="项目状态 SSOT (outputs/<project>/STATUS.yaml)"
elif [[ "$FILE" == "MEMORY.md" ]]; then
  TYPE="长期记忆 SSOT"
elif [[ "$FILE" == "AGENTS.md" ]]; then
  TYPE="工作纪律 SSOT"
elif [[ "$FILE" == *SKILL.md ]]; then
  TYPE="Agent SKILL SSOT (5 个 ai-director-*/SKILL.md)"
elif [[ "$FILE" == skills/knowledge/* ]]; then
  TYPE="知识库 SSOT (skills/knowledge/*.yaml)"
elif [[ "$FILE" == skills/knowledge/管线规范.yaml ]]; then
  TYPE="管线规范 SSOT (核心)"
elif [[ "$FILE" == scripts/verify_state.sh ]]; then
  TYPE="verify_state.sh 自动化脚本 SSOT"
elif [[ "$FILE" == scripts/ai_director_dryrun.sh ]]; then
  TYPE="ai_director_dryrun.sh 自动化脚本 SSOT"
fi

echo "SSOT 类型: $TYPE"
echo ""

# 输出文件当前 git diff（如果有 git）
if [ -d "$WORKSPACE/.git" ]; then
  echo "===== 当前 git diff（未提交改动）====="
  cd "$WORKSPACE"
  git diff -- "$FILE" 2>/dev/null | head -50 || echo "(no git diff)"
  echo ""
fi

echo "===== diff 模板（请按格式列出）====="
cat <<'EOF'
## 修改清单

### 改动 1
- **位置**: <行号 或 章节名>
- **改前**:
  ```
  <原文>
  ```
- **改后**:
  ```
  <新文>
  ```
- **理由**: <为什么改>
- **属于**: 
  - [ ] 纯 bug 修（自相矛盾 / 字段重复 / YAML 语法错）→ 可自主
  - [ ] 结构改动（新增段 / 改字段含义 / 加 changelog）→ 需批

EOF

echo "===== 决策树 ====="
cat <<'EOF'
是 SSOT 文件吗？
├── 否 → "看着办"（按清晰指令调工具）
└── 是 → 是纯 bug 修吗？
    ├── 是（自相矛盾 / 字段重复 / YAML 语法错）→ 可自主修
    └── 否（结构改动 / 字段含义改 / 加新段）→ 列 diff + 等批
EOF

echo ""
echo "===== 处理方式（请选 1）====="
echo "1. 列'修改清单 + diff' → 提交张大马批 → 批后再改"
echo "2. 如果是纯 bug 修 → 重试时张大马在线确认 → 直接改"
echo "3. 让张大马直接改（不通过 AI）"
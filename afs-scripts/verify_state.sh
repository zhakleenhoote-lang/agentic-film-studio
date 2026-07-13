#!/bin/bash
# verify_state.sh - 健忘症防护工具
# 主 agent 每次"已完成"前必跑
# 触发条件：任何"已完成 / 跑了 X 项 / 数据是 Y"陈述前
# 作者：凌（张大马 07/08 立红线要求）
# 2026-07-09 18:25:00 凌按张大马"执行终极方案"批 diff 改：加 [8] 红线 8 SSOT 改动 changelog 一致性 检查段（outputs/*/STATUS.yaml 缺 changelog 或 mtime 晚于最后 changelog at → 警告）

set -e

WORKSPACE="/home/user/.openclaw/workspace"
cd "$WORKSPACE" || { echo "❌ workspace 路径错误"; exit 1; }

echo "========================================="
echo "verify_state.sh — 健忘症防护"
echo "运行时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================="

ERRORS=0
WARNINGS=0

# 1. 检查当前活跃 sub-agent（文件系统判断，不靠 push）
echo ""
echo "[1] sub-agent 状态（文件系统判断）"
ACTIVE_SUBAGENTS=0
for AGENT in ai-director-auditor ai-director-render ai-director-script ai-director-storyboard; do
    if [ -d "$HOME/.openclaw/agents/$AGENT/sessions" ]; then
        # 仅检查最近 5 分钟内有更新的 session（避开历史 session 干扰）
        RUNNING=$(find "$HOME/.openclaw/agents/$AGENT/sessions" -name "*.json" -mmin -5 2>/dev/null | wc -l | tr -d ' ')
        TOTAL=$(find "$HOME/.openclaw/agents/$AGENT/sessions" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        echo "  $AGENT: 活跃(5min)=$RUNNING / 总数=$TOTAL"
        ACTIVE_SUBAGENTS=$((ACTIVE_SUBAGENTS + RUNNING))
    fi
done
if [ $ACTIVE_SUBAGENTS -gt 0 ]; then
    echo "  ⚠️  有 $ACTIVE_SUBAGENTS 个活跃 sub-agent，结果未定"
    WARNINGS=$((WARNINGS+1))
fi

# 2. 检查 0708 项目 STATUS.yaml 与实际产物一致性
echo ""
echo "[2] 0708 项目产物一致性"
STATUS_FILE="outputs/0708_咖啡店重逢_v2/STATUS.yaml"
if [ -f "$STATUS_FILE" ]; then
    STATUS=$(grep "^status:" "$STATUS_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    echo "  STATUS.yaml status: $STATUS"
    if [ "$STATUS" = "PAUSED_BY_ZHANGDA_MA" ]; then
        echo "  ⚠️  项目处于暂停状态"
        WARNINGS=$((WARNINGS+1))
    fi
    
    for DIR in 01_剧本 02_分镜 03_资产 04_渲染 05_审核; do
        if [ -d "outputs/0708_咖啡店重逢_v2/$DIR" ]; then
            COUNT=$(ls "outputs/0708_咖啡店重逢_v2/$DIR" 2>/dev/null | wc -l | tr -d ' ')
            echo "  $DIR/: $COUNT 个文件"
        else
            echo "  ❌ $DIR/ 不存在"
            ERRORS=$((ERRORS+1))
        fi
    done
    
    if [ -d "outputs/0708_咖啡店重逢_v2/04_渲染/clips" ]; then
        CLIPS=$(ls "outputs/0708_咖啡店重逢_v2/04_渲染/clips"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
        echo "  04_渲染/clips/: $CLIPS 个 mp4"
    else
        echo "  ⚠️  04_渲染/clips/ 不存在"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  ❌ STATUS.yaml 不存在"
    ERRORS=$((ERRORS+1))
fi

# 3. 检查关键文件存在性
echo ""
echo "[3] 关键文件存在性"
for FILE in MEMORY.md AGENTS.md skills/knowledge/管线规范.yaml memory/api-costs.md; do
    if [ -f "$FILE" ]; then
        SIZE=$(stat -f%z "$FILE" 2>/dev/null || echo "?")
        MTIME=$(stat -f "%Sm" "$FILE" 2>/dev/null || echo "?")
        echo "  ✓ $FILE ($SIZE bytes, $MTIME)"
    else
        echo "  ❌ $FILE 不存在"
        ERRORS=$((ERRORS+1))
    fi
done

# 4. 检查 19:46 锁定数据是否被错误修改
echo ""
echo "[4] 19:46 锁定数据校核"
if [ -f "MEMORY.md" ]; then
    if grep -q "28/46 元/百万\|28 元/百万.*46 元/百万" MEMORY.md; then
        echo "  ✓ MEMORY.md 含 28/46 真实值"
    else
        echo "  ❌ MEMORY.md 缺 28/46 真实值"
        ERRORS=$((ERRORS+1))
    fi
    # 检查"56 元/百万"是否还在（除锁定/更正/回滚/反例引用外）
    WRONG_REFS=$(grep "56 元/百万" MEMORY.md 2>/dev/null | grep -v "锁定\|更正\|回滚\|凑的\|错的\|反例" | wc -l | tr -d ' ')
    if [ "$WRONG_REFS" -gt 0 ]; then
        echo "  ⚠️  MEMORY.md 仍含 $WRONG_REFS 处未标注的'56 元/百万'引用（需人工检查）"
        WARNINGS=$((WARNINGS+1))
    else
        echo "  ✓ MEMORY.md 中'56 元/百万'均为反例/锁定/回滚引用（非错数据）"
    fi
fi

# 5. 检查 P0 修复状态
echo ""
echo "[5] P0 修复状态"
if [ -f "$STATUS_FILE" ]; then
    P0_D=$(awk '/^P0_D_status:/{flag=1; next} flag && /status:/{gsub(/[\"]/,"",$2); print $2; exit}' "$STATUS_FILE")
    P0_E=$(awk '/^P0_E_status:/{flag=1; next} flag && /status:/{gsub(/[\"]/,"",$2); print $2; exit}' "$STATUS_FILE")
    P0_C=$(awk '/^P0_C_integration_status:/{flag=1; next} flag && /status:/{gsub(/[\"]/,"",$2); print $2; exit}' "$STATUS_FILE")
    echo "  P0_D_status: ${P0_D:-未设置}"
    echo "  P0_E_status: ${P0_E:-未设置}"
    echo "  P0_C_integration_status: ${P0_C:-未设置}"
    [ "$P0_D" = "done" ] && echo "  ✓ P0-D 修复完成" || { echo "  ⚠️  P0-D 未完成"; WARNINGS=$((WARNINGS+1)); }
    [ "$P0_E" = "done" ] && echo "  ✓ P0-E 修复完成" || { echo "  ⚠️  P0-E 未完成"; WARNINGS=$((WARNINGS+1)); }
    [ "$P0_C" = "done" ] && echo "  ✓ P0-C 集成完成" || { echo "  ⚠️  P0-C 集成未完成"; WARNINGS=$((WARNINGS+1)); }
fi

# 6. 检查 api-costs 记录
echo ""
echo "[6] API 成本记录"
if [ -f "memory/api-costs.md" ]; then
    LINES=$(wc -l < "memory/api-costs.md" | tr -d ' ')
    echo "  memory/api-costs.md: $LINES 行"
    echo "  最近 3 笔："
    tail -3 "memory/api-costs.md" 2>/dev/null | sed 's/^/    /'
else
    echo "  ⚠️  memory/api-costs.md 不存在"
    WARNINGS=$((WARNINGS+1))
fi

# 7. 检查 P0 修复产物
echo ""
echo "[7] P0 修复产物"
P0_SCRIPTS=0
for SCRIPT in \
    "skills/ai-director-auditor/auditor/check_gate_consistency.py" \
    "skills/ai-director-auditor/auditor/live_reverify_gate.py" \
    "skills/ai-director-auditor/auditor/stamp_gate_with_input_hashes.py" \
    "skills/ai-director-auditor/auditor/verify_input_hashes.py" \
    "skills/ai-director-post/post.py"; do
    if [ -f "$SCRIPT" ]; then
        SIZE=$(stat -f%z "$SCRIPT" 2>/dev/null || echo "?")
        echo "  ✓ $SCRIPT ($SIZE bytes)"
        P0_SCRIPTS=$((P0_SCRIPTS+1))
    else
        echo "  ❌ $SCRIPT 不存在"
        ERRORS=$((ERRORS+1))
    fi
done
echo "  P0 脚本存在数: $P0_SCRIPTS/5"

# 8. 红线 8 SSOT 改动 changelog 一致性（终极方案集成）
echo ""
echo "[8] 红线 8 SSOT 改动 changelog 一致性"
SSOT_STATUS_FILES=$(find outputs -name "STATUS.yaml" -type f 2>/dev/null)
REDLINE8_OK=0
REDLINE8_WARN=0
for SSF in $SSOT_STATUS_FILES; do
    if [ -f "$SSF" ]; then
        HAS_CHANGELOG=$(grep -c "^changelog:" "$SSF" 2>/dev/null; true)
        HAS_CHANGELOG="${HAS_CHANGELOG:-0}"
        FILE_MTIME_EPOCH=$(stat -f %m "$SSF" 2>/dev/null || echo 0)

        if [ "$HAS_CHANGELOG" -eq 0 ]; then
            echo "  ⚠️  $SSF 缺 changelog 段（红线 8 必填）"
            WARNINGS=$((WARNINGS+1))
            REDLINE8_WARN=$((REDLINE8_WARN+1))
        else
            # 提取最后一条 changelog at: 时间
            LAST_AT=$(awk '/^changelog:/{flag=1; next} flag && /^  - at:/{at=$0; gsub(/.*at: *"|"/, "", at); print at; flag=0}' "$SSF" | tail -1)
            if [ -z "$LAST_AT" ]; then
                echo "  ⚠️  $SSF 有 changelog 但无 at 条目"
                WARNINGS=$((WARNINGS+1))
                REDLINE8_WARN=$((REDLINE8_WARN+1))
            else
                # macOS date 命令：date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_AT" "+%s"
                LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_AT" "+%s" 2>/dev/null || echo 0)
                if [ "$FILE_MTIME_EPOCH" -gt "$LAST_EPOCH" ] && [ "$LAST_EPOCH" -gt 0 ]; then
                    DIFF_SEC=$((FILE_MTIME_EPOCH - LAST_EPOCH))
                    if [ "$DIFF_SEC" -gt 60 ]; then
                        echo "  ⚠️  $SSF mtime 晚于 changelog 最后条目 ${DIFF_SEC}s（可能漏写 changelog）"
                        WARNINGS=$((WARNINGS+1))
                        REDLINE8_WARN=$((REDLINE8_WARN+1))
                    else
                        echo "  ✓ $SSF changelog 一致（差异 ${DIFF_SEC}s 在 60s 容差内）"
                        REDLINE8_OK=$((REDLINE8_OK+1))
                    fi
                else
                    echo "  ✓ $SSF changelog 一致"
                    REDLINE8_OK=$((REDLINE8_OK+1))
                fi
            fi
        fi
    fi
done
echo "  红线 8 状态: $REDLINE8_OK OK / $REDLINE8_WARN 警告"

# 汇总
echo ""
echo "========================================="
echo "汇总: $ERRORS 错误, $WARNINGS 警告"
echo "========================================="
if [ $ERRORS -gt 0 ]; then
    echo "❌ 验证失败，请先修复错误再继续"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo "⚠️  验证通过（带警告），警告项需关注"
    exit 0
else
    echo "✅ 验证通过（无错误无警告）"
    exit 0
fi

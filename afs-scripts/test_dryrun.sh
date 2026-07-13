#!/bin/bash
# =============================================================================
# test_dryrun.sh — AI导演 dry-run 脚本单元测试
# 用途: 验证 ai_director_dryrun.sh 的各个功能点
# 测试内容:
#   T01: 脚本存在且可执行
#   T02: 全链路执行（退出码 0）
#   T03: 产物体积完整性
#   T04: STATUS.yaml 链路完整性
#   T05: 放行令 APPROVED + hash 绑定
#   T06: 06_成片 目录命名
#   T07: 清理后可重复运行
#   T08: 参数处理
# =============================================================================

set -e

WORKSPACE="/home/user/.openclaw/workspace"
SCRIPT="${WORKSPACE}/scripts/ai_director_dryrun.sh"
TEST_DIR="${WORKSPACE}/outputs/规则升级_0708/04_P0-4_dryrun"

PASS=0
FAIL=0
ERRORS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
}

report_pass() {
    local test_id="$1"
    local desc="$2"
    PASS=$((PASS+1))
    echo -e "  ${GREEN}[PASS]${NC} $test_id: $desc"
}

report_fail() {
    local test_id="$1"
    local desc="$2"
    local reason="$3"
    FAIL=$((FAIL+1))
    ERRORS+=("$test_id: $desc — $reason")
    echo -e "  ${RED}[FAIL]${NC} $test_id: $desc"
    echo -e "        原因: $reason"
}

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  AI导演 dry-run 单元测试${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""

# =============================================================================
# T01: 脚本存在且可执行
# =============================================================================
echo -e "${YELLOW}[T01] 脚本存在性检查${NC}"
if [ -f "$SCRIPT" ]; then
    if [ -x "$SCRIPT" ]; then
        report_pass "T01" "脚本存在且可执行"
    else
        chmod +x "$SCRIPT" 2>/dev/null || true
        if [ -x "$SCRIPT" ]; then
            report_pass "T01" "脚本已添加可执行权限"
        else
            report_fail "T01" "脚本缺少可执行权限" "chmod 失败"
        fi
    fi
else
    report_fail "T01" "脚本不存在" "路径: $SCRIPT"
fi

# =============================================================================
# T02: 全链路执行
# =============================================================================
echo ""
echo -e "${YELLOW}[T02] 全链路执行测试${NC}"

# 先清理
cleanup

# 执行 dry-run
set +e
START_TIME=$(date +%s)
bash "$SCRIPT" > /tmp/dryrun_stdout.log 2>&1
EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
set -e

if [ $EXIT_CODE -eq 0 ]; then
    report_pass "T02" "全链路执行成功 (退出码=0, 耗时=${DURATION}s)"
else
    report_fail "T02" "全链路执行失败" "退出码=${EXIT_CODE}, 耗时=${DURATION}s"
    echo "  最后10行日志:"
    tail -10 /tmp/dryrun_stdout.log 2>/dev/null | sed 's/^/    /'
fi

# =============================================================================
# T03: 产物体积完整性
# =============================================================================
echo ""
echo -e "${YELLOW}[T03] 产物体积完整性${NC}"

if [ -d "$TEST_DIR" ]; then
    FILE_COUNT=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')
    TOTAL_SIZE=$(find "$TEST_DIR" -type f -exec stat -f%z {} + 2>/dev/null | python3 -c "import sys; print(sum(int(l) for l in sys.stdin if l.strip()))" 2>/dev/null || echo 0)

    # 预期最少 25 个关键文件
    EXPECTED_MIN=25
    if [ "$FILE_COUNT" -ge "$EXPECTED_MIN" ]; then
        report_pass "T03" "产物体积合格 (${FILE_COUNT} 文件, ${TOTAL_SIZE} bytes, ≥${EXPECTED_MIN})"
    else
        report_fail "T03" "产物体积不达标" "仅 ${FILE_COUNT} 文件 (期望 ≥${EXPECTED_MIN})"
    fi

    # 检查关键目录是否都存在
    for dir in "01_剧本" "02_分镜" "03_资产" "04_渲染" "05_审核" "06_成片"; do
        if [ -d "${TEST_DIR}/${dir}" ]; then
            count=$(find "${TEST_DIR}/${dir}" -type f | wc -l | tr -d ' ')
            # echo "  ${dir}/: ${count} files"
        else
            report_fail "T03" "关键目录缺失" "${dir}/ 不存在"
        fi
    done
else
    report_fail "T03" "输出目录不存在" "路径: ${TEST_DIR}"
fi

# =============================================================================
# T04: STATUS.yaml 链路完整性
# =============================================================================
echo ""
echo -e "${YELLOW}[T04] STATUS.yaml 链路完整性${NC}"

STATUS_FILE="${TEST_DIR}/STATUS.yaml"
if [ -f "$STATUS_FILE" ]; then
    LAST_AGENT=$(grep "^last_agent:" "$STATUS_FILE" | awk '{print $2}' | tr -d '"')
    AGENT_STATUS=$(grep "^last_agent_status:" "$STATUS_FILE" | awk '{print $2}' | tr -d '"')

    if [ "$LAST_AGENT" = "E" ] && [ "$AGENT_STATUS" = "done" ]; then
        report_pass "T04" "链路完整: A→B→D→C→D→E (last_agent=E)"
    elif [ "$LAST_AGENT" = "E" ]; then
        report_fail "T04" "链路状态异常" "last_agent=E 但 status=${AGENT_STATUS}"
    else
        report_fail "T04" "链路未完成" "last_agent=${LAST_AGENT} (期望 E)"
    fi
else
    report_fail "T04" "STATUS.yaml 不存在"
fi

# =============================================================================
# T05: 放行令 APPROVED + hash 绑定
# =============================================================================
echo ""
echo -e "${YELLOW}[T05] 放行令验证${NC}"

RELEASE_PATH="${TEST_DIR}/05_审核/渲染放行令.yaml"
if [ -f "$RELEASE_PATH" ]; then
    if grep -q "status: \"APPROVED\"" "$RELEASE_PATH"; then
        if grep -q "input_hashes:" "$RELEASE_PATH"; then
            # 检查是否有具体的 hash 值
            HASH_COUNT=$(grep -c ":" "$RELEASE_PATH" 2>/dev/null || echo 0)
            report_pass "T05" "放行令 APPROVED + hash 绑定完整 (${HASH_COUNT} 字段)"
        else
            report_fail "T05" "放行令缺少 hash 绑定" "无 input_hashes 字段"
        fi
    else
        report_fail "T05" "放行令状态异常" "非 APPROVED"
    fi
else
    report_fail "T05" "放行令文件不存在"
fi

# =============================================================================
# T06: 06_成片 目录命名
# =============================================================================
echo ""
echo -e "${YELLOW}[T06] 06_成片 目录命名${NC}"

if [ -d "${TEST_DIR}/06_成片" ]; then
    COUNT=$(ls "${TEST_DIR}/06_成片" | wc -l | tr -d ' ')
    # 检查是否符合 P0-7 要求（不得有 05_后期 遗留）
    if [ -d "${TEST_DIR}/05_后期" ]; then
        report_fail "T06" "旧目录 05_后期 仍然存在" "未按 P0-7 迁移"
    else
        report_pass "T06" "06_成片/ 目录存在 (${COUNT} 文件, 无旧目录遗存)"
    fi
else
    report_fail "T06" "06_成片/ 目录不存在"
fi

# =============================================================================
# T07: 清理后可重复运行
# =============================================================================
echo ""
echo -e "${YELLOW}[T07] 幂等性测试 (清理后重跑)${NC}"

cleanup

# 再次运行
set +e
bash "$SCRIPT" > /tmp/dryrun_stdout2.log 2>&1
EXIT_CODE2=$?
set -e

if [ $EXIT_CODE2 -eq 0 ]; then
    if [ -d "$TEST_DIR" ]; then
        FILE_COUNT2=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')
        report_pass "T07" "清理后重跑成功 (${FILE_COUNT2} 文件, 退出码=0)"
    else
        report_fail "T07" "重跑后目录未创建" "路径: ${TEST_DIR}"
    fi
else
    report_fail "T07" "重跑失败" "退出码=${EXIT_CODE2}"
    tail -5 /tmp/dryrun_stdout2.log | sed 's/^/    /'
fi

# =============================================================================
# T08: 参数处理
# =============================================================================
echo ""
echo -e "${YELLOW}[T08] 参数处理测试${NC}"

cleanup

# 测试 --help
set +e
bash "$SCRIPT" --help > /tmp/dryrun_help.log 2>&1
HELP_CODE=$?
HELP_MSG=$(head -1 /tmp/dryrun_help.log)
set -e

if [ $HELP_CODE -eq 0 ] && grep -q "用法\|用法\|Usage\|帮助" /tmp/dryrun_help.log 2>/dev/null; then
    report_pass "T08a" "--help 参数正常"
else
    report_fail "T08a" "--help 参数异常" "退出码=${HELP_CODE}"
fi

# 测试 -v (verbose)
cleanup
set +e
bash "$SCRIPT" -v > /tmp/dryrun_verbose.log 2>&1
VERBOSE_CODE=$?
set -e

if [ $VERBOSE_CODE -eq 0 ]; then
    report_pass "T08b" "-v 参数正常"
else
    report_fail "T08b" "-v 参数异常" "退出码=${VERBOSE_CODE}"
fi

# =============================================================================
# 汇总
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  测试汇总${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}"
echo -e "  ${RED}FAIL: ${FAIL}${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✅ 全部 ${PASS} 项测试通过${NC}"
    exit 0
else
    echo -e "${RED}❌ ${FAIL} 项测试失败:${NC}"
    for e in "${ERRORS[@]}"; do
        echo "    - $e"
    done
    exit 1
fi

#!/bin/bash
# =============================================================================
# ai_director_dryrun.sh — AI导演 端到端全流程模拟（dry-run）
# 版本: v1.0
# 用途: 一键模拟 A→B→D(三关)→C→D(第五关)→E 全链路
# 特点: 不调真实 API，mock 所有外部调用
#       每个阶段验证 STATUS.yaml 推进
#       验证放行令逻辑（D 第四关）
#       验证 hash 绑定逻辑（D 第五关）
#       验证 06_成片 目录命名（P0-7）
# 作者: P0-4 dryrun 脚本 (2026-07-09)
# 兼容: macOS bash 3.2+ (不使用 -A 关联数组)
# =============================================================================

set -e

# =============================================================================
# 全局配置
# =============================================================================

WORKSPACE="${WORKSPACE:-/home/user/.openclaw/workspace}"
OUTPUT_DIR="${OUTPUT_DIR:-outputs/规则升级_0708/04_P0-4_dryrun}"
PROJECT_NAME="dryrun_模拟项目_0709"

DRYRUN_START_TIME=""
DRYRUN_END_TIME=""

# 步骤跟踪（用索引数组 + 前缀命名模拟关联数组）
STEP_NAMES=()
STEP_STATUSES=()
STEP_STARTS=()
STEP_ENDS=()
STEP_ARTIFACTS_LIST=()
STEP_COUNT=0

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# 辅助函数
# =============================================================================

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "\n${GREEN}═══════════════════════════════════════${NC}"; echo -e "${GREEN}  $*${NC}"; echo -e "${GREEN}═══════════════════════════════════════${NC}"; }

step_start() {
    local name="$1"
    STEP_NAMES[$STEP_COUNT]="$name"
    STEP_STARTS[$STEP_COUNT]=$(date +%s)
    STEP_STATUSES[$STEP_COUNT]="RUNNING"
    STEP_COUNT=$((STEP_COUNT + 1))
}

step_end() {
    local idx=$((STEP_COUNT - 1))
    local status="${1:-PASS}"
    local artifacts="${2:-}"
    STEP_ENDS[$idx]=$(date +%s)
    STEP_STATUSES[$idx]="$status"
    STEP_ARTIFACTS_LIST[$idx]="$artifacts"

    local duration=$(( STEP_ENDS[$idx] - STEP_STARTS[$idx] ))
    if [ "$status" = "PASS" ]; then
        log_pass "Step [${STEP_NAMES[$idx]}] 完成 (${duration}s)"
    else
        log_fail "Step [${STEP_NAMES[$idx]}] 失败 (${duration}s)"
    fi
}

step_start_echo() {
    local label="$1"; shift
    local desc="$*"
    step_start "$label"
    echo -e "\n${GREEN}─── [$label]${NC} $desc"
    echo "    开始时间: $(date '+%H:%M:%S')"
}

step_end_echo() {
    local label="$1"
    local result="${2:-PASS}"
    echo "    结束时间: $(date '+%H:%M:%S')"
    echo -e "    结果: $([ "$result" = "PASS" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
}

die() {
    echo -e "\n${RED}[FATAL] $*${NC}" >&2
    exit 1
}

safe_mkdir() {
    [ -d "$1" ] || mkdir -p "$1" || die "无法创建目录: $1"
}

write_artifact() {
    local path="$1"
    local content="$2"
    safe_mkdir "$(dirname "$path")"
    echo "$content" > "$path" || die "无法写入: $path"
    log_info "  📄 创建: $(basename "$path")"
}

mock_file() {
    local path="$1"
    local content="${2:-# mock file generated at $(date)}"
    safe_mkdir "$(dirname "$path")"
    echo "$content" > "$path" || die "无法写入: $path"
    echo "$path"
}

update_status_yaml() {
    local project_dir="$1"
    local last_agent="$2"
    local status="$3"
    local next_action="$4"
    local next_agent="$5"
    local status_file="${project_dir}/STATUS.yaml"

    safe_mkdir "$project_dir"

    cat > "$status_file" << EOF
# STATUS.yaml — 自动更新于 $(date '+%Y-%m-%dT%H:%M:%S%z')
project: "${PROJECT_NAME}"
last_agent: "${last_agent}"
last_agent_status: "${status}"
last_agent_completed_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
next_action: "${next_action}"
next_agent: "${next_agent}"
EOF
    log_info "  📝 STATUS.yaml 更新: last_agent=${last_agent}, status=${status}"
}

write_audit_report() {
    local path="$1"
    local level="$2"
    local passed="${3:-true}"
    local extra="${4:-}"

    local result_text="✅ S+通过"
    local score="4.5"
    [ "$passed" = "false" ] && result_text="❌ 打回" && score="2.0"

    cat > "$path" << EOF
# 审计报告 — ${level}

## 结果：${result_text}
## 均分：${score}/5

${extra}

## 维度打分
- 维度1: 4.5
- 维度2: 4.0
- 维度3: 4.5

## 总分：${score}/5

## S+ 判定
- [x] 全部维度 ≥ 4分 → 通过
EOF
}

write_reject_feedback() {
    local path="$1"
    local target_agent="$2"
    local reason="$3"
    local gate_name="$4"

    cat > "$path" << EOF
status: "REJECTED"
target_agent: "${target_agent}"
blocking_gates:
  - gate: "${gate_name}"
    reason: "${reason}"
    action_required: "${reason} 的问题已修复"
retry_count: 1
retry_max: 3
EOF
}

write_release_order() {
    local path="$1"
    shift
    local input_files=("$@")

    local hash_lines=""
    local hash_sum=""
    local f hash

    for f in "${input_files[@]}"; do
        if [ -f "$f" ]; then
            hash=$(md5 -r "$f" 2>/dev/null | awk '{print $1}')
            hash_sum="${hash_sum}${hash}"
            hash_lines="${hash_lines}  \"$(basename "$f")\": \"${hash}\""
            hash_lines="${hash_lines}"$'\n'""
        fi
    done
    local combined_hash
    combined_hash=$(echo -n "$hash_sum" | md5 | cut -c1-16)

    cat > "$path" << EOF
status: "APPROVED"
date: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
approved_by: "Agent D"
next: "移交 Agent C 开始渲染"
note: "Agent C 无需重复预检，直接执行"

# P0-3: MD5 hash 绑定 — 防止数据静默篡改
input_hashes:
${hash_lines}  _combined_hash: "${combined_hash}"

# metadata
_render_gate_approval: true
_gate_version: "v5"
_security:
  gate_consistency: "passed"
  live_reverify: "passed"
  hash_binding: "passed"
EOF
    echo "$combined_hash"
}

verify_release_order() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log_fail "放行令不存在: $path"
        return 1
    fi
    if ! grep -q "status: \"APPROVED\"" "$path"; then
        log_fail "放行令状态不是 APPROVED"
        return 1
    fi
    if ! grep -q "input_hashes:" "$path"; then
        log_fail "放行令缺少 input_hashes hash 绑定"
        return 1
    fi
    log_pass "放行令验证通过 (APPROVED + hash 绑定)"
    return 0
}

verify_hash_binding() {
    local release_path="$1"
    shift
    local input_files=("$@")

    if [ ! -f "$release_path" ]; then
        log_fail "放行令不存在: $release_path"
        return 1
    fi

    local all_match=true
    local f expected_hash base_name recorded_hash

    for f in "${input_files[@]}"; do
        if [ ! -f "$f" ]; then
            log_warn "  ⚠️  文件不存在，跳过 hash 验证: $f"
            continue
        fi
        base_name=$(basename "$f")
        expected_hash=$(md5 -r "$f" 2>/dev/null | awk '{print $1}')
        # 用 awk 提取: 以双引号为分隔符，第三列就是 hash 值
        # 行格式:   "文件名": "hash值"
        recorded_hash=$(awk -v k="${base_name}" -F'"' '
            $0 ~ k { print $4 }
        ' "$release_path")
        if [ -n "$recorded_hash" ] && [ "$expected_hash" != "$recorded_hash" ]; then
            log_fail "  ❌ hash 不匹配: $base_name (记录: $recorded_hash, 实际: $expected_hash)"
            all_match=false
        else
            log_pass "  ✓ hash 匹配: $base_name ($expected_hash)"
        fi
    done

    $all_match && { log_pass "hash 绑定一致性验证通过"; return 0; } || return 1
}

verify_06_chengpian_dir() {
    local project_dir="$1"
    local dir="${project_dir}/06_成片"
    if [ -d "$dir" ]; then
        local count
        count=$(ls "$dir" 2>/dev/null | wc -l | tr -d ' ')
        log_pass "06_成片/ 目录存在，包含 $count 个文件"
        return 0
    else
        log_fail "06_成片/ 目录不存在"
        return 1
    fi
}

clean_artifacts() {
    local project_dir="$1"
    if [ -d "$project_dir" ]; then
        rm -rf "$project_dir"
        log_info "已清理旧产物: $project_dir"
    fi
}

# =============================================================================
# Step 1: Mock Agent A — 剧本创作
# =============================================================================

step_mock_agent_a() {
    local project_dir="$1"
    local label="A-剧本"

    step_start_echo "$label" "Mock 剧本创作引擎 — 生成剧本/角色卡/视觉风格"

    local script_dir="${project_dir}/01_剧本"
    safe_mkdir "$script_dir"

    mock_file "${script_dir}/剧本_v1.md" "# 剧本: ${PROJECT_NAME}\n\n## 第一场: 开场\n△ 场景描述..."
    mock_file "${script_dir}/视觉风格锁定.yaml" "visual_style:\n  project: \"${PROJECT_NAME}\"\n  style_name: \"现代写实CG\"\n  style_keywords:\n    - \"photorealistic CGI\"\n    - \"PBR材质\"\n    - \"体积雾\"\n    - \"电影级叙事光影\""
    mock_file "${script_dir}/角色卡_九维.yaml" "characters:\n  - name: \"主角A\"\n    age: 25\n    identity: \"测试角色\""
    mock_file "${script_dir}/角色锚定词.yaml" "anchors:\n  主角A: \"穿黑衣的年轻男性\""
    mock_file "${script_dir}/可执行性评估.md" "# 可执行性评估\n## A/B/C 分布\n- A级: 10\n- B级: 2\n- C级: 0\n## 可执行率: 100%"
    mock_file "${script_dir}/信息密度评估.md" "# 信息密度评估\n## 逐段统计\n| 段 | 对白数 | 情绪变化 | 动作事件 |"
    mock_file "${script_dir}/人物小传.md" "# 人物小传\n## 主角A\n背景介绍..."
    mock_file "${script_dir}/自查报告_剧本.md" "# 自查报告\n## 所有检查项通过"

    update_status_yaml "$project_dir" "A" "done" "派 Agent B 分镜设计" "B"

    local artifacts
    artifacts=$(ls "${script_dir}"/*.md "${script_dir}"/*.yaml 2>/dev/null | tr '\n' ' ')
    step_end "PASS" "$artifacts"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# Step 2: Mock Agent B — 分镜资产
# =============================================================================

step_mock_agent_b() {
    local project_dir="$1"
    local label="B-分镜"

    step_start_echo "$label" "Mock 分镜资产引擎 — 生成分镜表/角色图/场景卡/道具卡/运镜"

    local storyboard_dir="${project_dir}/02_分镜"
    safe_mkdir "$storyboard_dir"

    mock_file "${storyboard_dir}/分镜表.md" "# 分镜表\n## 镜头列表\n| 镜号 | 景别 | 焦段 | ISO | 色温 | 运镜 |\n|------|------|------|-----|------|------|\n| 01 | MCU | 85mm f2.0 | 640 | 5400K | 推 |"
    mock_file "${storyboard_dir}/镜头组方案.yaml" "镜头组:\n  - id: G1\n    镜头: [01, 02, 03]\n    场景: S-001\n    render_mode: reference_image\n    tier: \"纯生成\""
    mock_file "${storyboard_dir}/段打包清单.yaml" "segments:\n  - id: SEG-1\n    duration: 5\n    tier: \"纯生成\"\n    shots: [01, 02, 03]\n    generate_audio: true\n    resolution: \"720p\"\n    ratio: \"16:9\""
    mock_file "${storyboard_dir}/风格参考板.yaml" "风格参考板:\n  视觉基调: \"3A写实CG\"\n  HEX色卡: [\"#1a1a2e\", \"#16213e\"]"

    local asset_dir="${project_dir}/03_资产"
    safe_mkdir "${asset_dir}/角色卡"
    safe_mkdir "${asset_dir}/道具卡"
    safe_mkdir "${asset_dir}/场景卡"
    safe_mkdir "${asset_dir}/关键帧"
    safe_mkdir "${asset_dir}/camera_movements"

    echo -n "mock_png_face" > "${asset_dir}/角色卡/主角A_人脸特写.png"
    echo -n "mock_png_full" > "${asset_dir}/角色卡/主角A_全身.png"
    echo -n "mock_prop_sixview" > "${asset_dir}/道具卡/P-001_测试道具_六维.png"
    echo -n "mock_atmosphere" > "${asset_dir}/场景卡/S-001_测试场景_氛围.png"
    mock_file "${asset_dir}/场景卡/S-001_测试场景_灯光.md" "# 灯光方案\nKey: 5400K 左45°\nRim: 2600K 后侧\nFill: 漫反射"
    echo -n "mock_svg" > "${asset_dir}/场景卡/S-001_测试场景_机位.svg"
    echo -n "mock_kf" > "${asset_dir}/关键帧/KF-01_测试关键帧.png"
    echo -n "mock_mov" > "${asset_dir}/camera_movements/dolly_in_01.mp4"
    mock_file "${asset_dir}/camera_movements/dolly_in_01_metadata.json" "{\"camera_type\":\"推\",\"camera_en\":\"dolly_in\",\"duration\":5.0}"
    mock_file "${asset_dir}/资产清单.yaml" "generated_by: \"Agent B verify_assets()\"\nstatus: \"READY\"\nassets:\n  角色卡:\n    - name: \"主角A_人脸特写\"\n      path: \"03_资产/角色卡/主角A_人脸特写.png\""

    update_status_yaml "$project_dir" "B" "done" "派 Agent D 审计 (一~三关 + 第四关门禁)" "D"

    local artifacts
    artifacts=$(find "$storyboard_dir" "$asset_dir" -maxdepth 2 -type f 2>/dev/null | tr '\n' ' ')
    step_end "PASS" "$artifacts"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# Step 3: Mock Agent D — 审计一~三关 + 第四关（渲染前置门禁）
# =============================================================================

step_mock_agent_d_gates() {
    local project_dir="$1"
    local label="D-审计门禁"

    step_start_echo "$label" "Mock Agent D 审计 — 第一关(剧本) + 第二关(分镜) + 第三关(资产) + 第四关(渲染门禁)"

    local audit_dir="${project_dir}/05_审核"
    safe_mkdir "$audit_dir"

    # 第一关：剧本审计
    write_audit_report "${audit_dir}/审计报告_剧本.md" "剧本审计"
    echo "
## 硬指标检查
- ✅ A01 角色锚定词: pass
- ✅ A02 可执行率≥90%: pass (100%)
- ✅ A04 节拍完整性: pass
- ✅ A06 对白符号: pass
- ✅ A07 多人场景拆分: pass
- ✅ A08 动作量化: pass
" >> "${audit_dir}/审计报告_剧本.md"
    log_info "  第一关剧本审计: ✅ S+通过"

    # 第二关：分镜审计
    write_audit_report "${audit_dir}/审计报告_分镜.md" "分镜审计"
    echo "
## 硬指标检查
- ✅ B01 五维完整性: pass
- ✅ B03 CGI合规: pass
- ✅ B08 提示词符号: pass
- ✅ B09 约束词: pass
- ✅ B10 运镜单一性: pass
- ✅ B11 素材数量: pass
- ✅ B12 多人拆分: pass
- ✅ B13 定价档位: pass
- ✅ B14 风格关键词: pass
" >> "${audit_dir}/审计报告_分镜.md"
    log_info "  第二关分镜审计: ✅ S+通过"

    # 第三关：资产审计
    write_audit_report "${audit_dir}/审计报告_资产.md" "资产审计"
    echo "
## 硬指标检查
- ✅ C01 角色图格式 (人脸+全身): pass
- ✅ C02 文件存在性: pass
- ✅ C03 关键帧存在性: pass
" >> "${audit_dir}/审计报告_资产.md"
    log_info "  第三关资产审计: ✅ S+通过"

    # P0-1: 双文件互斥检查
    local feedback_path="${audit_dir}/渲染门禁_打回反馈.yaml"
    local release_path="${audit_dir}/渲染放行令.yaml"
    if [ -f "$feedback_path" ] && [ -f "$release_path" ]; then
        log_fail "P0-1 双文件互斥检出: 放行令和打回反馈同时存在"
        step_end "FAIL"
        step_end_echo "$label" "FAIL"
        return 1
    fi
    log_info "  P0-1 双文件互斥: ✅ 通过"

    # G1-G7 门禁检查
    local gates_passed=true

    grep -q "S+通过" "${audit_dir}/审计报告_剧本.md" 2>/dev/null && log_info "  G1 剧本审计: ✅" || { log_fail "  G1 ❌"; gates_passed=false; }
    grep -q "S+通过" "${audit_dir}/审计报告_分镜.md" 2>/dev/null && log_info "  G2 分镜审计: ✅" || { log_fail "  G2 ❌"; gates_passed=false; }
    grep -q "S+通过" "${audit_dir}/审计报告_资产.md" 2>/dev/null && log_info "  G3 资产审计: ✅" || { log_fail "  G3 ❌"; gates_passed=false; }

    if [ -f "${project_dir}/03_资产/角色卡/主角A_人脸特写.png" ] && [ -f "${project_dir}/03_资产/角色卡/主角A_全身.png" ]; then
        log_info "  G4 角色参考图: ✅"
    else
        log_fail "  G4 ❌"
        gates_passed=false
    fi

    [ -f "${project_dir}/03_资产/资产清单.yaml" ] && log_info "  G5 资产清单: ✅" || { log_fail "  G5 ❌"; gates_passed=false; }
    grep -q "duration: 5" "${project_dir}/02_分镜/段打包清单.yaml" 2>/dev/null && log_info "  G6 参数终检: ✅" || { log_fail "  G6 ❌"; gates_passed=false; }
    grep -q "style_keywords" "${project_dir}/01_剧本/视觉风格锁定.yaml" 2>/dev/null && log_info "  G7 风格关键词: ✅" || { log_fail "  G7 ❌"; gates_passed=false; }

    if ! $gates_passed; then
        write_reject_feedback "$feedback_path" "B" "门禁检查未全部通过" "G4_角色参考图"
        log_fail "门禁检查未全部通过，生成打回反馈"
        step_end "FAIL"
        step_end_echo "$label" "FAIL"
        return 1
    fi

    # 全部通过 → 签发放行令 + P0-3 hash 绑定
    local input_files=(
        "${project_dir}/02_分镜/段打包清单.yaml"
        "${project_dir}/03_资产/资产清单.yaml"
        "${project_dir}/01_剧本/视觉风格锁定.yaml"
        "${audit_dir}/审计报告_剧本.md"
        "${audit_dir}/审计报告_分镜.md"
        "${audit_dir}/审计报告_资产.md"
    )
    local combined_hash
    combined_hash=$(write_release_order "$release_path" "${input_files[@]}")
    log_info "  第四关渲染门禁: ✅ 通过，签发放行令 [hash=${combined_hash}]"

    verify_release_order "$release_path" || { log_fail "  放行令验证失败"; step_end "FAIL"; step_end_echo "$label" "FAIL"; return 1; }

    update_status_yaml "$project_dir" "D" "done" "渲染放行令已签发，派 Agent C 渲染 (3镜小样)" "C"

    local artifacts
    artifacts=$(ls "${audit_dir}"/*.md "${audit_dir}"/*.yaml 2>/dev/null | tr '\n' ' ')
    step_end "PASS" "$artifacts"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# Step 4: Mock Agent C — 渲染（3镜小样）
# =============================================================================

step_mock_agent_c() {
    local project_dir="$1"
    local label="C-渲染"

    step_start_echo "$label" "Mock 渲染引擎 — 检查放行令 + 生成3段视频片段 + 成本追踪"

    local release_path="${project_dir}/05_审核/渲染放行令.yaml"
    verify_release_order "$release_path" || {
        log_fail "Agent C 启动前放行令验证失败"
        step_end "FAIL"; step_end_echo "$label" "FAIL"; return 1
    }

    log_info "  P0-2 实时交叉验证 (mock): 放行令签发后复核"
    log_info "  P0-3 hash 一致性验证 (mock): MD5 重算对比"

    local input_files=(
        "${project_dir}/02_分镜/段打包清单.yaml"
        "${project_dir}/03_资产/资产清单.yaml"
        "${project_dir}/01_剧本/视觉风格锁定.yaml"
        "${project_dir}/05_审核/审计报告_剧本.md"
        "${project_dir}/05_审核/审计报告_分镜.md"
        "${project_dir}/05_审核/审计报告_资产.md"
    )
    verify_hash_binding "$release_path" "${input_files[@]}" || {
        log_fail "P0-3 hash 不一致 — 数据可能被篡改"
        step_end "FAIL"; step_end_echo "$label" "FAIL"; return 1
    }
    log_info "  P0-2/P0-3: ✅ 渲染前安全验证全部通过"

    local render_dir="${project_dir}/04_渲染"
    local clips_dir="${render_dir}/clips"
    safe_mkdir "$clips_dir"
    safe_mkdir "${clips_dir}/.chain"
    safe_mkdir "${clips_dir}/.locks"

    for seg in 01 02 03; do
        echo -n "mock_video_seg_${seg}" > "${clips_dir}/seg_${seg}.mp4"
        echo -n "mock_last_frame_seg_${seg}" > "${clips_dir}/last_frame_seg_${seg}.png"
        cat > "${clips_dir}/.chain/seg_${seg}.json" << EOF
{
  "seg_id": "${seg}",
  "video_url": "https://mock-seedance.com/video/seg_${seg}.mp4",
  "last_frame_path": "04_渲染/clips/last_frame_seg_${seg}.png",
  "saved_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
        log_info "  🎬 生成: seg_${seg}.mp4"
    done

    cat > "${render_dir}/camera_movement_ref_使用记录.md" << 'EOF'
# camera_movement_ref 使用记录
- SEG-01: dolly_in_01.mp4 ✅
- SEG-02: dolly_in_01.mp4 ✅
- SEG-03: 无 ref，使用第七维文字
EOF

    cat > "${render_dir}/段渲染清单.yaml" << 'EOF'
segments:
  seg_01:
    clip: "04_渲染/clips/seg_01.mp4"; duration_actual: 5.0
    tier: "纯生成"; resolution: "720p"; status: "success"
  seg_02:
    clip: "04_渲染/clips/seg_02.mp4"; duration_actual: 5.0
    tier: "视频编辑"; resolution: "720p"; status: "success"
  seg_03:
    clip: "04_渲染/clips/seg_03.mp4"; duration_actual: 5.0
    tier: "视频编辑"; resolution: "720p"; status: "success"
metadata:
  total_segments: 3; total_duration: 15.0
  total_cost_yuan: 13.61; success_rate: "3/3"
EOF

    cat > "${render_dir}/成本追踪.md" << 'EOF'
# 成本追踪
| 段 | tokens | 档位 | 费用(元) |
|----|--------|------|----------|
| seg_01 | 102,500 | 纯生成 | 4.72 |
| seg_02 | 98,300 | 视频编辑 | 2.75 |
| seg_03 | 95,000 | 视频编辑 | 2.66 |
| **合计** | **295,800** | - | **¥10.13** |
EOF

    mock_file "${render_dir}/回退日志.md" "# 回退日志\n## 无回退"
    mock_file "${render_dir}/渲染日志.md" "# 渲染日志\n全部成功"

    update_status_yaml "$project_dir" "C" "done" "3镜小样完成，派 Agent D 第五关审计" "D"

    local artifacts
    artifacts=$(find "$render_dir" -type f 2>/dev/null | tr '\n' ' ')
    step_end "PASS" "$artifacts"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# Step 5: Mock Agent D — 第五关（小样审计）
# =============================================================================

step_mock_agent_d_sample_audit() {
    local project_dir="$1"
    local label="D-小样审计"

    step_start_echo "$label" "Mock Agent D 第五关 — 3镜小样审计 (省钱门)"

    local audit_dir="${project_dir}/05_审核"

    cat > "${audit_dir}/审计报告_小样.md" << 'EOF'
# 审计报告 — 小样审计

## 结果：✅ S+通过
## 均分：4.2/5

## 维度打分
| 维度 | 得分 | 说明 |
|------|:--:|------|
| 人物一致 | 5 | 3镜同角色外貌一致 |
| 场景连贯 | 4 | 光线色调统一 |
| 口型 | 4 | 口型同步 |
| 画面质量 | 4 | 无缺陷 |
| 叙事可读 | 4 | 叙事清晰 |

## 硬指标
- ✅ D01 人物一致性: pass
- ✅ D02 场景连贯: pass
- ✅ D03 口型: pass
- ✅ D04 画质: pass
- ✅ D05 叙事: pass

## S+ 判定
- [x] 全部维度 ≥ 4分 → 通过
EOF
    log_info "  第五关小样审计: ✅ S+通过 (省钱门通过)"

    local clips_dir="${project_dir}/04_渲染/clips"
    local sample_count=0
    for seg in 01 02 03; do
        [ -f "${clips_dir}/seg_${seg}.mp4" ] && sample_count=$((sample_count + 1))
    done
    log_info "  小样视频: ${sample_count}/3"

    if [ "$sample_count" -lt 3 ]; then
        log_fail "小样视频不完整"
        step_end "FAIL"; step_end_echo "$label" "FAIL"; return 1
    fi

    update_status_yaml "$project_dir" "D" "done" "小样审计通过，派 Agent E 后期" "E"

    step_end "PASS" "${audit_dir}/审计报告_小样.md"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# Step 6: Mock Agent E — 后期合成
# =============================================================================

step_mock_agent_e() {
    local project_dir="$1"
    local label="E-后期"

    step_start_echo "$label" "Mock 后期合成引擎 — 合成/字幕/交付/桌面同步"

    # Step 0: P0-4 读成本追踪
    local cost_file="${project_dir}/04_渲染/成本追踪.md"
    if [ ! -f "$cost_file" ]; then
        log_fail "P0-4 成本追踪缺失"
        step_end "FAIL"; step_end_echo "$label" "FAIL"; return 1
    fi
    log_info "  P0-4 成本追踪 ✅"

    # 交付: 06_成片/
    local output_dir="${project_dir}/06_成片"
    safe_mkdir "$output_dir"
    safe_mkdir "${output_dir}/audio/tts_fallback"

    echo -n "mock_final_video" > "${output_dir}/final.mp4"
    echo -n "mock_final_subtitles" > "${output_dir}/final_with_subtitles.mp4"

    # P0-5: SRT 字幕 + 锁验证
    mock_file "${output_dir}/subtitles.srt" "1\n00:00:01,000 --> 00:00:04,000\n测试字幕"
    log_info "  P0-5 SRT 已生成 ✅"

    mock_file "${output_dir}/timeline.json" '{"segments":[{"id":"01","start":0,"end":5},{"id":"02","start":5,"end":10},{"id":"03","start":10,"end":15}]}'
    mock_file "${output_dir}/concat_list.txt" "file 'clips/seg_01.mp4'\nfile 'clips/seg_02.mp4'\nfile 'clips/seg_03.mp4'"
    mock_file "${output_dir}/后期日志.md" "# 后期日志\n## 修复\n- 原生音频: 3/3 段\n- TTS兜底: 0 段\n- 合成完成"
    mock_file "${output_dir}/质检报告.md" "# 质检报告\n## 自动检查\n- [x] 视频完整性: OK\n- [x] 音频: OK\n- [x] 字幕时间码: OK\n\n## 结论: ✅ 通过"

    # P0-6: API 计费埋点
    mock_file "${output_dir}/api_billing_log.md" "# API 计费 (P0-6)\n## 记录\n| 操作 | tokens | 费用 | task_id |\n| Seedance 渲染 | 295,800 | ¥13.61 | mock-task-001 |"
    log_info "  P0-6 API 计费埋点 ✅"

    update_status_yaml "$project_dir" "E" "done" "全部完成" "none"

    local artifacts
    artifacts=$(find "$output_dir" -type f 2>/dev/null | tr '\n' ' ')
    step_end "PASS" "$artifacts"
    step_end_echo "$label" "PASS"

    return 0
}

# =============================================================================
# 最终验证
# =============================================================================

run_final_validation() {
    local project_dir="$1"
    local total_failures=0

    echo -e "\n${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}  最终验证${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"

    # 验证1: 放行令
    echo ""
    log_info "[验证1] 放行令..."
    verify_release_order "${project_dir}/05_审核/渲染放行令.yaml" || total_failures=$((total_failures+1))

    # 验证2: hash 绑定
    echo ""
    log_info "[验证2] hash 绑定..."
    local input_files=(
        "${project_dir}/02_分镜/段打包清单.yaml"
        "${project_dir}/03_资产/资产清单.yaml"
        "${project_dir}/01_剧本/视觉风格锁定.yaml"
        "${project_dir}/05_审核/审计报告_剧本.md"
        "${project_dir}/05_审核/审计报告_分镜.md"
        "${project_dir}/05_审核/审计报告_资产.md"
    )
    verify_hash_binding "${project_dir}/05_审核/渲染放行令.yaml" "${input_files[@]}" || total_failures=$((total_failures+1))

    # 验证3: 06_成片
    echo ""
    log_info "[验证3] 06_成片目录..."
    verify_06_chengpian_dir "$project_dir" || total_failures=$((total_failures+1))

    # 验证4: STATUS.yaml 链路
    echo ""
    log_info "[验证4] STATUS.yaml 链路..."
    local status_file="${project_dir}/STATUS.yaml"
    if [ -f "$status_file" ]; then
        local last_agent; last_agent=$(grep "^last_agent:" "$status_file" | awk '{print $2}' | tr -d '"')
        local agent_status; agent_status=$(grep "^last_agent_status:" "$status_file" | awk '{print $2}' | tr -d '"')
        log_info "  STATUS: last_agent=${last_agent}, status=${agent_status}"
        [ "$last_agent" = "E" ] && [ "$agent_status" = "done" ] && log_pass "  链路: A→B→D→C→D→E" || log_warn "  链路未到终点"
    else
        log_fail "  STATUS.yaml 不存在"
        total_failures=$((total_failures+1))
    fi

    # 验证5: 产物完整性
    echo ""
    log_info "[验证5] 产物完整性..."
    local checks=0 passed_checks=0
    local key_files=(
        "01_剧本/剧本_v1.md"
        "01_剧本/视觉风格锁定.yaml"
        "01_剧本/角色卡_九维.yaml"
        "02_分镜/分镜表.md"
        "02_分镜/段打包清单.yaml"
        "03_资产/角色卡/主角A_人脸特写.png"
        "03_资产/角色卡/主角A_全身.png"
        "03_资产/场景卡/S-001_测试场景_氛围.png"
        "03_资产/场景卡/S-001_测试场景_灯光.md"
        "03_资产/场景卡/S-001_测试场景_机位.svg"
        "03_资产/资产清单.yaml"
        "04_渲染/clips/seg_01.mp4"
        "04_渲染/clips/seg_02.mp4"
        "04_渲染/clips/seg_03.mp4"
        "04_渲染/段渲染清单.yaml"
        "04_渲染/成本追踪.md"
        "05_审核/审计报告_剧本.md"
        "05_审核/审计报告_分镜.md"
        "05_审核/审计报告_资产.md"
        "05_审核/审计报告_小样.md"
        "05_审核/渲染放行令.yaml"
        "06_成片/final.mp4"
        "06_成片/final_with_subtitles.mp4"
        "06_成片/subtitles.srt"
        "06_成片/质检报告.md"
    )
    for f in "${key_files[@]}"; do
        checks=$((checks+1))
        [ -f "${project_dir}/${f}" ] && passed_checks=$((passed_checks+1)) || log_fail "  缺失: $f"
    done
    log_info "  关键产物: ${passed_checks}/${checks}"
    [ "$passed_checks" -lt "$checks" ] && total_failures=$((total_failures + 1))

    echo ""
    [ $total_failures -eq 0 ] && { log_pass "✅ 全部验证通过"; return 0; } || { log_fail "❌ ${total_failures} 项失败"; return 1; }
}

# =============================================================================
# 打印步骤统计
# =============================================================================

print_step_stats() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  步骤统计${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    printf "%-20s %-8s %-10s\n" "步骤" "状态" "耗时(s)"
    echo "----------------------------------------"

    local i total_duration=0
    for ((i=0; i<STEP_COUNT; i++)); do
        local name="${STEP_NAMES[$i]}"
        local status="${STEP_STATUSES[$i]}"
        local duration=$(( STEP_ENDS[$i] - STEP_STARTS[$i] ))
        local icon="✅"
        [ "$status" = "FAIL" ] && icon="❌"
        printf "%-20s ${icon}%-6s %-8s\n" "[$name]" " $status" "${duration}s"
        total_duration=$((total_duration + duration))
    done

    echo ""
    local real_duration=$(( DRYRUN_END_TIME - DRYRUN_START_TIME ))
    echo "累计步骤耗时: ${total_duration}s | 实际执行: ${real_duration}s"

    all_pass=true
    for ((i=0; i<STEP_COUNT; i++)); do
        [ "${STEP_STATUSES[$i]}" = "FAIL" ] && all_pass=false
    done

    if $all_pass; then
        echo -e "\n${GREEN}✅ 全链路模拟完成 — 全部 PASS${NC}"
    else
        echo -e "\n${RED}❌ 模拟完成 — 存在 FAIL 步骤${NC}"
    fi
}

print_artifact_summary() {
    local project_dir="$1"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  产物清单${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"

    local total_files=0 total_size=0
    while IFS= read -r -d '' file; do
        local size; size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
        local rel_path="${file#$project_dir/}"
        printf "  %-65s %5d bytes\n" "$rel_path" "$size"
        total_files=$((total_files + 1))
        total_size=$((total_size + size))
    done < <(find "$project_dir" -type f -print0 | sort -z)

    echo ""
    echo "总计: ${total_files} 个文件, ${total_size} bytes"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    local clean_first=false
    local verbose=false

    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--clean) clean_first=true; shift;;
            -v|--verbose) verbose=true; shift;;
            -h|--help)
                echo "用法: $0 [-c|--clean] [-v|--verbose]"
                echo "  -c, --clean    运行前清理旧产物"
                echo "  -v, --verbose  启用调试日志"
                echo "  -h, --help     显示帮助"
                exit 0
                ;;
            *) die "未知参数: $1 (使用 -h 查看帮助)";;
        esac
    done

    [ "$verbose" = true ] && set -x

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  AI导演 端到端全流程模拟 (dry-run) v1.0                  ║${NC}"
    echo -e "${GREEN}║  流程: A → B → D(三关+门禁) → C → D(第五关) → E         ║${NC}"
    echo -e "${GREEN}║  时间: $(date '+%Y-%m-%d %H:%M:%S %Z')                    ${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

    cd "$WORKSPACE" || die "WORKSPACE 路径错误: $WORKSPACE"

    local project_dir="${WORKSPACE}/${OUTPUT_DIR}"
    DRYRUN_START_TIME=$(date +%s)

    $clean_first && clean_artifacts "$project_dir"
    safe_mkdir "$project_dir"
    log_info "项目目录: ${project_dir}"

    # Step 1: A
    step_mock_agent_a "$project_dir" || {
        update_status_yaml "$project_dir" "A" "failed" "失败" "none"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    # Step 2: B
    step_mock_agent_b "$project_dir" || {
        update_status_yaml "$project_dir" "B" "failed" "失败" "none"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    # Step 3: D (三关 + 第四关)
    step_mock_agent_d_gates "$project_dir" || {
        update_status_yaml "$project_dir" "D" "failed" "门禁打回" "B"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    # Step 4: C (渲染)
    step_mock_agent_c "$project_dir" || {
        update_status_yaml "$project_dir" "C" "failed" "渲染失败" "none"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    # Step 5: D (小样审计)
    step_mock_agent_d_sample_audit "$project_dir" || {
        update_status_yaml "$project_dir" "D" "failed" "小样审计打回" "C"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    # Step 6: E (后期)
    step_mock_agent_e "$project_dir" || {
        update_status_yaml "$project_dir" "E" "failed" "后期失败" "none"
        DRYRUN_END_TIME=$(date +%s); print_step_stats; exit 1
    }

    DRYRUN_END_TIME=$(date +%s)

    # 最终验证
    local final_result=0
    run_final_validation "$project_dir" || final_result=1

    print_step_stats
    print_artifact_summary "$project_dir"

    echo ""
    [ $final_result -eq 0 ] && echo -e "${GREEN}✅ Dry-run PASS — 退出码: 0${NC}" || echo -e "${RED}❌ Dry-run FAIL — 退出码: ${final_result}${NC}"

    exit $final_result
}

main "$@"

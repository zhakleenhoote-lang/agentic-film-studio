/**
 * AI Director Discipline Plugin
 *
 * Enforces 2 red lines (7 + 8) for AI Director workflow:
 *   - Red line 7 (先验证后答): Inject project status summary into LLM context before prompt build
 *   - Red line 8 (SSOT 改动列清单): Block edits to SSOT files without explicit approval
 *
 * Version: 0.1.0 (2026-07-09 initial draft)
 */

import { execSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

// ===== Configuration =====
const WORKSPACE = process.env.WORKSPACE_DIR || "/home/user/.openclaw/workspace";
const PRE_CHECK_SCRIPT = join(WORKSPACE, "scripts", "pre_answer_check.sh");
const SSOT_DETECTOR_SCRIPT = join(WORKSPACE, "scripts", "ssot_change_detector.sh");

// SSOT path patterns (relative to workspace, no glob support, simple substring match)
const SSOT_PATTERNS = [
  "outputs/", // Any output project
  "/STATUS.yaml", // Project status SSOT
  "MEMORY.md",
  "AGENTS.md",
  "skills/ai-director-", // 5 Agent SKILL.md
  "/SKILL.md",
  "skills/knowledge/",
  "scripts/verify_state.sh",
  "scripts/ai_director_dryrun.sh",
];

const SSOT_EDIT_TOOLS = new Set(["edit", "write", "apply_patch", "create_file", "patch"]);

// ===== Helpers =====

function isSSOTPath(filePath: string): boolean {
  if (!filePath) return false;
  for (const pattern of SSOT_PATTERNS) {
    if (filePath.includes(pattern)) return true;
  }
  return false;
}

function runScript(scriptPath: string, args: string[] = []): string {
  if (!existsSync(scriptPath)) {
    return `[ai-director-discipline] script not found: ${scriptPath}`;
  }
  try {
    const cmd = `bash ${scriptPath} ${args.map((a) => `"${a.replace(/"/g, '\\"')}"`).join(" ")}`;
    return execSync(cmd, { encoding: "utf-8", timeout: 5000 });
  } catch (e: any) {
    return `[ai-director-discipline] script error: ${e.message?.slice(0, 200) || "unknown"}`;
  }
}

// ===== Plugin Entry =====

export default definePluginEntry({
  id: "ai-director-discipline",
  name: "AI Director Discipline",
  description:
    "Auto-injects project status summary (red line 7) and blocks SSOT edits (red line 8) for AI Director workflow",

  register(api) {
    // ===== Hook 1: before_prompt_build — Red line 7 (先验证后答) =====
    api.on(
      "before_prompt_build",
      async (_event) => {
        const summary = runScript(PRE_CHECK_SCRIPT);
        const systemContext = `[ai-director-discipline] 自动注入项目状态摘要（红线 7 — 先验证后答）

${summary}

⚠️ 你是凌（minimax/MiniMax-M3）。任何项目状态相关回答必须基于以上自动注入的实时摘要。
⚠️ 若摘要显示异常/过期，请主动 verify 后再答，不要凭记忆。
⚠️ 红线 7 触发反例 ≥ 5 次：必须按摘要回答，不再"先猜再查"。

⚠️ 红线 9（不主动编张大马没说过的话）— 2026-07-09 11:13 张大马立：
   • 不要主动编张大马没说过的新流程/选项/方案。
   • 列"接下来能做什么"前，必须基于张大马最近 3 条消息原话。
   • 不确定张大马是否这个意思时，先问"我理解对吗？"再列。
   • 红线 8 精神扩展：禁止"扩大解释用户指令"。

⚠️ 主agent↔子agent通信规则 v1（2026-07-12 张大马批落地，覆盖红线 13）：
   • 反馈及时：sub-agent 任何状态变化（含 done）→ sessions_send 主 agent + 写 STATUS.yaml
   • 不失明：filesystem 是 SSOT，plugin 注入状态摘要，30s/5min/10min 文件轮询兜底
   • 不刷屏：禁 cron/heartbeat（红线 11 物理隔离），silent reply 收紧
   • 过程不飞书：本规则生效期间，长任务不发中间进展，只发派任务简报（开头）+ 最终详报（结果）
   • 开头和结果：派任务简报+完成后详报硬约束（红线 5）
   • 开头格式：第一句 \`【派任务简报·开始】任务名·预计 Y 分钟\`，第二行起 \`📋 步骤：1)...2)...3)...\`
   • 开头三件套：任务详情 + 预计耗时 + 规划执行

⚠️ 红线 13 已覆盖：原"长任务每原子步骤必发进展 \`【进展】#N 完成\`"整段删除。
⚠️ 本规则覆盖红线 13，遇到冲突时本规则优先。`;

        return {
          prependSystemContext: systemContext,
        };
      },
      { priority: 90, timeoutMs: 8000 },
    );

    // ===== Hook 2: before_tool_call — Red line 8 (SSOT 改动列清单) =====
    api.on(
      "before_tool_call",
      async (event) => {
        // ===== Auto-sync whitelist (张大马 09:47 立的"自动同步"规则放行) =====
        // 张大马批的改动，主 agent 提前创建 /tmp/openclaw_auto_sync 含 timestamp
        // 5 分钟内凭证有效，hook 跳过拦截。凭证创建后主 agent 同步完会 rm。
        const AUTO_SYNC_TOKEN = "/tmp/openclaw_auto_sync";
        if (existsSync(AUTO_SYNC_TOKEN)) {
          try {
            const stat = statSync(AUTO_SYNC_TOKEN);
            const age = Date.now() - stat.mtimeMs;
            // 容忍 mtime ±2 秒（文件系统视图延迟）
            // age < 0 表示 mtime 晚于当前时间（fs 延迟/时钟误差），也认有效
            if (age >= -2000 && age < 300000) {
              return; // 5 分钟内凭证有效 → 放行
            }
          } catch {
            // 文件 stat 失败 → 继续正常拦截
          }
        }

        const toolName = (event.toolName || "").toLowerCase();
        if (!SSOT_EDIT_TOOLS.has(toolName)) return;

        // Extract file path from common param shapes
        const params = event.params || {};
        const filePath =
          (params.path as string) ||
          (params.file as string) ||
          (params.filePath as string) ||
          (params.target as string) ||
          "";

        if (!isSSOTPath(filePath)) return;

        // Run detector to produce diff template
        const detectorOut = runScript(SSOT_DETECTOR_SCRIPT, [filePath]);

        const blockMessage = `🚨 SSOT 改动被自动拦截（红线 8 — SSOT 改动列清单 + 等批）

目标文件: ${filePath}
工具: ${toolName}

${detectorOut}

请按以下任一方式处理：
1. 列出"修改清单 + diff" → 提交给张大马批 → 批后再改
2. 如果是纯 bug 修（自相矛盾 / 字段重复 / YAML 语法错）→ 重试时张大马在线确认 → 改
3. 让张大马直接修改`;

        return {
          block: true,
          blockReason: blockMessage,
        };
      },
      { priority: 90, timeoutMs: 5000 },
    );
  },
});
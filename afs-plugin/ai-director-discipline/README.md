# AI Director Discipline

OpenClaw plugin enforcing 2 red lines (7 + 8) for AI Director workflow.

## Hooks

- **`before_prompt_build`** (priority 90) — Injects project status summary into LLM context
  - Calls `scripts/pre_answer_check.sh`
  - Prevents "先猜再查" (guess-then-verify) anti-pattern (red line 7)

- **`before_tool_call`** (priority 90) — Blocks SSOT file edits
  - Detects `toolName ∈ {edit, write, apply_patch}` with path matching SSOT list
  - Returns `{ block: true, blockReason: "..." }` with diff template
  - Enforces red line 8 (SSOT changes need Zhang Da Ma approval)

## Files

- `package.json` — Plugin manifest + SDK compat
- `openclaw.plugin.json` — OpenClaw plugin manifest
- `index.ts` — `definePluginEntry` + `api.on(...)` hook registrations

## Workspace dependency

This plugin depends on scripts in the workspace:
- `~/.openclaw/workspace/scripts/pre_answer_check.sh`
- `~/.openclaw/workspace/scripts/ssot_change_detector.sh`

## Version

0.1.0 — 2026-07-09 initial draft
# Tasks: Render Copilot CLI rg Tool Calls

1. [ ] Update `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` to recognize `rg`, share search display formatting with `grep`, include concise `path`/`glob`/`type`/`output_mode` details when present, and return the pattern from `getToolInputString('rg', ...)`.
   - depends on: none
2. [ ] Add formatter tests in `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts` proving `rg` no longer uses generic `rg` text, renders pattern and selected filters safely, mirrors invocation/past tense, and exposes the pattern as tool input.
   - depends on: task #1
3. [ ] Optionally add a replay regression test in `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/test/node/mapSessionEvents.test.ts` if the formatter tests do not clearly cover the original “Used rg” symptom through mapped `tool_start`/`tool_complete` events.
   - depends on: task #1
4. [ ] Validate with `npm run compile-check-ts-native`, focused `./scripts/test.sh --grep "copilotToolDisplay"`, optional `./scripts/test.sh --grep "mapSessionEvents"`, and `npm run valid-layers-check`.
   - depends on: tasks #1 and #2, plus task #3 if added
5. [ ] After implementation/finalize, update `/Users/roblou/code/knowledge-vscode/vsckb/docs/copilot-sdk-tool-display.md` with the reusable `grep`/`rg` normalization lesson.
   - depends on: implementation validation

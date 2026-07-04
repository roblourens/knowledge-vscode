# Agent Host Markdown links

**Date:** 2026-07-04
**VS Code branch:** agents/markdown-link-translation-exploration
**VS Code SHA at finalize:** 87eae31a82
**PR:** https://github.com/microsoft/vscode/pull/324326

## What was done

Copilot Agent Host system-message composition now adds a dedicated `<file_folder_and_symbol_links>` block to non-replacement prompts. It asks models to emit Markdown links whenever they refer to existing workspace files, folders, or symbols, using absolute filesystem targets with `/` separators and optional `:line[:column]` locations.

Normal assistant responses no longer rewrite Markdown links while individual deltas cross the AHP-to-chat adapter. The raw deltas accumulate in the chat model, and `ChatMarkdownContentPart` resolves actual parsed link/image targets immediately before sanitization through the owning `IChatSessionContentProvider`. Agent Host accepts conservative absolute POSIX/Windows/UNC paths and internal URIs, maps them through `toAgentHostUri`, preserves labels/titles, leaves external/client schemes untouched, and keeps native blue Markdown links. Atomic tool display messages retain their existing source rewrite and rich file-widget behavior.

## Key decisions

- Keep normal response Markdown append-only and raw; resolve only parsed link/image destinations at render time, where the full accumulated Markdown and session origin are both available.
- Put host-specific resolution behind the chat-session content provider instead of teaching the generic chat renderer how to infer Agent Host authority from a session URI.
- Preserve response link labels so they render as ordinary Markdown anchors; do not reuse the empty-label file-widget presentation used by tool messages.
- Prefer model-emitted absolute filesystem targets with optional `:line[:column]`; accept `file:` URIs and existing fragments defensively, but do not request ranges.
- Keep full replacement system prompts fully owned by their contributor instead of injecting universal guidance into them.

## What went wrong or was misunderstood

- Normal responses appeared to already be covered because completed history and reconnect snapshots called the Markdown rewrite helper. The live path actually passed each newly appended delta through the helper, so a link split across deltas was never recognized. — **prevented by:** doc body update and render-time gotcha in `agent-host-session-handler.md`.
- The first render-time attempt rewrote accumulated Markdown source and reconstructed labels. Reviews exposed failures with repeated link text inside code, explicit titles, escaped/bracketed labels, and image dimension suffixes. — **prevented by:** the `agent-host-session-handler.md` gotcha requiring parsed-token `transformUri` before sanitization.
- The initial design reused empty link labels because that is correct for tool-message file chips. The requested UX was instead native blue Markdown links in prose, so labels must remain intact and `renderFileWidgets` must not take over. — **prevented by:** the split tool-message versus normal-response contracts documented in `agent-host-session-handler.md`.
- Prompt syntax iterated through `file:` URIs, `#L` fragments, and ranges before comparison with first-party model guidance established the final absolute-path plus `:line[:column]` convention. — **prevented by:** the new prompt-composition section in `copilot-agent-provider.md` and this decision history.
- Absolute-path handling had non-obvious cross-platform and URI edges: Windows/UNC separators, encoded colons, queried file URIs, opaque schemes, product/client schemes, malformed numeric suffixes, and absolute `SKILL.md` tagging. — **prevented by:** the normal-response resolver details and gotcha in `agent-host-session-handler.md`.
- The GitHub MCP draft-PR form repeatedly failed to surface, requiring an authenticated `gh pr create` fallback. The first CI monitor also crashed while GitHub reported no checks, and the eventual policy failure revealed a real merge conflict with `main`. — **prevented by:** this summary; these are workflow observations rather than stable Agent Host component rules.

## What we learned

- The base Markdown renderer is the cleanest layer for a generic parsed-URI transform hook because it runs after Markdown tokenization but before sanitization and link activation.
- Image URI transformation must occur after parsing VS Code's `|width=...|height=...` suffix so resource mapping does not encode the dimension metadata into the path.
- The extension-host Copilot participant has both detailed prompt instructions and a streaming runtime linkifier. This Agent Host change intentionally implements model guidance plus target resolution, not automatic conversion of plain path text.
- VS Code opener selection fragments accept `Lline` and `Lline,column`; mapping `:line[:column]` to that internal form keeps the model-facing syntax independent from the editor-facing URI convention.

## Doc updates

- `docs/agent-host-session-handler.md` — added the normal-response render-time link pipeline, split it from tool-message file widgets, expanded `Covers:`, and added a gotcha preserving parsed-token transformation before sanitization.
- `docs/copilot-agent-provider.md` — added system-message composition and workspace-link guidance, expanded `Covers:`, and added a gotcha preserving full replacement prompt ownership.
- `index.md` — refreshed the two doc entries with prompt and render-time link coverage.

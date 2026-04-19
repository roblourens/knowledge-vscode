# Render remote agent-host file links in tool messages

**Date:** 2026-04-19
**VS Code branch:** roblou/agents/bugfix-rendering-remote-references
**VS Code SHA at finalize:** b708764819
**PR:** https://github.com/microsoft/vscode/pull/311264

## What was done

For sessions running against a **remote** agent host, tool past-tense messages like `Read [foo.ts](file:///path/to/foo.ts)` were rendering as bare prefix text — the link disappeared entirely instead of becoming a clickable file widget.

A recent change (#311201 / commit `696552cfc5c`) had introduced `rewriteMarkdownLinks` in `stateToProgressAdapter.ts` to wrap remote `file://` URIs into the `vscode-agent-host://<authority>/<scheme>/<authority|->/<path>` form via `toAgentHostUri(...)`. As part of that, link text was deliberately emptied so `[foo.ts](file:///...)` became `[](vscode-agent-host://...)`. The empty-text form is what `renderFileWidgets` (in `chatInlineAnchorWidget.ts`) picks up and converts into the rich `InlineAnchorWidget` chip.

The rewrite was working correctly. The bug was downstream: `ChatContentMarkdownRenderer`'s sanitizer config didn't include `vscode-agent-host` in `allowedLinkSchemes`. Inside `renderMarkdown`, the pipeline runs:

1. `marked.parse()` produces `<a href="vscode-agent-host://...">`.
2. `safeSetInnerHtml` runs DOMPurify with the configured allowed protocols and **strips the disallowed `href`**.
3. `rewriteRenderedLinks` walks the result and (since `href` is now empty *and* link text is also empty by design) **removes the `<a>` element entirely**.
4. `renderFileWidgets` runs later — but there's no anchor left to convert.

Fix: add `AGENT_HOST_SCHEME` (from `src/vs/platform/agentHost/common/agentHostUri.ts`) to the `allowedLinkSchemes.augment` list in `chatContentMarkdownRenderer.ts`. With the scheme allowed, DOMPurify preserves the `href`, `rewriteRenderedLinks` moves it to `data-href`, and `renderFileWidgets` does its job.

Tests added:

- `src/vs/base/test/browser/markdownRenderer.test.ts` — two new tests under `Sanitization`: one shows the default sanitizer config strips a `vscode-agent-host://` link entirely (reproducing the failure mode); the other shows that augmenting `allowedLinkSchemes` preserves the `<a>` with its `data-href`.
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/stateToProgressAdapter.test.ts` — confirms `finalizeToolInvocation` runs `rewriteMarkdownLinks` on `pastTenseMessage` (asserts a `Read [foo.ts](file:///path)` markdown becomes `Read [](vscode-agent-host://ssh__macbook-air/file/-/path/to/foo.ts)`).

`agentSessionsViewer.ts:377` also augments `allowedLinkSchemes` for the sessions list, but that surface only renders badges/labels and doesn't carry tool messages — left unchanged.

## Key decisions

- **Fix the renderer, not the rewrite.** The rewrite's empty-text + agent-host-scheme output is correct and is exactly what `renderFileWidgets` needs. The fix is to make the sanitizer let that output through.
- **Test the failure mode at the renderer layer.** The added `markdownRenderer.test.ts` cases capture the exact silent-failure behavior (link disappears entirely when scheme is disallowed) so it's protected against regression independently of any chat-specific test setup.
- **Don't touch `agentSessionsViewer.ts`'s allowlist.** That augment list is for the agent sessions list view, which doesn't render tool past-tense messages. Keeping the change scoped to the surface that actually had the bug avoids broadening trust unnecessarily.

## What went wrong or was misunderstood

- **Misattribution from the user prompt.** The reported symptom was a `pastTenseMessage` value in the local chat model that *looked* wrong (`Read [](vscode-agent-host://...)`) and was suspected to be evidence that "the rewrite isn't happening." It actually was the correctly-rewritten markdown. The visible-text-on-screen failure was several pipeline steps later. — **prevented by:** the new "Remote file links in tool messages" section + gotcha on [agent-host-session-handler.md](../../docs/agent-host-session-handler.md), which spells out that the empty-text agent-host link is the *expected* output of the rewrite and that rendering depends on the sanitizer + `renderFileWidgets`.
- **Hidden coupling between the rewrite, the sanitizer allowlist, and `renderFileWidgets`.** Three components that live in different folders all need to agree: empty-text + `vscode-agent-host://` href + scheme is allowed + `renderFileWidgets` runs after `rewriteRenderedLinks`. None of the three call sites mention the others. — **prevented by:** the gotcha entry on [agent-host-session-handler.md](../../docs/agent-host-session-handler.md), which names all three sides and the silent-failure mode if they drift.
- **Render pipeline order is non-obvious.** It's intuitive that DOMPurify "sanitizes" but easy to miss that it runs *before* `rewriteRenderedLinks` moves `href`→`data-href`. So a disallowed scheme isn't just dropped — combined with the empty link text, the entire `<a>` is removed. The pipeline order is documented inside `markdownRenderer.ts` but isn't surfaced anywhere a remote-link author would naturally look. — **prevented by:** the new section on [agent-host-session-handler.md](../../docs/agent-host-session-handler.md) describing the four-step pipeline and the silent-failure path.

## What we learned

- Browser DOM tests can be run with `node test/unit/browser/index.js --run <path> --browser chromium`. The `npm run test-node` runner fails for tests that touch DOM (`window is not defined`) — it's the wrong harness. Worth knowing because the failure mode looked like a test bug, not a harness mismatch.
- `EXTERNAL_LINK_SCHEMES` in `stateToProgressAdapter.ts` already includes `AGENT_HOST_SCHEME` to prevent double-rewrites. That's a useful precedent for future schemes that should be passed through unchanged.
- `stringOrMarkdownToString` returns plain `string` values **as-is** without rewriting. Not the bug here (Copilot wraps with `md(...)`), but if a future producer ships a plain string containing a `file://` link to a remote agent host, the rewrite won't fire.

## Doc updates

- `docs/agent-host-session-handler.md` — added a "Remote file links in tool messages" section covering the rewrite, empty-text design, and the renderer/sanitizer dependency; added a `gotcha` for the silent-failure mode if the rewrite and the sanitizer allowlist drift; added a changelog entry.

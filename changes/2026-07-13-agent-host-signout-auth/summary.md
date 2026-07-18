# Prompt for Agent Host authentication before send

**Date:** 2026-07-13
**VS Code branch:** roblou/agents/investigate-agent-host-session-logs
**VS Code SHA at finalize:** d38816526e (squash merge: `efed051eed`)
**PR:** [#325725](https://github.com/microsoft/vscode/pull/325725)

## What was done

Agent Host turns now preflight required authentication on both the normal create-and-subscribe path and the eager/provisional-session path. When the renderer has no usable Copilot credential, the shared `resolveAuthenticationInteractively` helper directly invokes the standard **Sign in to use GitHub Copilot** setup dialog with GitHub, Google, Apple, and GHE choices, re-resolves the resulting token, forwards it to the local or remote Agent Host, and lets the pending request continue.

The same change coordinates token forwarding through a promise-aware per-connection cache: same-token callers await one in-flight RPC, different tokens serialize, only successful RPCs become completed, and scoped/global generation invalidation prevents stale pre-clear work from overwriting newer credentials. Setup/provider/transport failures propagate unchanged instead of becoming "Authentication is required."

## Key decisions

- Keep AHP authentication generic: the protocol still advertises protected resources and accepts `authenticate`; the VS Code client owns the product-specific Copilot account-options dialog.
- Put missing-token setup inside `resolveAuthenticationInteractively`, the layer that already knows whether a token exists, rather than duplicating token probes in local and remote contributions or passing a custom sign-in callback.
- Require the product setup flow for interactive authentication. The raw provider/device-code fallback was removed; local and remote callers invoke the helper through `IInstantiationService.invokeFunction`, and the helper obtains `IAuthenticationService`, `ICommandService`, and `ILogService` from its `ServicesAccessor`.
- Keep options limited to per-connection context: token cache, log prefix, and the connection's `authenticate` callback.
- Make Chat Setup return structured cancellation/failure data to Agent Host, preserve the original provider error, mark already-presented retry UI, and pass `disableChatViewReveal: true` so setup does not steal focus from the originating session.
- Validate the complete signed-out → account-options → approved → token-forwarded → response-rendered flow in a launched Code OSS instance, not only through callback-level unit tests.

## What went wrong or was misunderstood

- The first diagnosis focused on the SDK's authorization error and generic rendering, but missed that eager-created sessions bypassed `_createAndSubscribe`, where auth preflight lived. — **prevented by:** the eager-session gotcha and ownership update in `agent-host-session-handler.md`.
- The first regression test injected a successful `resolveAuthentication` callback, proving call ordering but not the real contribution, authentication provider, or setup command. It missed a real post-login failure. — **prevented by:** the auth-flow body update in `agent-host-topology.md` plus the source skill pitfall requiring real-contribution and launched-build coverage.
- The initial launched verification accepted GitHub's device-code prompt as the intended UX. That prompt was only the lower-level GitHub Authentication subflow; the expected Copilot product entry point is the setup dialog with account choices. — **prevented by:** the standard setup-dialog description and missing-token gotcha in `agent-host-topology.md`.
- The first API shape passed a `signIn` callback, then an optional `ICommandService`, through the options bag. The helper owns the missing-token decision and the services are DI-owned, so both shapes were unnecessary indirection. — **prevented by:** the finalized topology guidance: invoke orchestration through `ServicesAccessor` and keep options per-call only.
- The launch helper's default macOS temp path exceeded the UNIX-domain socket path limit, and Playwright's default daemon path hit the same issue. — **prevented by:** run launch/Playwright verification with `TMPDIR=/tmp` and a short Playwright session name on macOS.

## What we learned

- A renderer can be signed out while the long-lived Agent Host still holds the last pushed token; session hydration and host token presence are not proof that the current client can authenticate a new turn.
- Code OSS filters browser OAuth flows that require a GitHub client secret, so selecting GitHub from the proper product dialog can still proceed to device code. The important UX distinction is that users first receive the Copilot account/provider choices.
- GitHub Authentication can return an access token from device flow and then reject it during immediate user-info validation with `401 Bad credentials`; that underlying failure should reach the request unchanged.
- Token dedupe must represent completed **and in-flight** state. Same-token callers await; different tokens serialize; completion occurs only after RPC success; scoped clears use per-key generations and global restart clears use a global generation.
- Chat Setup's boolean command result was insufficient for an in-request auth retry: cancellation, provider failure, focus behavior, and whether retry UI was already shown all matter.

## Doc updates

- `docs/agent-host-topology.md` — documented turn-time auth, standard setup, ServicesAccessor ownership, promise-aware forwarding, scoped/global generations, focus preservation, structured errors, and the expanded auth gotcha.
- `docs/agent-host-session-handler.md` — documented eager-path preflight, focus-preserving setup, structured cancellation/failure, and duplicate-retry suppression.
- `index.md` — expanded the cross-cutting AHP auth pointer to include turn preflight and product sign-in.

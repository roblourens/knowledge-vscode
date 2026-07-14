# Prompt for Agent Host authentication before send

**Date:** 2026-07-13
**VS Code branch:** roblou/agents/investigate-agent-host-session-logs
**VS Code SHA at finalize:** 08093ec0e7
**PR:** [#325725](https://github.com/microsoft/vscode/pull/325725)

## What was done

Agent Host turns now preflight required authentication on both the normal create-and-subscribe path and the eager/provisional-session path. When the renderer has no usable Copilot credential, the shared `resolveAuthenticationInteractively` helper directly invokes the standard **Sign in to use GitHub Copilot** setup dialog with GitHub, Google, Apple, and GHE choices, re-resolves the resulting token, forwards it to the local or remote Agent Host, and lets the pending request continue.

The same change dedupes repeated interactive token forwarding, clears failed cache reservations, and propagates setup/provider/transport failures unchanged instead of converting every failure into "Authentication is required."

## Key decisions

- Keep AHP authentication generic: the protocol still advertises protected resources and accepts `authenticate`; the VS Code client owns the product-specific Copilot account-options dialog.
- Put missing-token setup inside `resolveAuthenticationInteractively`, the layer that already knows whether a token exists, rather than duplicating token probes in local and remote contributions or passing a custom sign-in callback.
- Preserve the direct authentication-provider path only for callers without a product command service; in-tree local and remote Agent Host contributions pass `ICommandService` and therefore use the standard setup experience.
- Validate the complete signed-out → account-options → approved → token-forwarded → response-rendered flow in a launched Code OSS instance, not only through callback-level unit tests.

## What went wrong or was misunderstood

- The first diagnosis focused on the SDK's authorization error and generic rendering, but missed that eager-created sessions bypassed `_createAndSubscribe`, where auth preflight lived. — **prevented by:** the eager-session gotcha and ownership update in `agent-host-session-handler.md`.
- The first regression test injected a successful `resolveAuthentication` callback, proving call ordering but not the real contribution, authentication provider, or setup command. It missed a real post-login failure. — **prevented by:** the auth-flow body update in `agent-host-topology.md` plus the source skill pitfall requiring real-contribution and launched-build coverage.
- The initial launched verification accepted GitHub's device-code prompt as the intended UX. That prompt was only the lower-level GitHub Authentication subflow; the expected Copilot product entry point is the setup dialog with account choices. — **prevented by:** the standard setup-dialog description and missing-token gotcha in `agent-host-topology.md`.
- The first API shape passed a `signIn` callback into the helper. The helper already owns the exact missing-token decision, so the callback was unnecessary indirection and duplicated command wiring. — **prevented by:** this summary's decision record; the final code passes the standard `ICommandService` and invokes the command directly in `resolveAuthenticationInteractively`.
- The launch helper's default macOS temp path exceeded the UNIX-domain socket path limit, and Playwright's default daemon path hit the same issue. — **prevented by:** run launch/Playwright verification with `TMPDIR=/tmp` and a short Playwright session name on macOS.

## What we learned

- A renderer can be signed out while the long-lived Agent Host still holds the last pushed token; session hydration and host token presence are not proof that the current client can authenticate a new turn.
- Code OSS filters browser OAuth flows that require a GitHub client secret, so selecting GitHub from the proper product dialog can still proceed to device code. The important UX distinction is that users first receive the Copilot account/provider choices.
- GitHub Authentication can return an access token from device flow and then reject it during immediate user-info validation with `401 Bad credentials`; that underlying failure should reach the request unchanged.
- `AgentHostAuthTokenCache.updateAndIsChanged` reserves before the RPC and relies on exact resource/scope clearing on failure; the prior knowledge text incorrectly described it as seed-after-success.

## Doc updates

- `docs/agent-host-topology.md` — documented turn-time auth, the standard setup dialog, error propagation, and corrected cache ordering; expanded the auth gotcha.
- `docs/agent-host-session-handler.md` — documented eager-path preflight and added an eager-session authentication gotcha.
- `index.md` — expanded the cross-cutting AHP auth pointer to include turn preflight and product sign-in.

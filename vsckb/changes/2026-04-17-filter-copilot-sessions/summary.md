# Filter Copilot Sessions

**Date:** 2026-04-17
**VS Code branch:** roblou/filter-copilot-sessions
**VS Code SHA at finalize:** 9364e338cc
**PR:** https://github.com/microsoft/vscode/pull/311097

## What was done

Updated `CopilotAgent.listSessions()` so it only returns Copilot SDK sessions that already have Agent Host session data. For each SDK session, the provider now checks the canonical Agent Host session URI with `tryOpenDatabase()` and skips sessions with no existing per-session database. Project resolution and project metadata writes happen only after that gate, so listing SDK sessions from other Copilot CLI agents does not create local databases for them.

Added focused Copilot provider tests with a fake SDK client and real in-memory `SessionDatabase(':memory:')` instances behind a small test `ISessionDataService`. The tests cover owned sessions being listed, unowned SDK sessions being filtered out, stored metadata being read, and `openDatabase()` not being called during list-only filtering of external sessions.

## Key decisions

- Filter at the Copilot provider boundary instead of `AgentService` or UI consumers, because providers own which backend sessions count as their Agent Host sessions.
- Use existing per-session database presence as the ownership signal. A separate metadata marker was considered but dropped after deciding that any existing database can be treated as owned going forward.
- Keep listing side-effect-free for unowned SDK sessions by checking `tryOpenDatabase()` before resolving project metadata or writing project resolution.
- Keep application object construction straightforward; tests normalize optional `undefined` properties when their presence is irrelevant.
- Add a narrow `ICopilotClient` test seam because the SDK `CopilotClient` class has private members and cannot be faked directly by structural typing.

## What we learned

- `ISessionDataService.tryOpenDatabase()` is the correct read-only ownership check; `openDatabase()` intentionally creates session data and should not be used during list filtering.
- `SessionDataService` with a `':memory:'` database path is useful for service tests, but `tryOpenDatabase()` still depends on file existence. Provider tests that need precise owned/unowned control can fake the service existence map while using real in-memory `SessionDatabase` objects.
- VS Code's TypeScript configuration does not enable `exactOptionalPropertyTypes`, so optional metadata properties may be present with `undefined`. Avoid contorting product code solely for deep-equality object shape expectations in tests.
- The suite leak helper `ensureNoDisposablesAreLeakedInTestSuite()` returns the store surface tests should use for disposables. If a test dispose helper needs to wait for async lifecycle cleanup, document the reason.

## Doc updates

- Updated `docs/agent-host-topology.md` to call out provider-owned session filtering/adoption boundaries.
- Added `docs/copilot-agent-provider.md` covering CopilotAgent session ownership, metadata, and focused test patterns.
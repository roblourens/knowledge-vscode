# Fix session spinner stuck after turn completion

## Root cause

Race between the 100ms `_summaryNotifyScheduler` and `removeSession`:

1. `endTurn` sets `status=Idle` on summary → session added to `_dirtySummaries`, flush scheduled +100ms
2. Within that 100ms, `_maybeEvictIdleSession` (called on client unsubscribe, sees `activeTurn === undefined`) calls `removeSession`
3. `removeSession` clears `_sessionStates`, `_lastNotifiedSummaries`, and `_dirtySummaries`
4. Scheduler fires, nothing dirty → no `SessionSummaryChanged { status: Idle }` ever emitted

## Fix

Flush any pending summary notification synchronously in `removeSession` before tearing down the maps. Extract helper `_flushSummaryNotificationFor(session)` and call it from both `removeSession` and `_flushSummaryNotifications`.

## Tasks

- [x] Extract `_flushSummaryNotificationFor` helper from loop body in `_flushSummaryNotifications`
- [x] Call it from `removeSession` before clearing session from state maps
- [x] Add regression test: turnStarted → turnComplete → removeSession before scheduler fires → assert SessionSummaryChanged with status=Idle emitted

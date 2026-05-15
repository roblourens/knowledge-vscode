# Agent Host PR State

## Problem

EH CLI surfaces an "Open Pull Request" button + live PR/CI state on agent sessions.
Agent Host sessions don't: `AgentHostSession.gitHubInfo` is hardcoded to `undefined`,
so `OpenPullRequestAction` (gated by `ActiveSessionContextKeys.HasPullRequest`)
never lights up, and the live PR/CI refresh path via `IGitHubService` never fires.

## Approach (Option A - client-side detection)

1. Server: extend `ISessionGitState` with optional `owner`/`repo` parsed from
   `git remote -v` for the GitHub remote in `_computeSessionGitState`. Flows
   through the existing `_meta.git` slot.
2. Client: add `findPullRequestNumberByHeadBranch(owner, repo, branch)` to
   `IGitHubService` (GraphQL via `GitHubApiClient`), with caching by tuple.
3. Client: replace `gitHubInfo = observableValue(undefined)` in
   `AgentHostSession` with a `derived` that reads `_meta.git`, resolves PR
   number, and constructs `IGitHubInfo`. Live refresh + CI icon then comes for
   free via `createPullRequestModelReference`.
4. `OpenPullRequestAction` lights up automatically.

## Tasks

See SQL todos.

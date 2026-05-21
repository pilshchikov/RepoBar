# RepoBar fork improvements

This fork keeps the upstream RepoBar app, plus local changes that make it behave more like a persistent GitHub work dashboard and on-demand CI launcher.

## Menu stability and refresh behavior

- Main menu rebuilds reconcile existing `NSMenuItem` instances instead of removing and recreating every row.
- Repo submenus preserve their parent `NSMenuItem` and child `NSMenu` identity across background refreshes.
- Issue/PR filter chips reuse their hosted menu item wrappers so clicking filters does not collapse the open submenu.
- Opening the status bar menu no longer triggers a GitHub refresh. The background refresh scheduler owns network refresh cadence.
- The practical result is that hovering inside a repo submenu should survive normal data refreshes.

## GitHub Actions as on-demand jobs

- The old `CI Runs` submenu no longer starts as a repo-wide run-history list.
- `CI Runs` now shows dispatchable GitHub Actions workflows, meaning workflows that define `workflow_dispatch`.
- Each workflow opens a submenu with:
  - `Run Action`
  - a branch picker using the 10 most recently updated branches
  - workflow dispatch inputs parsed from the workflow YAML
  - the last 10 runs for that workflow
- Choice and boolean inputs are selectable directly from submenus.
- Free-text style inputs can be edited through a small prompt.
- Dispatch uses GitHub's workflow dispatch endpoint with the selected branch and inputs.
- RepoBar sends a notification when a run it started completes or fails.

## Fork/base differences from original upstream

This branch is based on `pilshchikov/RepoBar` `main`, which was already ahead of the cloned upstream by many commits. The integration keeps the fork's newer refactors and features, including:

- newer actions/rate-limit menu work
- GitHub reference lookup and preview support
- notification settings and GitHub PR notification support
- iOS/share-extension related project changes
- split GitHub REST API files such as `GitHubRestAPI+Actions.swift`

The menu-stability and workflow-dispatch changes were replayed on top of that fork instead of replacing those refactors.

## Local implementation notes

- `FIXED.md` records the original local menu-stability patch.
- `MenuReconciler.swift` is the shared AppKit menu diff primitive.
- `WorkflowDispatchInputParser.swift` intentionally handles the common `workflow_dispatch.inputs` YAML shape without adding a new dependency.
- `WorkflowRunNotifier.swift` tracks only runs started through RepoBar and reports final success/failure.

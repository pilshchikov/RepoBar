import AppKit
import Foundation
import RepoBarCore

extension RecentListMenuCoordinator {
    func workflowState(repoFullName: String, workflow: RepoWorkflowSummary) -> WorkflowMenuState {
        let key = WorkflowMenuState.key(fullName: repoFullName, workflowID: workflow.id)
        if let existing = self.workflowStates[key] {
            existing.workflow = workflow
            return existing
        }

        let state = WorkflowMenuState(fullName: repoFullName, workflow: workflow)
        self.workflowStates[key] = state
        return state
    }

    func populateWorkflowMenuLoading(_ menu: NSMenu, state: WorkflowMenuState) {
        let header = ListMenuHeader(
            title: "Open Workflow",
            action: state.workflow.url == nil ? nil : #selector(StatusBarMenuManager.openURLItem(_:)),
            systemImage: "play.rectangle",
            representedObject: state.workflow.url
        )
        self.populateListMenu(menu, header: header, content: .message("Loading…"))
    }

    func refreshWorkflowMenu(menu: NSMenu, entry: WorkflowMenuEntry) async {
        let state = entry.state
        guard let (owner, name) = self.ownerAndName(from: state.fullName) else {
            self.populateWorkflowMenu(menu, state: state, runs: [], message: "Invalid repository name")
            return
        }

        if entry.hasLoaded == false {
            do {
                let runs = try await self.appState.github.recentWorkflowRuns(
                    owner: owner,
                    name: name,
                    workflowID: state.workflow.id,
                    limit: 10
                )
                entry.runs = runs
                entry.hasLoaded = true
            } catch {
                self.populateWorkflowMenu(menu, state: state, runs: entry.runs, message: Self.failureMessage(for: error))
                menu.update()
                return
            }
        }

        self.populateWorkflowMenu(menu, state: state, runs: entry.runs, message: nil)
        menu.update()
    }

    private func populateWorkflowMenu(
        _ menu: NSMenu,
        state: WorkflowMenuState,
        runs: [RepoWorkflowRunSummary],
        message: String?
    ) {
        let header = ListMenuHeader(
            title: "Open Workflow",
            action: state.workflow.url == nil ? nil : #selector(StatusBarMenuManager.openURLItem(_:)),
            systemImage: "play.rectangle",
            representedObject: state.workflow.url
        )

        self.populateListMenu(
            menu,
            header: header,
            content: .items(isEmpty: false, emptyTitle: nil) { target in
                if let message {
                    self.addEmptyListItem(message, to: target)
                    return
                }

                let runsHeader = self.makeListItem(
                    title: "Recent Runs",
                    action: nil,
                    representedObject: nil,
                    systemImage: "clock.arrow.circlepath",
                    isEnabled: false
                )
                target.addItem(runsHeader)

                if runs.isEmpty {
                    self.addEmptyListItem("No recent runs", to: target)
                } else {
                    for run in runs.prefix(10) {
                        self.addWorkflowRunMenuItem(run, to: target)
                    }
                }
            }
        )
    }
}

@MainActor
final class WorkflowMenuEntry {
    weak var menu: NSMenu?
    let state: WorkflowMenuState
    var runs: [RepoWorkflowRunSummary] = []
    var hasLoaded = false

    init(menu: NSMenu, state: WorkflowMenuState) {
        self.menu = menu
        self.state = state
    }
}

@MainActor
final class WorkflowMenuState {
    let fullName: String
    var workflow: RepoWorkflowSummary
    weak var menu: NSMenu?

    init(fullName: String, workflow: RepoWorkflowSummary) {
        self.fullName = fullName
        self.workflow = workflow
    }

    static func key(fullName: String, workflowID: Int) -> String {
        "\(fullName)#\(workflowID)"
    }
}

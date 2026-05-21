import AppKit
import Foundation
import RepoBarCore

extension RecentListMenuCoordinator {
    func workflowState(repoFullName: String, workflow: RepoWorkflowSummary) -> WorkflowDispatchMenuState {
        let key = WorkflowDispatchMenuState.key(fullName: repoFullName, workflowID: workflow.id)
        if let existing = self.workflowStates[key] {
            existing.workflow = workflow
            return existing
        }

        let state = WorkflowDispatchMenuState(fullName: repoFullName, workflow: workflow)
        self.workflowStates[key] = state
        return state
    }

    func populateWorkflowMenuLoading(_ menu: NSMenu, state: WorkflowDispatchMenuState) {
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
            self.populateWorkflowMenu(menu, state: state, branches: [], runs: [], message: "Invalid repository name")
            return
        }

        if entry.hasLoaded == false {
            do {
                async let branches = self.appState.github.recentBranchesByCommitDate(owner: owner, name: name, limit: 10)
                async let runs = self.appState.github.recentWorkflowRuns(
                    owner: owner,
                    name: name,
                    workflowID: state.workflow.id,
                    limit: 10
                )
                let loadedBranches = try await branches
                let loadedRuns = try await runs
                entry.branches = loadedBranches
                entry.runs = loadedRuns
                entry.hasLoaded = true
                if state.selectedBranch == nil {
                    state.selectedBranch = loadedBranches.first?.name
                }
            } catch {
                self.populateWorkflowMenu(menu, state: state, branches: entry.branches, runs: entry.runs, message: Self.failureMessage(for: error))
                menu.update()
                return
            }
        }

        self.populateWorkflowMenu(menu, state: state, branches: entry.branches, runs: entry.runs, message: nil)
        menu.update()
    }

    func refreshWorkflowMenu(for state: WorkflowDispatchMenuState) {
        guard let menu = state.menu,
              let entry = self.workflowMenus[ObjectIdentifier(menu)]
        else { return }

        self.populateWorkflowMenu(menu, state: state, branches: entry.branches, runs: entry.runs, message: nil)
        menu.update()
    }

    private func populateWorkflowMenu(
        _ menu: NSMenu,
        state: WorkflowDispatchMenuState,
        branches: [RepoBranchSummary],
        runs: [RepoWorkflowRunSummary],
        message: String?
    ) {
        let header = ListMenuHeader(
            title: "Open Workflow",
            action: state.workflow.url == nil ? nil : #selector(StatusBarMenuManager.openURLItem(_:)),
            systemImage: "play.rectangle",
            representedObject: state.workflow.url
        )
        var actions: [ListMenuAction] = [
            ListMenuAction(
                title: "Run Action",
                action: #selector(StatusBarMenuManager.runWorkflowDispatch(_:)),
                systemImage: "play.fill",
                representedObject: WorkflowRunCommand(state: state),
                isEnabled: state.canRun
            )
        ]

        if let missing = state.missingRequiredInputs.first {
            actions.append(ListMenuAction(
                title: "Missing: \(missing)",
                action: #selector(StatusBarMenuManager.menuItemNoOp(_:)),
                systemImage: "exclamationmark.triangle",
                representedObject: state,
                isEnabled: false
            ))
        }

        self.populateListMenu(
            menu,
            header: header,
            actions: actions,
            content: .items(isEmpty: false, emptyTitle: nil) { target in
                if let message {
                    self.addEmptyListItem(message, to: target)
                    return
                }

                target.addItem(self.branchSelectionMenuItem(branches: branches, state: state))
                if state.workflow.inputs.isEmpty == false {
                    target.addItem(.separator())
                    for input in state.workflow.inputs {
                        target.addItem(self.inputMenuItem(input, state: state))
                    }
                }

                target.addItem(.separator())
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

    private func branchSelectionMenuItem(branches: [RepoBranchSummary], state: WorkflowDispatchMenuState) -> NSMenuItem {
        let title = state.selectedBranch.map { "Branch: \($0)" } ?? "Choose Branch"
        let item = self.makeListItem(
            title: title,
            action: nil,
            representedObject: state,
            systemImage: "arrow.triangle.branch",
            isEnabled: branches.isEmpty == false
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for branch in branches {
            let branchItem = NSMenuItem(
                title: branch.name,
                action: #selector(StatusBarMenuManager.selectWorkflowBranch(_:)),
                keyEquivalent: ""
            )
            branchItem.target = self.actionHandler
            branchItem.representedObject = WorkflowBranchSelectionCommand(state: state, branchName: branch.name)
            branchItem.state = branch.name == state.selectedBranch ? .on : .off
            submenu.addItem(branchItem)
        }
        item.submenu = submenu
        return item
    }

    private func inputMenuItem(_ input: RepoWorkflowDispatchInput, state: WorkflowDispatchMenuState) -> NSMenuItem {
        let current = state.value(for: input)
        let required = input.isRequired ? " *" : ""
        let title = current.isEmpty ? "\(input.name)\(required): Not set" : "\(input.name)\(required): \(current)"
        let item = self.makeListItem(
            title: title,
            action: #selector(StatusBarMenuManager.editWorkflowInput(_:)),
            representedObject: WorkflowInputEditCommand(state: state, input: input),
            systemImage: self.inputSystemImage(for: input),
            isEnabled: true
        )
        item.toolTip = input.description

        if input.type == "boolean" || input.options.isEmpty == false {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let values = input.type == "boolean" ? ["true", "false"] : input.options
            for value in values {
                let choice = NSMenuItem(
                    title: value,
                    action: #selector(StatusBarMenuManager.chooseWorkflowInputValue(_:)),
                    keyEquivalent: ""
                )
                choice.target = self.actionHandler
                choice.representedObject = WorkflowInputChoiceCommand(state: state, inputName: input.name, value: value)
                choice.state = value == current ? .on : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            item.action = #selector(StatusBarMenuManager.menuItemNoOp(_:))
        }

        return item
    }

    private func inputSystemImage(for input: RepoWorkflowDispatchInput) -> String {
        switch input.type {
        case "choice": "list.bullet"
        case "boolean": "checkmark.circle"
        case "number": "number"
        case "environment": "shippingbox"
        default: "text.cursor"
        }
    }
}

@MainActor
final class WorkflowMenuEntry {
    weak var menu: NSMenu?
    let state: WorkflowDispatchMenuState
    var branches: [RepoBranchSummary] = []
    var runs: [RepoWorkflowRunSummary] = []
    var hasLoaded = false

    init(menu: NSMenu, state: WorkflowDispatchMenuState) {
        self.menu = menu
        self.state = state
    }
}

@MainActor
final class WorkflowDispatchMenuState {
    let fullName: String
    var workflow: RepoWorkflowSummary
    weak var menu: NSMenu?
    var selectedBranch: String?
    var inputValues: [String: String]

    init(fullName: String, workflow: RepoWorkflowSummary) {
        self.fullName = fullName
        self.workflow = workflow
        self.inputValues = Dictionary(uniqueKeysWithValues: workflow.inputs.compactMap { input in
            guard let defaultValue = input.defaultValue, !defaultValue.isEmpty else { return nil }
            return (input.name, defaultValue)
        })
    }

    static func key(fullName: String, workflowID: Int) -> String {
        "\(fullName)#\(workflowID)"
    }

    var canRun: Bool {
        self.selectedBranch?.isEmpty == false && self.missingRequiredInputs.isEmpty
    }

    var missingRequiredInputs: [String] {
        self.workflow.inputs.compactMap { input in
            guard input.isRequired else { return nil }
            return self.value(for: input).isEmpty ? input.name : nil
        }
    }

    func value(for input: RepoWorkflowDispatchInput) -> String {
        self.inputValues[input.name] ?? input.defaultValue ?? ""
    }

    var dispatchInputs: [String: String] {
        var values: [String: String] = [:]
        for input in self.workflow.inputs {
            let value = self.value(for: input).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values[input.name] = value
            }
        }
        return values
    }
}

final class WorkflowBranchSelectionCommand {
    let state: WorkflowDispatchMenuState
    let branchName: String

    init(state: WorkflowDispatchMenuState, branchName: String) {
        self.state = state
        self.branchName = branchName
    }
}

final class WorkflowInputEditCommand {
    let state: WorkflowDispatchMenuState
    let input: RepoWorkflowDispatchInput

    init(state: WorkflowDispatchMenuState, input: RepoWorkflowDispatchInput) {
        self.state = state
        self.input = input
    }
}

final class WorkflowInputChoiceCommand {
    let state: WorkflowDispatchMenuState
    let inputName: String
    let value: String

    init(state: WorkflowDispatchMenuState, inputName: String, value: String) {
        self.state = state
        self.inputName = inputName
        self.value = value
    }
}

final class WorkflowRunCommand {
    let state: WorkflowDispatchMenuState

    init(state: WorkflowDispatchMenuState) {
        self.state = state
    }
}

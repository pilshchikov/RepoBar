import Foundation
import RepoBarCore
import UserNotifications

actor WorkflowRunNotifier {
    static let shared = WorkflowRunNotifier()
    private let center: UNUserNotificationCenter?

    init() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
    }

    func notify(title: String, body: String) async {
        guard let center = self.center else { return }
        guard await self.isAuthorized(using: center) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        _ = try? await center.add(request)
    }

    func monitor(
        github: GitHubClient,
        owner: String,
        name: String,
        repoFullName: String,
        workflowID: Int,
        workflowName: String,
        branch: String,
        startedAt: Date
    ) async {
        let earliest = startedAt.addingTimeInterval(-10)
        var trackedRunID: Int?

        for _ in 0 ..< 80 {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }

            guard let run = try? await self.matchingRun(
                github: github,
                owner: owner,
                name: name,
                workflowID: workflowID,
                branch: branch,
                earliest: earliest,
                trackedRunID: trackedRunID
            ) else {
                continue
            }

            trackedRunID = run.id
            guard run.status != .pending else { continue }

            let outcome = run.status == .passing ? "completed" : "failed"
            await self.notify(
                title: "Workflow \(outcome)",
                body: "\(workflowName) on \(repoFullName) (\(branch))"
            )
            return
        }
    }

    private func matchingRun(
        github: GitHubClient,
        owner: String,
        name: String,
        workflowID: Int,
        branch: String,
        earliest: Date,
        trackedRunID: Int?
    ) async throws -> RepoWorkflowRunSummary? {
        let runs = try await github.recentWorkflowRuns(
            owner: owner,
            name: name,
            workflowID: workflowID,
            branch: branch,
            limit: 10
        )

        if let trackedRunID, let tracked = runs.first(where: { $0.id == trackedRunID }) {
            return tracked
        }

        return runs.first { run in
            guard run.event == nil || run.event == "workflow_dispatch" else { return false }
            guard run.branch == nil || run.branch == branch else { return false }
            let timestamp = run.createdAt ?? run.updatedAt
            return timestamp >= earliest
        }
    }

    private func isAuthorized(using center: UNUserNotificationCenter) async -> Bool {
        let status = await self.authorizationStatus(using: center)
        switch status {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return await self.requestAuthorization(using: center)
        default:
            return false
        }
    }

    private func authorizationStatus(using center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestAuthorization(using center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

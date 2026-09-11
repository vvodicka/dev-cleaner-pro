import Foundation
import Observation
import DevCleanerProCore

/// Live state of a running deletion, driving the progress sheet.
@Observable
@MainActor
final class DeleteProgress: Identifiable {
    let id = UUID()
    let plan: DeletionPlan
    private(set) var outcomes: [DeleteOutcome] = []
    private(set) var isFinished = false

    init(plan: DeletionPlan) {
        self.plan = plan
    }

    func record(_ outcome: DeleteOutcome) {
        outcomes.append(outcome)
    }

    func complete() {
        isFinished = true
    }

    var doneCount: Int { outcomes.count }
    var totalCount: Int { plan.totalCount }
    var remainingCount: Int { max(0, totalCount - doneCount) }
    var freedBytes: Int64 { outcomes.reduce(0) { $0 + $1.freed } }
    var failureCount: Int { outcomes.count { !$0.succeeded } }

    var fraction: Double {
        totalCount == 0 ? 1 : Double(doneCount) / Double(totalCount)
    }

    var headline: String { "Deleting — \(doneCount) of \(totalCount)" }
    var byteProgress: String {
        ByteFormatting.progress(done: freedBytes, total: plan.totalBytes)
    }

    var failureSummary: String? {
        switch failureCount {
        case 0: nil
        case 1: "1 item failed"
        default: "\(failureCount) items failed"
        }
    }
}

/// Transient confirmation after a deletion.
struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let offersEmptyTrash: Bool
}

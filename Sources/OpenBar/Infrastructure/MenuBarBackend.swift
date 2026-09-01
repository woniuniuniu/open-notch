import CoreGraphics
import Foundation
import OpenBarCore

@MainActor
protocol MenuBarBackend: AnyObject {
    var name: String { get }
    var capabilities: BackendCapabilities { get }
    var requiresAccessibility: Bool { get }
    var excludedWindowIDs: Set<CGWindowID> { get }

    func setExpanded(_ expanded: Bool)
    func scan() -> [LiveMenuBarItem]
    func apply(
        document: PolicyDocument,
        liveItems: [LiveMenuBarItem],
        reason: ApplyReason
    ) -> BackendApplyResult
    func stop()
}

@MainActor
enum MenuBarBackendFactory {
    static func make(
        legacySections: LegacySectionController?,
        onAssessmentApplied: @escaping () -> Void = {}
    ) -> MenuBarBackend {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return MenuBarAgentBackend(onAssessmentApplied: onAssessmentApplied)
        }
        return LegacyMenuBarBackend(sections: legacySections ?? LegacySectionController())
    }
}

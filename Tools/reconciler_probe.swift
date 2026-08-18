import Foundation

@main
struct ReconcilerProbe {
    static func main() {
        let boundary = CGRect(x: 100, y: 0, width: 1, height: 24)
        let misplaced = item(frame: CGRect(x: 20, y: 0, width: 20, height: 24))
        let correctlyPlaced = item(frame: CGRect(x: 120, y: 0, width: 20, height: 24))
        let desired = [misplaced.id: ItemDisposition.visible]
        let start = Date(timeIntervalSince1970: 1_000)
        var reconciler = LayoutReconciler()

        precondition(reconciler.observe(items: [misplaced], boundary: boundary, desiredPositions: desired, now: start) == nil)
        precondition(reconciler.observe(items: [misplaced], boundary: boundary, desiredPositions: desired, now: start.addingTimeInterval(0.5)) == nil)
        precondition(reconciler.observe(items: [misplaced], boundary: boundary, desiredPositions: desired, now: start.addingTimeInterval(1.1)) != nil)

        precondition(reconciler.observe(items: [correctlyPlaced], boundary: boundary, desiredPositions: desired, now: start.addingTimeInterval(2.2)) == nil)
        precondition(reconciler.observe(items: [misplaced], boundary: boundary, desiredPositions: desired, now: start.addingTimeInterval(3.3)) == nil)
        print("LayoutReconciler probe passed")
    }

    private static func item(frame: CGRect) -> MenuBarItem {
        MenuBarItem(
            id: "app:probe",
            windowID: 1,
            hostPID: 1,
            hostBundleIdentifier: "com.example.probe",
            semanticBundleIdentifier: "com.example.probe",
            semanticIdentifier: "",
            rawTitle: "Probe",
            displayName: "Probe",
            symbolName: "app",
            frame: frame,
            isProtected: false
        )
    }
}

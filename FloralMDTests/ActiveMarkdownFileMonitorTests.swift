import Foundation
import Testing

@testable import FloralMD

@Suite(.serialized)
struct ActiveMarkdownFileMonitorTests {
    @Test func parentDirectoryPresenterSurvivesAtomicReplacementAndEmitsTrailingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-FileMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Active.md")
        try "zero".write(to: note, atomically: true, encoding: .utf8)
        let recorder = EventRecorder()
        let monitor = ActiveMarkdownFileMonitor(url: note, debounceInterval: 0.08) { event in
            recorder.append(event)
        }
        #expect(!monitor.responds(to: NSSelectorFromString("primaryPresentedItemURL")))
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let store = CoordinatedMarkdownDiskStore()
        try store.save("one", at: note)
        try store.save("two", at: note)
        try store.save("final", at: note)

        for _ in 0..<80 {
            if recorder.count > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(recorder.count == 1)
        #expect(try String(contentsOf: note, encoding: .utf8) == "final")

        let countBeforeStop = recorder.count
        monitor.stop()
        try store.save("after stop", at: note)
        try await Task.sleep(for: .milliseconds(180))
        #expect(recorder.count == countBeforeStop)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ActiveMarkdownFileMonitor.Event] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func append(_ event: ActiveMarkdownFileMonitor.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

import Foundation

@MainActor
public final class AgentInboxMonitor {
    public var onEvent: ((AgentEvent) -> Void)?
    public var onError: ((Error) -> Void)?

    private let inbox: URL
    private var timer: Timer?
    private var isProcessing = false

    public init(inbox: URL) {
        self.inbox = inbox
    }

    public func start() {
        guard timer == nil else { return }
        processInbox()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processInbox() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func processInbox() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            for file in files.prefix(200) {
                do {
                    let data = try Data(contentsOf: file)
                    let event = try AgentEventParser.parse(envelope: data)
                    onEvent?(event)
                    try FileManager.default.removeItem(at: file)
                } catch {
                    let failed = file.deletingPathExtension().appendingPathExtension("failed")
                    try? FileManager.default.moveItem(at: file, to: failed)
                    onError?(error)
                }
            }
        } catch {
            onError?(error)
        }
    }
}

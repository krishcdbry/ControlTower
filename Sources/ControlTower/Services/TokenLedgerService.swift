import ControlTowerCore
import CoreServices
import Foundation
import Logging

// MARK: - Token Ledger Store (Observable)

/// App-side observable wrapper around `TokenLedger`. Views read `snapshot`;
/// refreshes are incremental (steady-state is a stat pass over the roots).
@MainActor
@Observable
final class TokenLedgerStore {
    private(set) var snapshot: LedgerSnapshot?
    private(set) var isLoading = false

    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false

    /// Refreshes the snapshot. Calls arriving while a scan is in flight are
    /// coalesced into one trailing scan so no change notification is lost.
    func refresh(force: Bool = false) {
        guard self.refreshTask == nil else {
            self.pendingRefresh = true
            return
        }
        self.isLoading = self.snapshot == nil
        self.refreshTask = Task { [weak self] in
            let result = await TokenLedger.shared.snapshot(forceScan: force)
            guard let self else { return }
            self.snapshot = result
            self.isLoading = false
            self.refreshTask = nil
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh(force: true)
            }
        }
    }

    func refreshAndWait(force: Bool = false) async {
        self.refresh(force: force)
        await self.refreshTask?.value
    }
}

// MARK: - Transcript Watcher (FSEvents)

/// Watches Claude transcript directories with FSEvents and fires a debounced
/// callback when sessions write — this is what makes token counts tick live
/// while Claude Code / Claude Desktop / Cowork are running.
final class TranscriptWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.controltower.transcript-watcher", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let logger = Logger(label: "com.controltower.transcript-watcher")

    init?(
        paths: [String],
        debounce: TimeInterval = 2.0,
        onChange: @escaping @Sendable () -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        self.onChange = onChange
        self.debounceInterval = debounce

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvents()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // FSEvents-level coalescing latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }

        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, self.queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.streamRef = nil
            return nil
        }
        self.logger.info("Watching transcript roots: \(paths)")
    }

    private func handleEvents() {
        self.debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onChange] in
            onChange()
        }
        self.debounceWorkItem = workItem
        self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
    }

    func stop() {
        guard let stream = self.streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.streamRef = nil
    }

    deinit {
        self.stop()
    }
}

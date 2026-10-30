import AppKit
import ScreenCaptureKit

/// 「ウィンドウを収録」の一連の流れをまとめる。
///
/// 1. 画面をフリーズさせてウィンドウを選ばせる（静止画のウィンドウ選択と同じオーバーレイ）
/// 2. 収録前のバーで音声・ポインタ・画質を決める
/// 3. カウントダウンのあと収録する（メニューバーに経過時間と停止ボタン）
/// 4. 止めたら履歴へ保存し、撮影後サムネイルを出す
@MainActor
final class RecordingCoordinator: ObservableObject {

    static let shared = RecordingCoordinator()

    enum State: Equatable {
        case idle
        case selecting
        case preparing
        case countingDown
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle

    /// 収録を始めてからの経過秒数。メニューバーの表示に使う。
    @Published private(set) var elapsed: TimeInterval = 0

    /// 収録しているウィンドウのアプリ名。メニューバーのメニューに出す。
    @Published private(set) var targetAppName: String?

    /// 開始に必要な空き容量。下回っていたら始めない。
    private static let minimumFreeSpaceToStart: Int64 = 2_000_000_000
    /// 収録中にここまで減ったら、ディスクを使い切る前に止める。
    private static let minimumFreeSpaceWhileRecording: Int64 = 500_000_000

    private let captureService = ScreenCaptureService()
    private let selectionController = AreaSelectionController()

    private var recorder: ScreenRecorder?
    private var recordingStartDate = Date()
    private var options = Preferences.recordingOptions
    private var ticker: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    private init() {}

    var isRecording: Bool { state == .recording }

    /// ホットキーから呼ぶ。待機中なら始め、収録中なら止める。
    func toggle() {
        switch state {
        case .idle:      start()
        case .recording: stop()
        default:         break
        }
    }

    func start() {
        guard state == .idle else { return }

        guard captureService.hasScreenRecordingPermission else {
            captureService.requestScreenRecordingPermission()
            OnboardingWindowController.show()
            return
        }

        CaptureThumbnailPresenter.dismissImmediately()
        state = .selecting

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runStartFlow()
            } catch {
                self.cleanUpAfterFailure()
                AlertPresenter.showError(error, title: "収録を開始できませんでした")
            }
        }
    }

    /// 収録を止めて保存する。
    /// - Parameter reason: こちらから止めた理由（ウィンドウが閉じられた、など）。HUD で知らせる。
    func stop(reason: String? = nil) {
        finishRecording { [weak self] recorder in
            guard let self else { return }
            do {
                let result = try await recorder.stop()
                let url = try await HistoryStore.shared.storeRecording(
                    result,
                    hasSystemAudio: self.options.recordsSystemAudio,
                    hasMicrophone: self.options.recordsMicrophone,
                    pointScale: recorder.pointScale,
                    date: self.recordingStartDate
                )
                self.presentFinishedRecording(at: url, result: result, reason: reason)
            } catch {
                AlertPresenter.showError(error, title: "収録を保存できませんでした")
            }
        }
    }

    /// 収録を止めて、ファイルを保存せずに捨てる。
    func discard() {
        finishRecording { recorder in
            if let result = try? await recorder.stop() {
                try? FileManager.default.removeItem(at: result.url)
            }
            HUDPresenter.show("収録を破棄しました", symbolName: "trash.fill")
        }
    }

    private func finishRecording(_ body: @escaping (ScreenRecorder) async -> Void) {
        guard state == .recording, let recorder else { return }
        state = .finishing
        stopTicker()

        Task { [weak self] in
            await body(recorder)
            guard let self else { return }
            self.recorder = nil
            self.targetAppName = nil
            self.state = .idle
            self.elapsed = 0
        }
    }

    #if DEBUG
    /// メニューバーの見た目を確かめるため、収録せずに収録中の状態にする。
    func debugSimulateRecording(elapsed: TimeInterval, appName: String) {
        targetAppName = appName
        self.elapsed = elapsed
        state = .recording
    }
    #endif

    // MARK: - 開始までの流れ

    private func runStartFlow() async throws {
        let snapshots = try await captureService.captureAllDisplays()

        guard let selection = await selectWindow(in: snapshots),
              let windowID = selection.windowID
        else {
            state = .idle
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.captureFailed("選んだウィンドウが見つかりませんでした")
        }

        state = .preparing
        let appName = window.owningApplication?.applicationName ?? "ウィンドウ"
        guard let targetFrame = await RecordingSetupPanel.run(
            windowID: windowID,
            initialFrame: selection.rect,
            appName: appName
        ) else {
            state = .idle
            return
        }

        // 待っている間に大きさを変えられていることがあるので、最新のウィンドウ情報を取り直す。
        let latestContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let latestWindow = latestContent.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.captureFailed("選んだウィンドウが閉じられました")
        }

        options = Preferences.recordingOptions
        if options.recordsMicrophone, !(await MicrophoneCapture.requestAccessIfNeeded()) {
            options.recordsMicrophone = false
            HUDPresenter.show("マイクが許可されていないため、マイクなしで収録します", symbolName: "mic.slash.fill", duration: 2.4)
        }

        if let free = HistoryStore.shared.availableDiskSpace, free < Self.minimumFreeSpaceToStart {
            throw RecordingError.notEnoughDiskSpace
        }

        if Preferences.recordingCountdown {
            state = .countingDown
            guard await RecordingCountdownPanel.run(seconds: 3, over: targetFrame) else {
                state = .idle
                return
            }
        }

        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)) }?
            .backingScaleFactor ?? 2
        let date = Date()
        let recorder = try ScreenRecorder(
            window: latestWindow,
            scale: scale,
            options: options,
            outputURL: HistoryStore.shared.temporaryRecordingURL(for: date)
        )
        recorder.onUnexpectedStop = { [weak self] _ in
            self?.stop(reason: "ウィンドウが閉じられたため収録を終了しました")
        }
        try await recorder.start()

        self.recorder = recorder
        targetAppName = appName
        recordingStartDate = date
        elapsed = 0
        state = .recording
        startTicker()
    }

    private func selectWindow(in snapshots: [DisplaySnapshot]) async -> SelectionResult? {
        await withCheckedContinuation { continuation in
            selectionController.begin(snapshots: snapshots, mode: .window, actionVerb: "収録") { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func cleanUpAfterFailure() {
        stopTicker()
        recorder = nil
        targetAppName = nil
        state = .idle
        elapsed = 0
    }

    // MARK: - 収録中

    private func startTicker() {
        // 長時間の収録でスリープや画面の消灯が起きると映像が止まるので、収録中は抑止する。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "画面を収録しています"
        )

        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state == .recording else { return }
                self.elapsed = Date().timeIntervalSince(self.recordingStartDate)

                tick += 1
                if tick % 30 == 0,
                   let free = HistoryStore.shared.availableDiskSpace,
                   free < Self.minimumFreeSpaceWhileRecording {
                    self.stop(reason: "ディスクの空きが少なくなったため収録を終了しました")
                    return
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - 収録後

    private func presentFinishedRecording(at url: URL, result: RecordingWriterResult, reason: String?) {
        if let reason {
            HUDPresenter.show(reason, symbolName: "stop.circle.fill", duration: 2.4)
        }

        Pasteboard.copy(fileURL: url)

        if Preferences.afterCaptureAction == .openEditor {
            VideoEditorWindowController.present(url: url)
            return
        }

        guard let poster = result.poster, Preferences.afterCaptureAction != .copyOnly else {
            if reason == nil {
                HUDPresenter.show("収録した動画をクリップボードにコピーしました", symbolName: "checkmark.circle.fill")
            }
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        CaptureThumbnailPresenter.show(
            image: poster,
            pointSize: CGSize(width: CGFloat(poster.width) / scale, height: CGFloat(poster.height) / scale),
            videoDuration: result.duration
        ) {
            VideoEditorWindowController.present(url: url)
        }
    }
}

enum RecordingError: LocalizedError {
    case notEnoughDiskSpace

    var errorDescription: String? {
        switch self {
        case .notEnoughDiskSpace:
            return "ディスクの空きが足りません（2GB 以上必要です）。"
        }
    }
}

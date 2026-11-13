import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit

/// 「ウィンドウを収録」の一連の流れをまとめる。
///
/// 1. 画面をフリーズさせてウィンドウを選ばせる（静止画のウィンドウ選択と同じオーバーレイ）
/// 2. 収録前のバーで音声・ポインタ・画質と、開始・終了の時刻を決める
/// 3. カウントダウンのあと収録する（メニューバーに経過時間と停止ボタン）。
///    開始時刻を指定したときは、その時刻まで待ってからカウントダウンなしで始める
/// 4. 止めたら履歴へ保存し、撮影後サムネイルを出す。終了時刻を指定したときは、その時刻に自動で止める
@MainActor
final class RecordingCoordinator: ObservableObject {

    static let shared = RecordingCoordinator()

    enum State: Equatable {
        case idle
        case selecting
        case preparing
        /// 開始時刻を待っている。
        case scheduled
        case countingDown
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle

    /// 収録を始めてからの経過秒数。メニューバーの表示に使う。
    @Published private(set) var elapsed: TimeInterval = 0

    /// 収録しているウィンドウのアプリ名。メニューバーのメニューに出す。
    @Published private(set) var targetAppName: String?

    /// 予約した開始時刻。待っている間だけ入る。
    @Published private(set) var scheduledStart: Date?
    /// 予約した終了時刻。待っている間と収録中に入る。
    @Published private(set) var scheduledStop: Date?
    /// 開始時刻までの残り秒数。メニューバーの表示に使う。
    @Published private(set) var remainingUntilStart: TimeInterval = 0

    /// 予約の取り消し・今すぐ開始を待機中のループへ伝える。
    private var isScheduleCancelled = false

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

    /// 収録を始める前の操作の途中（ウィンドウ選択・収録前のバー・カウントダウン）か。
    var isSettingUp: Bool {
        state == .selecting || state == .preparing || state == .countingDown
    }

    /// ホットキーから呼ぶ。待機中なら始め、収録中なら止める。
    /// 予約中は、うっかり取り消さないよう何もしない（取り消しはメニューバーから）。
    func toggle() {
        switch state {
        case .idle:      start()
        case .recording: stop()
        case .scheduled:
            HUDPresenter.show("収録を予約しています。取り消しや今すぐ開始はメニューバーから", symbolName: "timer", duration: 2.4)
        default:         break
        }
    }

    /// 予約を取り消す。
    func cancelSchedule() {
        guard state == .scheduled else { return }
        isScheduleCancelled = true
    }

    /// 予約した時刻を待たずに今すぐ始める。
    func startScheduledNow() {
        guard state == .scheduled else { return }
        scheduledStart = Date()
    }

    func start() {
        guard state == .idle else { return }

        // 静止画の範囲選択の途中に始めると、選択用のオーバーレイが二重に出てしまう。
        guard !CaptureCoordinator.shared.isBusy else {
            NSSound.beep()
            return
        }

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
                let (url, result) = try await self.save(recorder)
                self.presentFinishedRecording(at: url, result: result, reason: reason)
            } catch {
                // 書き込みの途中で失敗しても、そこまでの分はフラグメントとして残っていることがある。
                // 次の起動を待たずに、いま履歴へ救い出しておく。
                await HistoryStore.shared.recoverInterruptedRecordings()
                AlertPresenter.showError(error, title: "収録を保存できませんでした")
            }
        }
    }

    private func save(_ recorder: ScreenRecorder) async throws -> (URL, RecordingWriterResult) {
        let result = try await recorder.stop()
        let url = try await HistoryStore.shared.storeRecording(
            result,
            hasSystemAudio: options.recordsSystemAudio,
            hasMicrophone: options.recordsMicrophone,
            pointScale: recorder.pointScale,
            date: recordingStartDate
        )
        return (url, result)
    }

    /// アプリを終了する前に呼ぶ。収録中なら保存し、保存の途中ならそれが済むまで待つ。
    /// サムネイルやエディタは出さない（すぐ終了するので）。
    func finishBeforeTermination() async {
        finishRecording { [weak self] recorder in
            // 失敗しても書きかけのファイルは残り、次の起動時に履歴へ移される。
            _ = try? await self?.save(recorder)
        }
        while state == .finishing {
            try? await Task.sleep(nanoseconds: 50_000_000)
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
            self.scheduledStop = nil
            self.state = .idle
            self.elapsed = 0
        }
    }

    #if DEBUG
    /// 見た目の確認用に状態だけを作っているか。終了時の確認を出さないために見る。
    private(set) var isDebugSimulation = false

    /// メニューバーの見た目を確かめるため、収録せずに収録中の状態にする。
    func debugSimulateRecording(elapsed: TimeInterval, appName: String) {
        isDebugSimulation = true
        targetAppName = appName
        self.elapsed = elapsed
        state = .recording
    }

    /// メニューバーの見た目を確かめるため、収録を予約している状態にする。
    func debugSimulateScheduled(start: Date, stop: Date?, appName: String) {
        isDebugSimulation = true
        targetAppName = appName
        scheduledStart = start
        scheduledStop = stop
        remainingUntilStart = start.timeIntervalSinceNow
        state = .scheduled
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
        guard let setup = await RecordingSetupPanel.run(
            windowID: windowID,
            initialFrame: selection.rect,
            appName: appName
        ) else {
            state = .idle
            return
        }

        try await proceed(windowID: windowID, appName: appName, frame: setup.frame, schedule: setup.schedule)
    }

    /// 収録前のバーで決めたあと。予約なら時刻まで待ち、それから収録を始める。
    func proceed(windowID: CGWindowID, appName: String, frame: CGRect, schedule: RecordingSchedule) async throws {
        options = Preferences.recordingOptions
        if options.recordsMicrophone, !(await MicrophoneCapture.requestAccessIfNeeded()) {
            options.recordsMicrophone = false
            HUDPresenter.show("マイクが許可されていないため、マイクなしで収録します", symbolName: "mic.slash.fill", duration: 2.4)
        }

        if let free = HistoryStore.shared.availableDiskSpace, free < Self.minimumFreeSpaceToStart {
            throw RecordingError.notEnoughDiskSpace
        }

        targetAppName = appName
        scheduledStop = schedule.stop

        if let start = schedule.start {
            scheduledStart = start
            HUDPresenter.show(
                "\(RecordingSchedule.timeText(start)) から収録します（メニューバーで取り消せます）",
                symbolName: "timer",
                duration: 2.4
            )
            switch await waitForScheduledStart(windowID: windowID) {
            case .start:
                // Mac がスリープしていて、目が覚めたら終了時刻まで過ぎていた場合は収録しない。
                if let stop = schedule.stop, Date() >= stop {
                    resetSchedule()
                    state = .idle
                    AlertPresenter.showError(
                        ScreenCaptureError.captureFailed("予約した時間（\(RecordingSchedule.timeText(start)) 〜 \(RecordingSchedule.timeText(stop, relativeTo: start))）を過ぎていたため、収録しませんでした。Mac がスリープしていた可能性があります"),
                        title: "予約した収録を開始できませんでした"
                    )
                    return
                }
                // 画面が消えていると映像が届かないので、ユーザーが触ったことにして起こす。
                Self.wakeDisplay()
            case .cancelled:
                resetSchedule()
                state = .idle
                HUDPresenter.show("収録の予約を取り消しました", symbolName: "xmark.circle.fill")
                return
            case .windowClosed:
                resetSchedule()
                state = .idle
                AlertPresenter.showError(
                    ScreenCaptureError.captureFailed("収録する予定だった \(appName) のウィンドウが閉じられたため、予約を取り消しました"),
                    title: "収録を開始できませんでした"
                )
                return
            }
        } else if Preferences.recordingCountdown {
            state = .countingDown
            guard await RecordingCountdownPanel.run(seconds: 3, over: frame) else {
                resetSchedule()
                state = .idle
                return
            }
        }

        try await beginRecording(windowID: windowID, appName: appName)
    }

    private func beginRecording(windowID: CGWindowID, appName: String) async throws {
        // 待っている間に大きさを変えたり最小化したりしていることがあるので、最新の情報を取り直す。
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.captureFailed("選んだウィンドウが閉じられました")
        }
        let frame = WindowLister.frame(of: windowID) ?? .zero

        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?
            .backingScaleFactor ?? 2
        let date = Date()
        let recorder = try ScreenRecorder(
            window: window,
            scale: scale,
            options: options,
            outputURL: HistoryStore.shared.temporaryRecordingURL(for: date)
        )
        recorder.onUnexpectedStop = { [weak self] _ in
            // ウィンドウが残っているなら、閉じられた以外の理由（システム側で共有を止めた、書き込みの失敗など）。
            let reason = WindowLister.frame(of: windowID) == nil
                ? "ウィンドウが閉じられたため収録を終了しました"
                : "収録が中断されたため、ここまでを保存しました"
            self?.stop(reason: reason)
        }
        try await recorder.start()

        self.recorder = recorder
        targetAppName = appName
        scheduledStart = nil
        recordingStartDate = date
        elapsed = 0
        state = .recording
        startTicker()
    }

    // MARK: - 予約

    private enum WaitResult {
        case start
        case cancelled
        case windowClosed
    }

    /// 開始時刻まで待つ。その間 Mac が眠らないようにし、ウィンドウが閉じられていないかも見張る。
    private func waitForScheduledStart(windowID: CGWindowID) async -> WaitResult {
        state = .scheduled
        isScheduleCancelled = false
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "収録の予約を待っています"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        while true {
            if isScheduleCancelled { return .cancelled }
            guard WindowLister.frame(of: windowID) != nil else { return .windowClosed }
            guard let start = scheduledStart else { return .cancelled }

            let remaining = start.timeIntervalSinceNow
            remainingUntilStart = max(0, remaining)
            if remaining <= 0 { return .start }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func resetSchedule() {
        scheduledStart = nil
        scheduledStop = nil
        remainingUntilStart = 0
        targetAppName = nil
    }

    /// 画面がスリープしていたら起こす（ユーザーが操作したことにする）。
    private static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Shotter の収録の予約" as CFString, kIOPMUserActiveLocal, &assertionID)
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
        resetSchedule()
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

                // 予約した終了時刻になったら止める。
                if let stopDate = self.scheduledStop, Date() >= stopDate {
                    self.stop(reason: "終了時刻になったため収録を終了しました")
                    return
                }

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

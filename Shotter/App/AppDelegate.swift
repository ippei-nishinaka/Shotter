import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Finder の「このアプリで開く」や `open -a Shotter <path>` で渡された画像を読み込めなかった場合のエラー。
enum FileOpenError: LocalizedError {
    case unreadableImage(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "\(url.lastPathComponent) を画像として読み込めませんでした。"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var purgeTimer: Timer?

    /// 予約中に終了してよいかを、もう確かめたか（再起動のとき二重に聞かないため）。
    private static var hasConfirmedQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement アプリでも ⌘Z / ⌘C / ⌘W を効かせるためにメインメニューを設定する。
        NSApp.mainMenu = MainMenu.build()
        let failedHotKeys = CaptureCoordinator.shared.registerStoredHotKeys()
        #if DEBUG
        DebugSupport.log(
            "ホットキー登録  範囲: \(Preferences.hotKey?.displayString ?? "なし")"
                + "  ウィンドウ: \(Preferences.windowHotKey?.displayString ?? "なし")"
                + "  文字認識: \(Preferences.textRecognitionHotKey?.displayString ?? "なし")"
                + "  収録: \(Preferences.recordingHotKey?.displayString ?? "なし")"
                + (failedHotKeys.isEmpty ? " → すべて成功" : " → 失敗: \(failedHotKeys.map(\.title))")
        )
        #endif
        statusItemController = StatusItemController()

        // 前回、収録中に落ちていたら、書きかけのファイルを履歴へ移す。
        Task { await HistoryStore.shared.recoverInterruptedRecordings() }

        // 保持期間を過ぎた履歴をファイルごと削除する。
        let purged = HistoryStore.shared.purgeExpired()
        #if DEBUG
        if purged > 0 { DebugSupport.log("期限切れの履歴を \(purged) 件削除しました") }
        #endif
        // メニューバーに常駐して何日も起動したままになるので、起動中も定期的に期限切れを片付ける。
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { _ = HistoryStore.shared.purgeExpired() }
        }

        OnboardingWindowController.showIfNeeded()

        #if DEBUG
        if DebugSupport.shouldOpenEditorOnLaunch {
            DebugSupport.openEditorWithSampleImage()
        }
        if DebugSupport.shouldOpenSettings {
            DebugSupport.openSettingsAndDump()
        }
        if DebugSupport.shouldOpenAbout {
            DebugSupport.openAboutAndDump()
        }
        if DebugSupport.shouldOpenOnboarding {
            DebugSupport.openOnboardingAndDump()
        }
        if CommandLine.arguments.contains("--debug-loginitem") {
            DebugSupport.dumpLoginItemStatusAndQuit()
        }
        if CommandLine.arguments.contains("--debug-ocr") {
            DebugSupport.runOCRCheckAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-encode-bitrate") {
            DebugSupport.measureEncodeBitrateAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-scheduled-record") {
            DebugSupport.checkScheduledRecordingAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-video-undo") {
            DebugSupport.checkVideoUndoAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-video-thumbnail") {
            DebugSupport.checkVideoThumbnailAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-open-video") {
            DebugSupport.checkOpenVideoAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-video-playback") {
            DebugSupport.checkVideoPlaybackAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-save-directory") {
            DebugSupport.checkSaveDirectoryAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-video-editor") {
            DebugSupport.dumpVideoEditorAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-video-export") {
            DebugSupport.exportVideoAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-record-resize") {
            DebugSupport.recordResizingWindowAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-record") {
            DebugSupport.recordFrontWindowAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-recording-statusbar") {
            DebugSupport.dumpRecordingStatusBarAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-recording-bar") {
            DebugSupport.dumpRecordingSetupBarAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-history-window") {
            DebugSupport.dumpHistoryWindowAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-apply-check") {
            DebugSupport.runApplyCheckAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-history") {
            DebugSupport.testHistoryPurgeAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-window-capture") {
            DebugSupport.dumpWindowCaptureAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-corner-probe") {
            DebugSupport.probeWindowCornerRadiusAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-rounded") {
            DebugSupport.dumpRoundedCornerSampleAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-capture-timing") {
            DebugSupport.measureCaptureTimingAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-overlay-frames") {
            DebugSupport.dumpOverlayFramesAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-windows") {
            DebugSupport.dumpWindowListAndQuit()
        }
        if DebugSupport.shouldShowThumbnail {
            DebugSupport.showThumbnailAndDump()
        }
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 終了

    /// 収録の予約を待っている間に終了しようとしたら確かめる。
    /// - Returns: 終了してよければ true。
    static func confirmQuitIfScheduled() -> Bool {
        guard RecordingCoordinator.shared.state == .scheduled, !hasConfirmedQuit else { return true }
        #if DEBUG
        if RecordingCoordinator.shared.isDebugSimulation { return true }
        #endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "収録の予約を取り消して終了しますか？"
        alert.informativeText = "Shotter を終了すると、予約した収録は行われません。"
        alert.addButton(withTitle: "終了する")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        hasConfirmedQuit = true
        return true
    }

    /// 収録中に終了しても動画を失わないよう、保存が済んでから終了する。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.confirmQuitIfScheduled() else { return .terminateCancel }

        let coordinator = RecordingCoordinator.shared
        guard coordinator.state == .recording || coordinator.state == .finishing else { return .terminateNow }

        Task { @MainActor in
            await coordinator.finishBeforeTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 終了時はウィンドウの「閉じる」が呼ばれないので、書き戻し待ちの編集内容をここで確定させる。
    func applicationWillTerminate(_ notification: Notification) {
        EditorWindowController.flushAllPendingEdits()
        VideoEditorWindowController.flushAllPendingEdits()
    }

    /// `open -a Shotter <path>` や Finder の「このアプリで開く」から渡された画像を注釈エディタで開く。
    /// BTT などから「ファイルへ保存 → このアプリで開く」を叩く連携を想定している。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openInEditor(fileAt: url)
        }
    }

    private func openInEditor(fileAt url: URL) {
        // 動画は動画エディタで開く。
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
            openVideoInEditor(fileAt: url)
            return
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            AlertPresenter.showError(FileOpenError.unreadableImage(url), title: "開けませんでした")
            return
        }

        // 通常の撮影と同じく、注釈を付ける前の状態を履歴に残す。
        let historyURL = HistoryStore.shared.save(image)

        // ウィンドウが実際に開く画面のスケールに合わせないと、キャンバスが引き伸ばされてぼやける。
        let scale = EditorWindowController.screenUnderMouse()?.backingScaleFactor ?? 2
        EditorWindowController.present(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            historyURL: historyURL
        )
    }

    /// 画像と同じく履歴へ取り込んでから開く。大きな動画はコピーに時間がかかるので、その間は知らせておく。
    private func openVideoInEditor(fileAt url: URL) {
        HUDPresenter.show("動画を読み込んでいます…", symbolName: "film", duration: 1.6)
        Task { @MainActor in
            do {
                let editableURL = try await HistoryStore.shared.importVideo(at: url)
                VideoEditorWindowController.present(url: editableURL)
            } catch {
                AlertPresenter.showError(error, title: "\(url.lastPathComponent) を開けませんでした")
            }
        }
    }
}

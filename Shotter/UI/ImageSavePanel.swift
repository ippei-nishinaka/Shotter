import AppKit
import UniformTypeIdentifiers

/// 保存ダイアログ。形式（PNG / JPEG）を切り替えられるアクセサリビューを付ける。
@MainActor
final class ImageSavePanel: NSObject {

    /// パネル表示中に解放されないよう自身を保持する。
    private static var active: ImageSavePanel?

    private let panel = NSSavePanel()
    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider()
    private let qualityLabel = NSTextField(labelWithString: "")

    private var format: ImageFormat = Preferences.imageFormat

    static func present(
        image: CGImage,
        in window: NSWindow?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let controller = ImageSavePanel()
        active = controller
        controller.run(image: image, in: window) { result in
            active = nil
            completion(result)
        }
    }

    private func run(
        image: CGImage,
        in window: NSWindow?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        configurePanel()

        let handler: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { return }

            Preferences.imageFormat = format
            Preferences.jpegQuality = CGFloat(qualitySlider.doubleValue)
            Preferences.lastSaveDirectory = url.deletingLastPathComponent()

            guard let data = ImageExporter.data(
                from: image,
                format: format,
                jpegQuality: CGFloat(qualitySlider.doubleValue)
            ) else {
                completion(.failure(ImageExportError.encodingFailed))
                return
            }

            do {
                try data.write(to: url, options: .atomic)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handler(panel.runModal())
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ImageExporter.defaultFileName()
        panel.directoryURL = Preferences.lastSaveDirectory
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [format.contentType]
        panel.accessoryView = makeAccessoryView()
        updateQualityControls()
    }

    private func makeAccessoryView() -> NSView {
        formatPopUp.addItems(withTitles: ImageFormat.allCases.map(\.title))
        formatPopUp.selectItem(at: ImageFormat.allCases.firstIndex(of: format) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)

        qualitySlider.minValue = 0.3
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = Double(Preferences.jpegQuality)
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        qualityLabel.font = .systemFont(ofSize: 11)
        qualityLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "形式:"),
            formatPopUp,
            NSTextField(labelWithString: "画質:"),
            qualitySlider,
            qualityLabel,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        return stack
    }

    @objc private func formatChanged() {
        let index = formatPopUp.indexOfSelectedItem
        guard ImageFormat.allCases.indices.contains(index) else { return }
        format = ImageFormat.allCases[index]

        panel.allowedContentTypes = [format.contentType]
        updateQualityControls()
    }

    @objc private func qualityChanged() {
        updateQualityControls()
    }

    /// JPEG のときだけ画質スライダーを有効にする。
    private func updateQualityControls() {
        let isJPEG = format == .jpeg
        qualitySlider.isEnabled = isJPEG
        qualityLabel.stringValue = isJPEG ? "\(Int(qualitySlider.doubleValue * 100))%" : "—"
    }
}

import AppKit
import SwiftUI

/// アプリの情報。バージョン・ライセンス・リポジトリの URL を出す。
enum AppInfo {

    static let repositoryURL = URL(string: "https://github.com/ippei-nishinaka/Shotter")!

    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shotter"
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    static let licenseName = "MIT License"

    static let licenseText = """
    MIT License

    Copyright (c) 2026 Ippei Nishinaka

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}

struct AboutView: View {

    @State private var didCopyURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            repositoryRow
            Divider()
            licenseSection
        }
        .padding(20)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name)
                    .font(.title2.bold())
                Text("バージョン \(AppInfo.version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("外部パッケージに依存しない、macOS 用のスクリーンショット注釈アプリ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var repositoryRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("リポジトリ")
                .font(.headline)

            HStack(spacing: 8) {
                Link(AppInfo.repositoryURL.absoluteString, destination: AppInfo.repositoryURL)
                    .font(.system(size: 12, design: .monospaced))

                Button(didCopyURL ? "コピーしました" : "URL をコピー") {
                    Pasteboard.copy(text: AppInfo.repositoryURL.absoluteString)
                    didCopyURL = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ライセンス — \(AppInfo.licenseName)")
                .font(.headline)

            ScrollView {
                Text(AppInfo.licenseText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: AboutWindowController?

    static func show() {
        if let existing = shared {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = AboutWindowController()
        shared = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter について"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingView(rootView: AboutView())
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

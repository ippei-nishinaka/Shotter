import AppKit

@main
enum ShotterMain {

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // .accessory: Dock アイコンを出さない常駐アプリ。Info.plist の LSUIElement と併用。
        app.setActivationPolicy(.accessory)

        // delegate は NSApplication に weak 参照されるため、run() の間だけ明示的に保持する。
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

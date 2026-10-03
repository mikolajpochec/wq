import AppKit

let application = NSApplication.shared

// Offscreen pictures are drawn by a one-off process, never the running app, which would stall
// for as long as they take: WindowQueue --render readme|tour|settings <dir>
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render"), arguments.count > flag + 2 {
    application.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: arguments[flag + 2])
    switch arguments[flag + 1] {
    case "readme": ReadmeRenderer.render(to: directory)
    case "tour": TourWindowController.render(store: PreferencesStore(), to: directory)
    case "settings": SettingsWindowController.render(store: PreferencesStore(), to: directory)
    default:
        FileHandle.standardError.write(Data("unknown render: \(arguments[flag + 1])\n".utf8))
        exit(1)
    }
    exit(0)
}

let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()

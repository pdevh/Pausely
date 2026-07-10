import AppKit

let apps = NSWorkspace.shared.runningApplications
for app in apps {
    if app != NSRunningApplication.current && app.activationPolicy == .regular {
        app.hide()
    }
}

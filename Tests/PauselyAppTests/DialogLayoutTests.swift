import AppKit
import SwiftUI
import XCTest
@testable import Pausely

final class DialogLayoutTests: XCTestCase {
    @MainActor
    func testNativeDialogsFitAndRender() async throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try snapshot(CustomDurationView(title: "Custom Work Interval",
                explanation: "Time to focus between breaks.", seconds: 37,
                onSave: { _ in }, onCancel: {}), name: "custom-37-\(appearance.rawValue)", appearance: appearance)
            try snapshot(CustomDurationView(title: "Custom Break Duration",
                explanation: "Time to rest during each break.", seconds: 86400,
                onSave: { _ in }, onCancel: {}), name: "custom-24h-\(appearance.rawValue)", appearance: appearance)
            try snapshot(JoinSessionView(), name: "join-\(appearance.rawValue)", appearance: appearance)
            try snapshot(HostSessionView(code: "AAAAABBBBBB"), name: "host-custom-\(appearance.rawValue)", appearance: appearance)
        }
    }

    @MainActor
    private func snapshot<V: View>(_ view: V, name: String, appearance: NSAppearance.Name) throws {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        XCTAssertLessThanOrEqual(size.width, 520, name)
        XCTAssertLessThanOrEqual(size.height, 650, name)
        XCTAssertGreaterThan(size.height, 200, name)
        if let directory = ProcessInfo.processInfo.environment["PAUSELY_UI_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}

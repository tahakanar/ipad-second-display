import AppKit
import SwiftUI

@main
struct MacDisplayApp: App {
    @State private var controller = HostController()

    var body: some Scene {
        Window("İkinci Ekran", id: "display") {
            HostView(controller: controller)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    controller.stop()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
                    controller.stop()
                }
                .onDisappear { controller.stop() }
        }
        .windowResizability(.contentSize)
    }
}

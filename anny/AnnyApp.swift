import SwiftUI

@main
struct AnnyApp: App {
    @StateObject private var store = HostStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 740)
    }
}

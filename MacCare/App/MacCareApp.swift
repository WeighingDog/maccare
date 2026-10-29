import SwiftUI

@main
struct MacCareApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacCare", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 600)
                #if DEBUG
                .task { DebugAutomation.runIfRequested(model: model) }
                #endif
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Avvia scansione") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning || model.isCleaning)
                Button("Interrompi scansione") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isScanning)
            }
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

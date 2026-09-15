import SwiftUI
import CodexAccountSwitchCore

@main
struct CodexAccountSwitchApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: state.menuBarSymbol)
                if !state.menuBarTitle.isEmpty {
                    Text(state.menuBarTitle).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

import SwiftUI
import CodexAccountSwitchCore

@main
struct CodexAccountSwitchApp: App {
    @State private var state = AppState()

    init() {
        // 开发用：CAS_OPEN=window 启动即打开详情窗口，CAS_OPEN=overview 打开并定位到"全部账号"总览页；
        // CAS_OPEN=menu 用普通窗口预览菜单面板（菜单栏弹窗无法脚本化打开）。
        guard let mode = ProcessInfo.processInfo.environment["CAS_OPEN"] else { return }
        let state = self.state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch mode {
            case "window": MainWindowController.shared.show(state: state, selecting: nil)
            case "overview": MainWindowController.shared.show(state: state, selecting: AppState.overviewSelectionId)
            case "menu": MainWindowController.shared.showMenuPreview(state: state)
            default: break
            }
        }
    }

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

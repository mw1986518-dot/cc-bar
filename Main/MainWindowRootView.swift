import SwiftUI

enum MainTab: Hashable {
    case stats
    case settings
}

struct MainWindowRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bindable = appState
        TabView(selection: $bindable.mainTab) {
            StatsView()
                .tabItem { Label(tr("Statistics", "用量统计"), systemImage: "chart.bar") }
                .tag(MainTab.stats)

            SettingsRootView()
                .tabItem { Label(tr("Settings", "设置"), systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .frame(minWidth: 1040, minHeight: 520)
        .background(InitialFirstResponderClearer())
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// 主窗口打开时，系统会把第一个可聚焦控件（顶部 TabView 的 tab 条）设为第一响应者，
/// 开启「键盘导航」时 tab 外会多一圈蓝色焦点环。窗口首次成为 key 后清掉这个初始焦点；
/// 之后按 Tab 键导航、点击输入框时焦点环照常出现。
private struct InitialFirstResponderClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClearerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            if window.isKeyWindow {
                clear(window)
            } else {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        self?.removeObserver()
                        if let window { self?.clear(window) }
                    }
                }
            }
        }

        /// 推迟一拍，等 AppKit / SwiftUI 设完初始焦点再清。
        private func clear(_ window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                window?.makeFirstResponder(nil)
            }
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

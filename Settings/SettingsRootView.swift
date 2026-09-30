import SwiftUI

// MARK: - SettingsCategory

enum SettingsCategory: String, CaseIterable, Identifiable {
    case services
    case appearance
    case data
    case general

    var id: String { rawValue }

    var englishTitle: String {
        switch self {
        case .services: return "Services & Accounts"
        case .appearance: return "Appearance & Display"
        case .data: return "Data & Refresh"
        case .general: return "General"
        }
    }

    var chineseTitle: String {
        switch self {
        case .services: return "服务与账号"
        case .appearance: return "外观与显示"
        case .data: return "数据与刷新"
        case .general: return "通用"
        }
    }

    var icon: String {
        switch self {
        case .services: return "server.rack"
        case .appearance: return "macwindow"
        case .data: return "arrow.triangle.2.circlepath"
        case .general: return "gearshape"
        }
    }
}

// MARK: - SettingsRootView

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedCategory: SettingsCategory = .services
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginMessageIsError = false
    @State private var isRecalculatingUsage = false
    @State private var pricingCatalogMessage: String?
    @State private var pricingCatalogMessageIsError = false
    @State private var showCodexResetCreditsSheet = false
    @State private var showCommandCodeSheet = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var diagnosticsMessageIsError = false
    @State private var showDiagnosticsConfirm = false

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        HStack(spacing: 0) {
            sidebar
            // 与侧栏材质一起延伸进标题栏，侧栏右边界从上到下是同一条线。
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            contentArea(settings: settings)
        }
        .sheet(isPresented: $showCommandCodeSheet) {
            CommandCodeCredentialSheet()
        }
        .confirmationDialog(
            tr("Export diagnostics?", "导出诊断日志？"),
            isPresented: $showDiagnosticsConfirm,
            titleVisibility: .visible
        ) {
            Button(tr("Export", "导出")) { exportDiagnostics() }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(diagnosticsDisclosure)
        }
        .sheet(isPresented: $showCodexResetCreditsSheet) {
            CodexResetCreditsSheet(
                accountTitle: appState.codexAccount?.email ?? "Codex",
                privacyAccountKey: "primary:codex",
                fetchCredits: { await appState.fetchCodexResetCredits() }
            )
        }
        .onAppear {
            settings.syncLaunchAtLoginStatus()
            if settings.launchAtLoginRequiresApproval {
                launchAtLoginMessage = launchAtLoginApprovalMessage
                launchAtLoginMessageIsError = false
            } else {
                launchAtLoginMessage = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Preferences", chinese: "偏好设置") {
                ForEach(SettingsCategory.allCases) { category in
                    sidebarItem(category: category)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: MainWindowLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(
        title: String,
        chinese: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr(title, chinese).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            content()
        }
    }

    private func sidebarItem(category: SettingsCategory) -> some View {
        let active = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(active ? Color.white : Color.secondary)

                Text(tr(category.englishTitle, category.chineseTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: - Content Area

    private func contentArea(settings: SettingsStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch selectedCategory {
                case .services:
                    servicesSection(settings: settings)
                case .appearance:
                    appearanceSection(settings: settings)
                case .data:
                    dataSection(settings: settings)
                case .general:
                    generalSection(settings: settings)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selectedCategory)
    }

    // MARK: - Section 1: Services & Accounts

    @ViewBuilder
    private func servicesSection(settings: SettingsStore) -> some View {
        // 已接入服务矩阵：每个服务一行，列为状态 / 启用 / 菜单栏 / 悬浮窗 / 用量统计 / 专属操作
        PrefsGroup(
            title: "Connected Services",
            chinese: "已接入服务",
            desc: "Configure quota monitoring, menu bar, floating HUD, and usage stats per service.",
            chineseDesc: "按服务配置配额监控、菜单栏、悬浮窗与本地统计"
        ) {
            ServiceMatrixHeader()

            let providers = QuotaProviderDescriptor.allProviders
            ForEach(providers, id: \.id) { provider in
                let info = accountInfo(for: provider.app)
                let usageApp = provider.app.usageApp
                ServiceSettingsRow(
                    provider: provider,
                    email: info.email.map { PrivacyDisplay.isEnabled ? PrivacyDisplay.account("primary:\(provider.app.rawValue)") : $0 },
                    plan: info.plan,
                    availability: info.availability,
                    accessory: accessoryView(for: provider.app),
                    isEnabled: isProviderEnabledBinding(for: provider.app, settings: settings),
                    showInMenuBar: menuBarBinding(for: provider.app, settings: settings),
                    showInFloatingHUD: floatingBinding(for: provider.app, settings: settings),
                    floatingHUDGloballyEnabled: settings.floatingEnabled,
                    usageApp: usageApp,
                    isUsageVisible: usageApp.map { usageStatsBinding(for: $0, settings: settings) }
                )

                InsetDivider()
            }

            // 本地用量服务：Pi
            let piInfo = usageServiceInfo(for: .pi)
            ServiceSettingsRow(
                logoName: "pi",
                fallback: "P",
                tint: UsageApp.pi.tintColor,
                title: "Pi",
                vendor: "pi.dev",
                detailText: piInfo.detailText,
                availability: piInfo.availability,
                isEnabled: usageStatsBinding(for: .pi, settings: settings),
                supportsMenuBar: false,
                supportsFloatingHUD: false
            )

            InsetDivider()

            // 本地用量服务：OpenCode
            let opencodeInfo = usageServiceInfo(for: .opencode)
            ServiceSettingsRow(
                logoName: "opencode",
                fallback: "O",
                tint: UsageApp.opencode.tintColor,
                title: "OpenCode",
                vendor: "opencode.ai",
                detailText: opencodeInfo.detailText,
                availability: opencodeInfo.availability,
                isEnabled: usageStatsBinding(for: .opencode, settings: settings),
                supportsMenuBar: false,
                supportsFloatingHUD: false
            )

            InsetDivider()

            // 本地用量服务：DSH（只进主窗口普通统计与对话，不进菜单栏 / 悬浮窗 / Cycles）
            let dshInfo = usageServiceInfo(for: .dsh)
            ServiceSettingsRow(
                logoName: "dsh",
                fallback: "D",
                tint: UsageApp.dsh.tintColor,
                title: "DSH",
                vendor: "DeepSeek Harness",
                detailText: dshInfo.detailText,
                availability: dshInfo.availability,
                isEnabled: usageStatsBinding(for: .dsh, settings: settings),
                supportsMenuBar: false,
                supportsFloatingHUD: false
            )
        }

        // 其他 Codex 账号（手动导入）
        PrefsGroup(
            title: "Other Codex Accounts",
            chinese: "其他 Codex 账号",
            desc: "Paste auth.json to monitor additional Codex accounts (view only).",
            chineseDesc: "粘贴 auth.json 添加更多 Codex 账号额度，仅查看，不会切换 CLI 登录状态"
        ) {
            ImportedCodexAccountsView()
        }
    }

    // MARK: - Section 2: Appearance & Display

    @ViewBuilder
    private func appearanceSection(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Menu Bar",
            chinese: "菜单栏",
            desc: "Global menu bar preferences.",
            chineseDesc: "菜单栏全局偏好"
        ) {
            PrefsRow(
                label: "Quota period",
                chinese: "额度周期",
                desc: "Which window to display in the menu bar.",
                chineseDesc: "菜单栏显示哪个窗口"
            ) {
                Picker("", selection: Binding(get: { settings.menuBarWindow }, set: { settings.menuBarWindow = $0 })) {
                    Text(tr("Main", "主要")).tag(MenuBarWindowChoice.primary)
                    Text(tr("Weekly", "周额度")).tag(MenuBarWindowChoice.weekly)
                    Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }

        PrefsGroup(
            title: "Floating HUD",
            chinese: "桌面悬浮窗",
            desc: "A small always-on-top window pinned to your desktop.",
            chineseDesc: "桌面常驻的小悬浮窗"
        ) {
            PrefsRow(
                label: "Show floating window",
                chinese: "显示悬浮窗",
                desc: "Toggle global HUD visibility. Service rows can be configured in Services & Accounts.",
                chineseDesc: "控制桌面悬浮窗总开关。各服务具体行可在「服务与账号」中独立勾选"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.floatingEnabled },
                    set: { newValue in
                        settings.floatingEnabled = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }

        PrefsGroup(
            title: "Display Details",
            chinese: "显示细节"
        ) {
            PrefsRow(
                label: "Reset time",
                chinese: "重置时间",
                desc: "How quota reset time is shown in the popover.",
                chineseDesc: "弹出窗口中额度重置时间的显示方式"
            ) {
                Picker("", selection: Binding(
                    get: { settings.resetTimeDisplay },
                    set: { settings.resetTimeDisplay = $0 }
                )) {
                    Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                    Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            InsetDivider()
            PrefsRow(
                label: "Service status dot",
                chinese: "服务状态圆点",
                desc: "Show OpenAI / Anthropic status next to each service in the popover.",
                chineseDesc: "在弹出窗口为每个服务显示官方状态页圆点"
            ) {
                Toggle("", isOn: Binding(get: { settings.showServiceStatus }, set: { settings.showServiceStatus = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            InsetDivider()
            PrefsRow(
                label: "Privacy mode",
                chinese: "隐私模式",
                desc: "Hide sensitive account, project, and conversation information while keeping usage stats visible, so you can share screenshots.",
                chineseDesc: "开启隐私模式，隐藏账号、项目及对话等敏感信息，保留用量统计，方便您截图分享。"
            ) {
                Toggle("", isOn: Binding(get: { settings.privacyMode }, set: { settings.privacyMode = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
        }
    }

    // MARK: - Section 3: Data & Refresh

    @ViewBuilder
    private func dataSection(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Polling Intervals",
            chinese: "后台刷新",
            desc: "How often the app polls usage and logs in the background.",
            chineseDesc: "后台轮询额度与日志的频率"
        ) {
            PrefsRow(label: "Quota refresh", chinese: "额度刷新") {
                Picker("", selection: Binding(
                    get: { settings.quotaInterval },
                    set: { newValue in
                        settings.quotaInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(QuotaIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            InsetDivider()
            PrefsRow(label: "Log scan", chinese: "日志扫描") {
                Picker("", selection: Binding(
                    get: { settings.usageInterval },
                    set: { newValue in
                        settings.usageInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(UsageIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            InsetDivider()
            PrefsRow(label: "Last refresh", chinese: "上次刷新") {
                HStack(spacing: 6) {
                    if appState.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Text(lastRefreshText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }

        PrefsGroup(
            title: "Data Maintenance",
            chinese: "数据维护",
            desc: "Model pricing catalogs and historical usage calculation.",
            chineseDesc: "模型价格目录与历史用量计算"
        ) {
            PrefsRow(
                label: "Price catalog",
                chinese: "价格目录",
                desc: "Fetch the latest Standard and Fast pricing. Applies to new records only; use Recalculate to reprice history.",
                chineseDesc: "获取最新的 Standard 与 Fast 模型价格；只对新记录生效，历史费用需用「重新计算」对齐"
            ) {
                HStack(spacing: 8) {
                    if let pricingCatalogMessage {
                        Text(pricingCatalogMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(pricingCatalogMessageIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        pricingCatalogMessage = nil
                        Task {
                            let succeeded = await appState.usageService.refreshPricingCatalog()
                            pricingCatalogMessageIsError = !succeeded
                            pricingCatalogMessage = succeeded
                                ? tr("Updated", "已更新")
                                : tr("Update failed", "更新失败")
                        }
                    } label: {
                        if appState.usageService.isRefreshingPricingCatalog {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Update", "更新"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.usageService.isRefreshingPricingCatalog)
                }
            }
            InsetDivider()
            PrefsRow(
                label: "Recalculate usage",
                chinese: "重新计算用量",
                desc: "Rescan all local logs, fill in missing prices, and recompute every cost with the current pricing table.",
                chineseDesc: "重新扫描全部本地日志，补齐缺价并按当前定价表重算所有费用",
                detail: recalculateOutcomeDetail
            ) {
                HStack(spacing: 8) {
                    if appState.usageService.cycleUsageNeedsManualRecalculation, !isRecalculatingUsage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(tr("Cycle usage incomplete", "周期用量不完整"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help(tr(
                            "Some historical cycle usage could not be restored from cache. Recalculate to fill it in.",
                            "部分历史周期的用量无法从缓存恢复，点「重新计算」补齐"
                        ))
                    }
                    if let progress = appState.usageService.scanProgress, isRecalculatingUsage {
                        Text(scanProgressText(progress))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Button {
                        isRecalculatingUsage = true
                        Task {
                            await appState.usageService.forceRescan()
                            isRecalculatingUsage = false
                        }
                    } label: {
                        if isRecalculatingUsage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Recalculate", "重新计算"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRecalculatingUsage)
                }
            }
        }
    }

    // MARK: - Section 4: General

    @ViewBuilder
    private func generalSection(settings: SettingsStore) -> some View {
        PrefsGroup(title: "System", chinese: "系统") {
            PrefsRow(label: "Language", chinese: "语言") {
                Picker("", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            InsetDivider()
            PrefsRow(label: "Launch at login", chinese: "开机自动启动", detail: launchAtLoginDetail) {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try settings.setLaunchAtLogin(newValue)
                            if settings.launchAtLoginRequiresApproval {
                                launchAtLoginMessage = launchAtLoginApprovalMessage
                                launchAtLoginMessageIsError = false
                            } else {
                                launchAtLoginMessage = nil
                            }
                        } catch {
                            settings.syncLaunchAtLoginStatus()
                            launchAtLoginMessage = launchAtLoginErrorMessage(error)
                            launchAtLoginMessageIsError = true
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }

        PrefsGroup(title: "Diagnostics", chinese: "诊断") {
            PrefsRow(
                label: "Export diagnostics",
                chinese: "导出诊断日志",
                desc: "Package redacted logs and app state into a zip you can send to the developer.",
                chineseDesc: "把脱敏后的日志与运行状态打包成 zip，可直接发给开发者"
            ) {
                HStack(spacing: 8) {
                    if let diagnosticsMessage {
                        Text(diagnosticsMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(diagnosticsMessageIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing)
                    }
                    Button {
                        showDiagnosticsConfirm = true
                    } label: {
                        if isExportingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Export", "导出"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExportingDiagnostics)
                }
            }
            InsetDivider()
            PrefsRow(
                label: "Reveal log folder",
                chinese: "打开日志目录",
                desc: "Logs live in ~/Library/Logs/CCBar and are kept to about 8 MB.",
                chineseDesc: "日志存放在 ~/Library/Logs/CCBar，总量约 8 MB 上限"
            ) {
                Button(tr("Open", "打开")) {
                    DiagnosticsBundle.revealLogDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            InsetDivider()
            PrefsRow(
                label: "Verbose logging",
                chinese: "详细日志",
                desc: "Record extra detail for troubleshooting. Turn it off when you are done.",
                chineseDesc: "记录更详细的排查信息，排查完建议关闭"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.verboseLogging },
                    set: { settings.verboseLogging = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }

        PrefsGroup(title: "Updates & About", chinese: "更新与关于") {
            PrefsRow(label: "Version", chinese: "版本") {
                Text(appVersion)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            InsetDivider()
            PrefsRow(
                label: "Check for updates",
                chinese: "检查更新",
                desc: "Fetch the newest release info from GitHub.",
                chineseDesc: "从 GitHub 获取最新版本信息"
            ) {
                HStack(spacing: 8) {
                    if let updateStatusText {
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(updateStatusIsError ? Color.red : (updateStatusHasNewVersion ? Color.accentColor : Color.secondary))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        if updateStatusHasNewVersion {
                            appState.openReleasePage()
                        } else {
                            Task { await appState.checkForUpdates() }
                        }
                    } label: {
                        if isUpdateCheckInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(updateButtonTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUpdateCheckInProgress)
                }
            }
            InsetDivider()
            PrefsRow(label: "Check at launch", chinese: "启动时自动检查") {
                Toggle("", isOn: Binding(
                    get: { settings.autoCheckForUpdates },
                    set: { settings.autoCheckForUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }

        footer
    }

    // MARK: - Bindings & Actions Helpers

    private func isProviderEnabledBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderEnabled(app) },
            set: { newValue in
                switch app {
                case .codex:
                    settings.showCodex = newValue
                case .claude:
                    settings.showClaude = newValue
                case .antigravity:
                    settings.showAntigravity = newValue
                    if newValue {
                        Task { await appState.refreshQuotas(reason: .userInitiated) }
                    }
                case .cursor:
                    setCursorProviderEnabled(newValue, settings: settings)
                case .commandCode:
                    setCommandCodeProviderEnabled(newValue, settings: settings)
                }
            }
        )
    }

    private func menuBarBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInMenuBar(app) },
            set: { settings.setProviderShownInMenuBar($0, for: app) }
        )
    }

    private func floatingBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInFloatingHUD(app) },
            set: { newValue in
                settings.setProviderShownInFloatingHUD(newValue, for: app)
                FloatingPanelController.shared.sync()
            }
        )
    }

    private func usageStatsBinding(for usageApp: UsageApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isUsageServiceVisible(usageApp) },
            set: { visible in
                settings.setUsageServiceVisible(visible, for: usageApp)
                if usageApp == .cursor, visible {
                    Task { await appState.refreshQuotas(reason: .userInitiated) }
                }
            }
        )
    }

    private func setCursorProviderEnabled(_ enabled: Bool, settings: SettingsStore) {
        settings.setProviderEnabled(enabled, for: .cursor)
        guard enabled else { return }
        Task {
            await appState.refreshQuotas(reason: .userInitiated)
        }
    }

    private func setCommandCodeProviderEnabled(_ enabled: Bool, settings: SettingsStore) {
        settings.setProviderEnabled(enabled, for: .commandCode)
        guard enabled else { return }
        Task {
            await appState.refreshQuotas(reason: .userInitiated)
        }
    }

    private func accountInfo(for app: QuotaApp) -> (email: String?, plan: String?, availability: AccountAvailability) {
        switch app {
        case .codex:
            return (
                email: appState.codexAccount?.email,
                plan: appState.codexAccount?.planType?.capitalized,
                availability: appState.codexAccount == nil ? .notDetected : .connected
            )
        case .claude:
            return (
                email: appState.claudeAccount?.email,
                plan: appState.claudeAccount?.subscriptionType?.capitalized,
                availability: appState.claudeAccount == nil ? .notDetected : .connected
            )
        case .antigravity:
            return (
                email: appState.antigravityAccount?.email,
                plan: (appState.antigravityAccount?.planType ?? appState.antigravityQuota?.planType)?.capitalized,
                availability: appState.antigravityAccount == nil ? .notDetected : .connected
            )
        case .cursor:
            return (
                email: appState.cursorAccount?.email,
                plan: appState.cursorQuota?.planType,
                availability: appState.cursorAccount == nil ? .notDetected : .connected
            )
        case .commandCode:
            return (
                email: appState.commandCodeAccount?.email ?? appState.commandCodeAccount?.login,
                plan: appState.commandCodeQuota?.planType ?? appState.commandCodeAccount?.planType,
                availability: appState.commandCodeAccount == nil ? .notDetected : .connected
            )
        }
    }

    private func usageServiceInfo(for app: UsageApp) -> (detailText: String, availability: AccountAvailability) {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        switch app {
        case .pi:
            let sessionsDir = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            let configDir = home.appendingPathComponent(".pi", isDirectory: true)
            let detected = fileManager.fileExists(atPath: sessionsDir.path) || fileManager.fileExists(atPath: configDir.path)
            return (
                detailText: detected
                    ? tr("Local logs detected (~/.pi)", "已检测到本地日志 (~/.pi)")
                    : tr("No logs detected (~/.pi)", "未检测到本地日志 (~/.pi)"),
                availability: detected ? .connected : .notDetected
            )
        case .opencode:
            let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
            let configDir = home.appendingPathComponent(".config/opencode", isDirectory: true)
            let shareDir = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
            let detected = fileManager.fileExists(atPath: dbURL.path)
                || fileManager.fileExists(atPath: configDir.path)
                || fileManager.fileExists(atPath: shareDir.path)
            return (
                detailText: detected
                    ? tr("Local database detected (~/.local/share/opencode)", "已检测到本地数据库 (~/.local/share/opencode)")
                    : tr("No database detected (~/.local/share/opencode)", "未检测到本地数据库 (~/.local/share/opencode)"),
                availability: detected ? .connected : .notDetected
            )
        case .dsh:
            // 只探测默认根：不做 Desktop 自定义数据目录、显式 DSH_HOME、Beta home 的自动发现（§1）。
            // 没有默认日志不能据此断定用户未安装 DSH。
            let sessionsDir = home.appendingPathComponent(".dsh/sessions", isDirectory: true)
            let homeDir = home.appendingPathComponent(".dsh", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: sessionsDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return (
                    detailText: tr("Session directory detected (~/.dsh/sessions)", "已检测到会话目录 (~/.dsh/sessions)"),
                    availability: .connected
                )
            }
            if fileManager.fileExists(atPath: homeDir.path) {
                return (
                    detailText: tr("DSH data directory detected; no default session directory", "已检测到 DSH 数据目录，未发现默认会话目录"),
                    availability: .notDetected
                )
            }
            return (
                detailText: tr("No session directory detected (~/.dsh/sessions)", "未检测到会话目录 (~/.dsh/sessions)"),
                availability: .notDetected
            )
        default:
            return (detailText: "", availability: .connected)
        }
    }

    private func accessoryView(for app: QuotaApp) -> AnyView? {
        switch app {
        case .codex:
            return appState.codexAccount != nil ? AnyView(codexResetCreditsButton) : nil
        case .commandCode:
            return AnyView(commandCodeCredentialButton)
        default:
            return nil
        }
    }

    private var commandCodeCredentialButton: some View {
        Button {
            showCommandCodeSheet = true
        } label: {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(tr("Command Code credentials", "Command Code 凭据设置"))
    }

    private var codexResetCreditsButton: some View {
        Button {
            showCodexResetCreditsSheet = true
        } label: {
            Image(systemName: "gift")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(tr("Reset credits", "使用限额重置"))
    }

    /// 手动重算的结果提示。成功不提示（费用已在统计页可见）；被拒 / 失败必须说明
    /// 「原历史保留」与下一步，和技术实现里的拒绝阈值一致。
    private func rebuildOutcomeHint(_ outcome: UsageRebuildOutcome?) -> String? {
        switch outcome {
        case .rejectedUsageChanged:
            return tr(
                "Rebuild not applied: logs changed, previous history kept",
                "重算未生效：日志已变化，保留原历史"
            )
        case .rejectedIncompleteSources:
            return tr(
                "Rebuild not applied: some logs unreadable",
                "重算未生效：部分日志读取不完整"
            )
        case .commitFailed:
            return tr(
                "Rebuild could not be saved; previous history kept",
                "重算保存失败：原历史未改动"
            )
        case .partiallyCommitted:
            return tr(
                "Partly applied: price refresh was not saved",
                "部分生效：缺价刷新那一轮未保存"
            )
        case .restrictedRecoveryRejected:
            return tr(
                "Verification failed: history preserved, collection paused. Restore logs or resolve read/write errors before retrying.",
                "核对失败：历史已保留，采集暂停。恢复日志或解决读写故障后再重试。"
            )
        case .replaced(cycleVerified: false):
            return tr(
                "Costs updated; cycle attribution differs and could not be verified",
                "费用已更新；周期归属存在差异，完整性未确认"
            )
        case .replaced(cycleVerified: true), .recoveredFromRestrictedHistory, .none:
            return nil
        }
    }

    private func scanProgressText(_ progress: ScanProgress) -> String {
        let appName: String
        switch progress.app {
        case .codex: appName = "Codex"
        case .claude: appName = "Claude Code"
        case .cursor: appName = "Cursor"
        case .pi: appName = "Pi"
        case .opencode: appName = "OpenCode"
        case .dsh: appName = "DSH"
        }
        if progress.filesTotal > 0 {
            return tr(
                "Scanning \(appName): \(progress.filesCompleted)/\(progress.filesTotal) files",
                "正在扫描 \(appName)：\(progress.filesCompleted)/\(progress.filesTotal) 个文件"
            )
        }
        return tr(
            "Scanning \(appName): \(progress.linesParsed) items",
            "正在扫描 \(appName)：已处理 \(progress.linesParsed) 条"
        )
    }

    // MARK: Diagnostics helpers

    /// 导出前必须把"包含什么 / 不包含什么"说清楚。用户对"把日志发给开发者"的顾虑
    /// 只能靠明确告知消解，不能靠一句"已脱敏"带过。
    private var diagnosticsDisclosure: String {
        tr(
            """
            The zip contains the app version, macOS version, your settings, each service's \
            status and last error, and local log scan statistics.

            It does not contain sign-in tokens, plain-text email addresses, conversation \
            content, file contents, or project names. Nothing is uploaded — the file is \
            saved locally and it is up to you whether to send it.
            """,
            """
            压缩包内含：App 版本、macOS 版本、你的设置项、各服务的状态与最后一次错误、\
            本地日志扫描统计。

            不含：登录令牌、明文邮箱、对话内容、文件内容、项目名。App 不会上传任何内容，\
            文件只保存在本机，发不发由你决定。
            """
        )
    }

    private func exportDiagnostics() {
        isExportingDiagnostics = true
        diagnosticsMessage = nil
        diagnosticsMessageIsError = false
        Task {
            do {
                let url = try await DiagnosticsBundle.export(appState: appState)
                DiagnosticsBundle.revealInFinder(url)
                diagnosticsMessage = tr("Revealed in Finder", "已在 Finder 中显示")
            } catch {
                diagnosticsMessage = tr("Export failed", "导出失败")
                diagnosticsMessageIsError = true
                AppLog.error(.app, "diagnostics export failed: \(Redact.error(error))")
            }
            isExportingDiagnostics = false
        }
    }

    // MARK: Update check helpers

    private var isUpdateCheckInProgress: Bool {
        appState.updateStatus == .checking
    }

    private var updateStatusHasNewVersion: Bool {
        if case .updateAvailable = appState.updateStatus { return true }
        return false
    }

    private var updateStatusIsError: Bool {
        appState.updateStatus == .failed || appState.updateStatus == .rateLimited
    }

    private var updateStatusText: String? {
        switch appState.updateStatus {
        case .idle, .checking:
            return nil
        case .upToDate(let latest):
            return tr("Up to date (\(latest))", "已是最新（\(latest)）")
        case .updateAvailable(let version):
            return tr("Version \(version) is available", "发现新版本 \(version)")
        case .failed:
            return tr("Check failed", "检查失败")
        case .rateLimited:
            return tr("GitHub rate limit reached, try again later", "GitHub 暂时限流，请稍后再试")
        }
    }

    private var updateButtonTitle: String {
        updateStatusHasNewVersion
            ? tr("Download", "前往下载")
            : tr("Check", "检查")
    }

    private var launchAtLoginApprovalMessage: String {
        tr(
            "Approve CCBar in System Settings > General > Login Items & Extensions.",
            "请在「系统设置 > 通用 > 登录项与扩展」中允许 CCBar。"
        )
    }

    private func launchAtLoginErrorMessage(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
        if description.localizedCaseInsensitiveContains("operation not permitted") {
            return tr(
                "macOS rejected this change. Export a signed CCBar.app, move it to /Applications, launch it there, then try again.",
                "macOS 拒绝了这次更改。请导出签名后的 CCBar.app，拖到 /Applications 后从那里启动，再重试。"
            )
        }
        return description
    }

    /// 「重新计算用量」上一次的核对结果提示，放在描述下方，长文案换行显示。
    private var recalculateOutcomeDetail: AnyView? {
        guard !isRecalculatingUsage,
              let hint = rebuildOutcomeHint(appState.usageService.lastRebuildOutcome)
        else { return nil }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text(hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.top, 2)
            .help(PrivacyDisplay.help(appState.usageService.lastRebuildDiagnostic ?? ""))
        )
    }

    /// 开机启动的状态 / 错误说明，作为「开机自动启动」的描述行。
    private var launchAtLoginDetail: AnyView? {
        guard let launchAtLoginMessage else { return nil }
        return AnyView(
            Text(launchAtLoginMessageIsError ? PrivacyDisplay.error(launchAtLoginMessage) : launchAtLoginMessage)
                .font(.system(size: 11))
                .foregroundStyle(launchAtLoginMessageIsError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // 版本号只在「版本」行显示，页脚不重复。
            Text(tr("CCBar · AI subscription quota & local usage stats",
                    "CCBar · AI 订阅服务额度查询与本地用量统计"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Helpers

    private var lastRefreshText: String {
        let latest = QuotaApp.allCases.compactMap {
            appState.refreshState(for: $0).lastSuccessAt
        }.max()
        guard let latest else { return "—" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(timeFormatter.string(from: latest)) · \(PopoverRootView.relativeAge(from: latest)) \(tr("ago", "前"))"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}

// MARK: - PrefsGroup

private struct PrefsGroup<Content: View>: View {
    let title: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // 13 semibold：不小于行标签（13 regular），组标题层级在行之上。
                Text(tr(title, chinese))
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.05)
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - PrefsRow

private struct PrefsRow<Trailing: View>: View {
    let label: String
    let chinese: String
    var leading: AnyView? = nil
    var desc: String? = nil
    var chineseDesc: String? = nil
    /// 描述下方的附加行（状态、错误提示等），可多行换行，不占右侧控件区。
    var detail: AnyView? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // 右侧控件与左侧文字块垂直居中：描述有两行或带附加行时，控件不再贴着首行基线。
        HStack(alignment: .center, spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(label, chinese))
                    .font(.system(size: 13))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if let detail {
                    detail
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}

// MARK: - InsetDivider

private struct InsetDivider: View {
    var leading: CGFloat = 16
    var trailing: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
    }
}

// MARK: - Service matrix

/// 「已接入服务」矩阵列宽。服务列占剩余宽度；主窗口最小宽 1040 时服务列仍有约 330pt。
private enum ServiceMatrixColumn {
    static let status: CGFloat = 96
    static let toggle: CGFloat = 64
    static let destination: CGFloat = 64
    static let usage: CGFloat = 72
    static let accessory: CGFloat = 40
}

private struct ServiceMatrixHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(tr("Service", "服务"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("Status", "状态"))
                .frame(width: ServiceMatrixColumn.status, alignment: .leading)
            centered(tr("Enabled", "启用"), width: ServiceMatrixColumn.toggle)
            centered(tr("Menu Bar", "菜单栏"), width: ServiceMatrixColumn.destination)
            centered(tr("Floating HUD", "悬浮窗"), width: ServiceMatrixColumn.destination)
            centered(tr("Usage Stats", "用量统计"), width: ServiceMatrixColumn.usage)
            Color.clear
                .frame(width: ServiceMatrixColumn.accessory, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    /// 英文列头（如 Floating HUD）可能略宽于列，按自然宽度居中，允许轻微越出列边界。
    private func centered(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width)
    }
}

private struct ServiceSettingsRow: View {
    let logoName: String
    let fallback: String
    let tint: Color
    let title: String
    let vendor: String
    let detailText: String
    let availability: AccountAvailability
    let accessory: AnyView?
    @Binding var isEnabled: Bool
    @Binding var showInMenuBar: Bool
    var supportsMenuBar: Bool = true
    @Binding var showInFloatingHUD: Bool
    var supportsFloatingHUD: Bool = true
    var floatingHUDGloballyEnabled: Bool
    var isUsageVisible: Binding<Bool>?

    init(
        provider: QuotaProviderDescriptor,
        email: String?,
        plan: String?,
        availability: AccountAvailability,
        accessory: AnyView?,
        isEnabled: Binding<Bool>,
        showInMenuBar: Binding<Bool>,
        showInFloatingHUD: Binding<Bool>,
        floatingHUDGloballyEnabled: Bool,
        usageApp: UsageApp?,
        isUsageVisible: Binding<Bool>?
    ) {
        self.logoName = provider.logoName
        self.fallback = provider.fallback
        self.tint = provider.app.tintColor
        self.title = provider.title
        self.vendor = provider.vendor
        self.availability = availability
        self.accessory = accessory
        self._isEnabled = isEnabled
        self._showInMenuBar = showInMenuBar
        self.supportsMenuBar = provider.supportsMenuBar
        self._showInFloatingHUD = showInFloatingHUD
        self.supportsFloatingHUD = provider.supportsFloatingHUD
        self.floatingHUDGloballyEnabled = floatingHUDGloballyEnabled
        self.isUsageVisible = isUsageVisible

        if let email {
            if let plan, !plan.isEmpty {
                self.detailText = "\(email) · \(plan)"
            } else {
                self.detailText = email
            }
        } else {
            switch availability {
            case .connected: self.detailText = plan ?? tr("Connected", "已连接")
            case .notDetected: self.detailText = tr("Not detected", "未检测到")
            }
        }
    }

    init(
        logoName: String,
        fallback: String,
        tint: Color,
        title: String,
        vendor: String,
        detailText: String,
        availability: AccountAvailability,
        accessory: AnyView? = nil,
        isEnabled: Binding<Bool>,
        showInMenuBar: Binding<Bool> = .constant(false),
        supportsMenuBar: Bool = false,
        showInFloatingHUD: Binding<Bool> = .constant(false),
        supportsFloatingHUD: Bool = false,
        floatingHUDGloballyEnabled: Bool = false,
        isUsageVisible: Binding<Bool>? = nil
    ) {
        self.logoName = logoName
        self.fallback = fallback
        self.tint = tint
        self.title = title
        self.vendor = vendor
        self.detailText = detailText
        self.availability = availability
        self.accessory = accessory
        self._isEnabled = isEnabled
        self._showInMenuBar = showInMenuBar
        self.supportsMenuBar = supportsMenuBar
        self._showInFloatingHUD = showInFloatingHUD
        self.supportsFloatingHUD = supportsFloatingHUD
        self.floatingHUDGloballyEnabled = floatingHUDGloballyEnabled
        self.isUsageVisible = isUsageVisible
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ServiceTile(logoName: logoName, fallback: fallback, tint: tint)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("· \(vendor)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(detailText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            statusBadge
                .frame(width: ServiceMatrixColumn.status, alignment: .leading)

            // 小号开关：表格行更紧凑，接近设计稿 32×20，也不会撑满 64pt 列宽。
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .frame(width: ServiceMatrixColumn.toggle)

            // 展示位置三列：总开关关闭时整组置灰且不可点，不再隐藏，保持表格对齐。
            HStack(spacing: 0) {
                DisplayDestinationCheckbox(
                    title: "\(title) \(tr("Menu Bar", "菜单栏"))",
                    isOn: $showInMenuBar,
                    disabled: !isEnabled || !supportsMenuBar,
                    disabledHelp: supportsMenuBar ? nil : localUsageOnlyHelp
                )
                .frame(width: ServiceMatrixColumn.destination)

                DisplayDestinationCheckbox(
                    title: "\(title) \(tr("Floating HUD", "悬浮窗"))",
                    isOn: $showInFloatingHUD,
                    disabled: !isEnabled || !supportsFloatingHUD || !floatingHUDGloballyEnabled,
                    disabledHelp: floatingDisabledHelp
                )
                .frame(width: ServiceMatrixColumn.destination)

                Group {
                    if let isUsageVisible {
                        DisplayDestinationCheckbox(
                            title: "\(title) \(tr("Usage Stats", "用量统计"))",
                            isOn: isUsageVisible,
                            disabled: !isEnabled
                        )
                    } else {
                        // 不适用：无用量数据的服务，或本地用量服务（启用即用量统计）。
                        Text("—")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(tr("Not applicable", "不适用"))
                    }
                }
                .frame(width: ServiceMatrixColumn.usage)
            }
            .opacity(isEnabled ? 1 : 0.4)

            // 用固定宽的占位撑住操作列：没有专属操作的行也要占 40pt，否则整行各列右移、与列头错位。
            ZStack {
                Color.clear
                    .frame(width: ServiceMatrixColumn.accessory, height: 1)
                if let accessory { accessory }
            }
            .frame(width: ServiceMatrixColumn.accessory)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private var localUsageOnlyHelp: String {
        tr("Local usage only, no subscription quota", "仅支持本地用量，无订阅配额")
    }

    /// 悬浮窗列不可勾选的原因：不支持优先；总开关关闭时不提示；其余是全局悬浮窗未开启。
    private var floatingDisabledHelp: String? {
        if !supportsFloatingHUD { return localUsageOnlyHelp }
        if !isEnabled || floatingHUDGloballyEnabled { return nil }
        return tr("Enable Floating HUD in Appearance & Display first", "需先在「外观与显示」中开启桌面悬浮窗")
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(availability == .connected ? Color.green : (availability == .notDetected ? Color.orange : Color.secondary))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(availability == .connected ? Color.green : (availability == .notDetected ? Color.orange : Color.secondary))
        }
    }

    private var statusText: String {
        switch availability {
        case .connected: tr("Connected", "已连接")
        case .notDetected: tr("Not detected", "未检测到")
        }
    }
}

// MARK: - DisplayDestinationCheckbox

/// 矩阵单元格里的 13pt 复选框，没有文字标签（列头说明含义），`title` 只作无障碍标签。
/// 整个单元格可点，不只是 13pt 的框。
private struct DisplayDestinationCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var disabledHelp: String? = nil

    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        let button = Button {
            if disabled {
                if disabledHelp != nil {
                    showTooltip = true
                }
            } else {
                isOn.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(disabled ? 0.04 : 0.08) : Color.clear)

                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.8)

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.secondary)
                }
            }
            .frame(width: 13, height: 13)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? tr("On", "已开启") : tr("Off", "已关闭"))
        .onHover { hovering in
            guard disabled, let disabledHelp, !disabledHelp.isEmpty else { return }
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    showTooltip = true
                }
            } else {
                showTooltip = false
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
        }
        .popover(isPresented: $showTooltip, arrowEdge: .top) {
            if let disabledHelp, !disabledHelp.isEmpty {
                Text(disabledHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize()
            }
        }
        .help(disabled ? (disabledHelp ?? "") : "")

        if disabled {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    private var borderColor: Color {
        if disabled { return Color.primary.opacity(isOn ? 0.12 : 0.06) }
        return Color.primary.opacity(isOn ? 0.28 : 0.12)
    }
}

private enum AccountAvailability: Equatable {
    case connected
    case notDetected
}

// MARK: - Bilingual display names for existing enums

extension QuotaIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

extension UsageIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

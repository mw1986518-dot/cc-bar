import SwiftUI

struct MimoCredentialSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var cookieInput: String = ""
    @State private var hasStoredCookie: Bool = false
    @State private var isSaving: Bool = false
    @State private var showInvalidCookieHint: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text(tr("MiMo Token Plan Credentials", "MiMo Token Plan 凭据设置"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                Text(tr(
                    "The MiMo Token Plan quota is only available in the Xiaomi developer console and requires your browser sign-in Cookie (with serviceToken). It is stored in the macOS Keychain and only used to read your plan quota.",
                    "MiMo Token Plan 额度只在小米开放平台控制台提供，需要浏览器登录态 Cookie（需含 serviceToken）。Cookie 保存在 macOS 钥匙串中，仅用于查询套餐额度。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                Text(tr(
                    "How to get it: sign in at platform.xiaomimimo.com, open Developer Tools → Network, copy the Cookie header of any /api/v1 request.",
                    "获取方式：浏览器登录 platform.xiaomimimo.com，打开开发者工具 → Network，复制任意 /api/v1 请求的 Cookie 请求头。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    if hasStoredCookie {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 12))
                            Text(tr("Cookie saved in Keychain", "Keychain 中已保存 Cookie"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Remove", "清除")) {
                                MimoAuth.deleteFromKeychain()
                                hasStoredCookie = false
                                cookieInput = ""
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        }
                    }

                    SecureField(
                        hasStoredCookie ? tr("Paste a new Cookie to replace", "粘贴新的 Cookie 以替换") : tr("Paste Xiaomi account Cookie", "粘贴小米账号 Cookie"),
                        text: $cookieInput
                    )
                    .textFieldStyle(.roundedBorder)

                    if showInvalidCookieHint {
                        Text(tr("Cookie should contain serviceToken", "Cookie 中需要包含 serviceToken"))
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)

                Spacer(minLength: 0)

                // 底部按钮
                HStack {
                    Spacer()
                    Button(tr("Cancel", "取消")) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button {
                        saveAndDismiss()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Save", "保存并应用"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top, 10)
            }
            .padding(20)
        }
        .frame(width: 440, height: 360)
        .onAppear {
            hasStoredCookie = (MimoAuth.loadFromKeychain() != nil)
        }
    }

    private func saveAndDismiss() {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard MimoAuth.sanitizeCookie(trimmed) != nil, MimoAuth.looksLikeSessionCookie(trimmed) else {
                showInvalidCookieHint = true
                return
            }
            isSaving = true
            MimoAuth.saveToKeychain(cookie: trimmed)
            hasStoredCookie = true
        } else {
            isSaving = true
        }

        Task {
            await appState.loadMimo()
            if SettingsStore.shared.isProviderEnabled(.mimo) {
                await appState.refreshQuotas(reason: .userInitiated)
            }
            isSaving = false
            dismiss()
        }
    }
}

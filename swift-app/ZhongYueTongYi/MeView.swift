import SwiftUI
import UIKit

/// “我的”页：照参考图做——顶部封面横幅 + 分组白色圆角卡片 + 彩色图标。
struct MeView: View {
    @EnvironmentObject var auth: AuthViewModel
    @AppStorage("zy-ui-lang") private var uiLang = "zh"
    @AppStorage("zy-speak-lang") private var speakLang = "zh"
    @State private var showLogoutConfirm = false
    @State private var copied = false

    private var uiLangName: String { uiLang == "vi" ? "Tiếng Việt" : "简体中文" }
    private var speakLangName: String { speakLang == "vi" ? "Tiếng Việt" : "中文" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    coverHeader
                    VStack(spacing: 16) {
                        settingsCard {
                            SettingRow(icon: "person.fill", iconColor: .blue, title: "个人资料") {
                                ProfileDetailView()
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "qrcode", iconColor: .orange, title: "推荐好友") {
                                ReferFriendView()
                            }
                        }
                        settingsCard {
                            SettingRow(icon: "globe", iconColor: .purple, title: "界面语言", value: uiLangName) {
                                LanguagePickerView(kind: .ui)
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "mic.fill", iconColor: .green, title: "我说的语言", value: speakLangName) {
                                LanguagePickerView(kind: .speak)
                            }
                        }
                        settingsCard {
                            SettingRow(icon: "questionmark.circle.fill", iconColor: .blue, title: "使用帮助") {
                                HelpView()
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "shield.fill", iconColor: .gray, title: "隐私说明") {
                                PrivacyView()
                            }
                        }
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Text("退出登录")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                    .padding(16)
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarHidden(true)
            .confirmationDialog("退出登录", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await auth.signOut() }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }

    // MARK: - 封面横幅

    private var coverHeader: some View {
        ZStack {
            Image("AvatarImage")
                .resizable()
                .scaledToFill()
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        coverCircleLink(icon: "qrcode.viewfinder") { ReferFriendView() }
                        coverCircleLink(icon: "gearshape") { ProfileDetailView() }
                    }
                }
                Spacer()
                NavigationLink(destination: ProfileDetailView()) {
                    HStack(spacing: 14) {
                        Image("AvatarImage")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(auth.displayName)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                            HStack(spacing: 6) {
                                Text("ID: \(auth.friendNumber)")
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.85))
                                Button(action: copyFriendNumber) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .frame(height: 280)
    }

    private func coverCircleLink<Destination: View>(
        icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
    }

    private func copyFriendNumber() {
        UIPasteboard.general.string = auth.friendNumber
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    // MARK: - 卡片

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.white)
            .cornerRadius(16)
    }
}

/// 设置行：彩色圆角方块图标 + 文字 + 可选灰色值 + 右边灰色 ›。
struct SettingRow<Destination: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String?
    let destination: () -> Destination

    init(
        icon: String,
        iconColor: Color,
        title: String,
        value: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor)
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .foregroundColor(.white)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if let value {
                    Text(value)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

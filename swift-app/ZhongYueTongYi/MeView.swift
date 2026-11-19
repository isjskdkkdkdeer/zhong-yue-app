import SwiftUI
import UIKit

/// “我的”页：照参考图做——顶部封面横幅 + 分组白色圆角卡片 + 彩色图标。
///
/// 导航说明（第 2 步修）：原来用 inline NavigationLink 放在 ScrollView 里，
/// 封面那行还在 NavigationLink 里套了一个复制 Button，点按经常没反应。
/// 现在改成 NavigationStack(path:) + navigationDestination 的编程式导航，
/// 行就是普通 Button，点按直接往 path 里加目标，不再依赖 inline 链接的点击判定。
struct MeView: View {
    @EnvironmentObject var auth: AuthViewModel
    @AppStorage("zy-ui-lang") private var uiLang = "zh"
    @AppStorage("zy-speak-lang") private var speakLang = "zh"
    @State private var path: [MeDestination] = []
    @State private var showLogoutConfirm = false
    @State private var showCoverPicker = false
    @State private var copied = false

    private var uiLangName: String { uiLang == "vi" ? "Tiếng Việt" : "简体中文" }
    private var speakLangName: String { speakLang == "vi" ? "Tiếng Việt" : "中文" }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    coverHeader
                    VStack(spacing: 16) {
                        settingsCard {
                            // “个人资料”行已去掉：点封面头像就能进个人资料页，这行多余。
                            // 原来的位置改成“朋友圈”。
                            SettingRow(icon: "camera.fill", iconColor: .teal, title: "朋友圈") {
                                path.append(.moments)
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "qrcode", iconColor: .orange, title: "推荐好友") {
                                path.append(.refer)
                            }
                        }
                        settingsCard {
                            SettingRow(icon: "globe", iconColor: .purple, title: "界面语言", value: uiLangName) {
                                path.append(.uiLang)
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "mic.fill", iconColor: .green, title: "我说的语言", value: speakLangName) {
                                path.append(.speakLang)
                            }
                        }
                        settingsCard {
                            SettingRow(icon: "questionmark.circle.fill", iconColor: .blue, title: "使用帮助") {
                                path.append(.help)
                            }
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "shield.fill", iconColor: .gray, title: "隐私说明") {
                                path.append(.privacy)
                            }
                        }
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Text("退出登录")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                    }
                    .padding(16)
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MeDestination.self) { destination in
                switch destination {
                case .profile: ProfileDetailView(path: $path)
                case .profileSub(let page): ProfileDetailView.subPageView(for: page)
                case .moments: MomentsView()
                case .refer: ReferFriendView()
                case .uiLang: LanguagePickerView(kind: .ui)
                case .speakLang: LanguagePickerView(kind: .speak)
                case .help: HelpView()
                case .privacy: PrivacyView()
                }
            }
            .confirmationDialog("退出登录", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await auth.signOut() }
                }
                Button("取消", role: .cancel) { }
            }
            // 封面右上角的“换背景”：从相册选一张，选完立刻生效。
            .sheet(isPresented: $showCoverPicker) {
                PhotoPicker { image in
                    auth.setCustomCover(image)
                }
            }
        }
    }

    // MARK: - 封面横幅

    private var coverHeader: some View {
        ZStack {
            // 封面背景：相册自选的背景优先，没有就用当前头像（相册照片或预设图），
            // 再没有就用默认图。深色渐变遮罩不变，保证昵称和好友号的字看得清。
            Group {
                if let cover = auth.customCoverImage {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else if let photo = auth.customAvatarImage {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(auth.avatarAssetName)
                        .resizable()
                        .scaledToFill()
                }
            }
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
                        coverCircleButton(icon: "photo") { showCoverPicker = true }
                        coverCircleButton(icon: "qrcode.viewfinder") { path.append(.refer) }
                        coverCircleButton(icon: "gearshape") { path.append(.profile) }
                    }
                }
                Spacer()
                // 整行点按进个人资料；复制按钮是独立的 Button，不再套在链接里。
                HStack(spacing: 14) {
                    UserAvatarImage(size: 76)
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
                .contentShape(Rectangle())
                .onTapGesture { path.append(.profile) }
            }
            .padding(16)
        }
        .frame(height: 280)
    }

    private func coverCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    /// 分组卡片：深色模式修（第 7 步）——原来写死 Color.white，
    /// 深色模式下行文字是自适应的白色，白字印白底看不见。
    /// 改成 secondarySystemGroupedBackground：浅色还是白卡片，深色变深灰。
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
    }
}

/// “我的”页的导航目标（编程式导航用）。
/// profileSub 是个人资料页里的 13 行子页：资料页自己不另建 NavigationStack，
/// 点行时往同一个 path 里加目标，返回也走同一条栈。
enum MeDestination: Hashable {
    case profile
    case profileSub(ProfileSubPage)
    case moments
    case refer
    case uiLang
    case speakLang
    case help
    case privacy
}

/// 设置行：彩色圆角方块图标 + 文字 + 可选灰色值 + 右边灰色 ›。
/// 就是普通 Button，点按由调用方处理（往导航 path 里加目标）。
struct SettingRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String?
    let action: () -> Void

    init(
        icon: String,
        iconColor: Color,
        title: String,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
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
            // 点按修：和个人资料页同款毛病——行中间空白处没有内容，点按会透过行，
            // 加上整行宽 + contentShape，让整行任何位置都能点开。
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import CoreImage
import UIKit

// MARK: - 个人资料（只读展示，编辑后续步骤接入）

struct ProfileDetailView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("AvatarImage")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(auth.displayName).font(.headline)
                        Text("ID: \(auth.friendNumber)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
                LabeledRow(label: "昵称", value: auth.displayName)
                LabeledRow(label: "好友号", value: auth.friendNumber)
                LabeledRow(label: "邮箱", value: auth.currentUser?.email ?? "—")
            } footer: {
                Text("编辑功能后续步骤接入（换头像、改昵称、邮箱、密码、好友号）。")
            }
        }
        .navigationTitle("个人资料")
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 推荐好友（App 网址二维码 + 好友号）

struct ReferFriendView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            if let qr = qrImage(for: "https://zyty.cc.cd") {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
            }
            Text("扫码打开中越通译")
                .font(.headline)
            HStack(spacing: 8) {
                Text("我的好友号：\(auth.friendNumber)")
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = auth.friendNumber
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("推荐好友")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func qrImage(for string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - 语言选择（只存本机，后续步骤接入全 App 切换）

struct LanguagePickerView: View {
    enum Kind { case ui, speak }

    let kind: Kind
    @AppStorage("zy-ui-lang") private var uiLang = "zh"
    @AppStorage("zy-speak-lang") private var speakLang = "zh"

    private var selection: Binding<String> {
        kind == .ui ? $uiLang : $speakLang
    }

    var body: some View {
        List {
            Section {
                ForEach([("zh", "中文"), ("vi", "Tiếng Việt")], id: \.0) { code, name in
                    Button {
                        selection.wrappedValue = code
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if selection.wrappedValue == code {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            } footer: {
                Text("语言设置保存在本机，后续步骤接入全 App 切换。")
            }
        }
        .navigationTitle(kind == .ui ? "界面语言" : "我说的语言")
    }
}

// MARK: - 使用帮助

struct HelpView: View {
    private let steps: [(String, String, String)] = [
        ("1", "翻译助手", "不用加好友，直接和“翻译助手”聊天，中越互翻，还能发语音让它开口回答。"),
        ("2", "加好友", "输入对方 6 位好友号就能加好友，开始聊天和通话。"),
        ("3", "语音视频通话", "点好友头像打电话，通话里有实时翻译字幕。"),
        ("4", "离线消息与推送", "对方不在线也能发消息，对方上线后收到；来电有推送提醒。"),
    ]

    var body: some View {
        List {
            ForEach(steps, id: \.0) { number, title, body in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0, green: 0.48, blue: 1))
                            .frame(width: 26, height: 26)
                        Text(number)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(body)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("使用帮助")
    }
}

// MARK: - 隐私说明

struct PrivacyView: View {
    private let items: [(String, String)] = [
        ("文字翻译", "会发给翻译服务（Gemini / Cloudflare / Google / MyMemory），只发要翻译的那句话。"),
        ("通话字幕", "先用系统语音识别，识别不到就用云端识别（Cloudflare 语音识别）。"),
        ("翻译助手录音", "发给 Cloudflare 语音识别，识别成文字后再翻译、回答。"),
        ("朗读", "用 Google 云端语音。"),
        ("消息", "对方离线时存在 Cloudflare 服务器，对方上线后取走；聊天记录只存在你的手机上。"),
        ("推送", "后续接入苹果推送（APNs），关掉 App 也能收到消息和来电提醒。"),
    ]

    var body: some View {
        List {
            ForEach(items, id: \.0) { title, body in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(body)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("隐私说明")
    }
}

import SwiftUI
import CoreImage
import UIKit

// MARK: - 个人资料（可编辑：换头像 / 改男女 / 昵称 / 邮箱 / 密码 / 好友号）
// 和网页版第 33 轮的“我的资料”面板一致。

struct ProfileDetailView: View {
    @EnvironmentObject var auth: AuthViewModel

    @State private var avatar = "AvatarImage"
    @State private var gender = "male"
    @State private var nickname = ""
    @State private var email = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var friendNumber = ""
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isSaving = false

    private var avatarOptions: [String] {
        gender == "female" ? AuthViewModel.femaleAvatars : AuthViewModel.maleAvatars
    }

    private var currentNickname: String {
        auth.currentUser?.userMetadata["nickname"]?.stringValue ?? ""
    }

    private var currentFriendNumber: String {
        if let s = auth.currentUser?.userMetadata["num"]?.stringValue, !s.isEmpty { return s }
        if let n = auth.currentUser?.userMetadata["num"]?.intValue { return String(n) }
        return ""
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nickname.isEmpty ? auth.displayName : nickname).font(.headline)
                        Text("ID: \(friendNumber.isEmpty ? auth.friendNumber : friendNumber)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)

                // 换头像：按性别给选择。
                HStack(spacing: 16) {
                    ForEach(avatarOptions, id: \.self) { name in
                        Button { avatar = name } label: {
                            Image(name)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(
                                        avatar == name ? Color(red: 0, green: 0.48, blue: 1) : Color(.systemGray4),
                                        lineWidth: avatar == name ? 3 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)

                Picker("性别", selection: $gender) {
                    Text("男").tag("male")
                    Text("女").tag("female")
                }
                .pickerStyle(.segmented)
                .onChange(of: gender) { _, newGender in
                    // 换性别后，当前头像不在新性别的选项里就换成第一个（和网页版一致）。
                    let options = newGender == "female" ? AuthViewModel.femaleAvatars : AuthViewModel.maleAvatars
                    if !options.contains(avatar) {
                        avatar = options[0]
                    }
                }
            } header: {
                Text("头像与性别")
            }

            Section {
                TextField("昵称", text: $nickname)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("昵称与邮箱")
            } footer: {
                Text("改了邮箱要去新邮箱点确认，确认前仍用旧邮箱登录。")
            }

            Section {
                SecureField("新密码", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("确认密码", text: $confirmPassword)
                    .textContentType(.newPassword)
            } header: {
                Text("新密码")
            } footer: {
                Text("不改请留空；要改的话不少于 6 位，两次要一致。")
            }

            Section {
                TextField("好友号", text: $friendNumber)
                    .keyboardType(.numberPad)
                    .onChange(of: friendNumber) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        friendNumber = String(filtered.prefix(6))
                    }
            } header: {
                Text("好友号")
            } footer: {
                Text("改了好友号，别人用旧号就找不到你了，要重新加好友。")
            }

            if isSaving {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在保存…")
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }

            if let infoMessage {
                Section {
                    Text(infoMessage)
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("个人资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear {
            avatar = auth.avatarAssetName
            gender = auth.gender
            nickname = currentNickname
            email = auth.email
            newPassword = ""
            confirmPassword = ""
            friendNumber = currentFriendNumber
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil

        let nick = nickname.trimmingCharacters(in: .whitespaces)
        let newEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let num = friendNumber.filter { $0.isNumber }
        // 先记下旧值（保存成功后会话里的值就变了，后面比较要用旧值）。
        let oldNick = currentNickname
        let oldNum = currentFriendNumber

        // 校验（和网页版一致）。
        if !newEmail.isEmpty, !isValidEmail(newEmail) {
            errorMessage = "邮箱格式不对"
            return
        }
        if !newPassword.isEmpty || !confirmPassword.isEmpty {
            if newPassword.count < 6 {
                errorMessage = "新密码至少 6 位"
                return
            }
            if newPassword != confirmPassword {
                errorMessage = "两次输入的密码不一致"
                return
            }
        }
        if num.count != 6 || !num.allSatisfy({ $0.isNumber }) {
            errorMessage = "好友号必须是 6 位数字"
            return
        }

        isSaving = true
        defer { isSaving = false }

        // 头像和性别存本机（按邮箱分开存）。
        auth.avatarAssetName = avatar
        auth.gender = gender
        auth.saveLocalProfile()

        var notes: [String] = []
        var firstError: String?

        // 昵称 / 好友号：写 user_metadata。
        if nick != oldNick || num != oldNum {
            do {
                try await auth.updateProfileData(nickname: nick, friendNumber: num)
                if num != oldNum {
                    notes.append("好友号已改，别人用旧号找不到你，需要重新加好友")
                }
            } catch {
                firstError = error.localizedDescription
            }
        }

        // 邮箱：发确认邮件，点确认后才生效。
        if !newEmail.isEmpty, newEmail != auth.email {
            do {
                try await auth.updateEmail(newEmail)
                notes.append("确认邮件已发到新邮箱，点开确认后才生效")
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // 密码。
        if !newPassword.isEmpty {
            do {
                try await auth.updatePassword(newPassword)
                notes.append("密码已改")
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        if let firstError {
            errorMessage = firstError
        }
        if firstError == nil || !notes.isEmpty {
            var message = "已保存"
            if !notes.isEmpty {
                message += "。" + notes.joined(separator: "。")
            }
            infoMessage = message
        }
        newPassword = ""
        confirmPassword = ""
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

// MARK: - 语言选择（只存本机）

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
                Text("语言设置保存在本机。")
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
        ("推送", "苹果推送（APNs）尚未接入，关掉 App 后暂时收不到消息和来电提醒。"),
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

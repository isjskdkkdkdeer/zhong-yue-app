import Foundation
import Supabase

/// Supabase 连接配置。anon key 是公开的客户端 key，可以直接嵌进 App。
enum SupabaseConfig {
    static let url = "https://pobmofeyyybmadqgiooi.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBvYm1vZmV5eXlibWFkcWdpb29pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQyMzcxMDIsImV4cCI6MjEwOTgxMzEwMn0.SwciluHLDj779P-zXGp6NO7UOd1Sj0ib0D5xY7Pn-F4"
}

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: SupabaseConfig.url)!,
            supabaseKey: SupabaseConfig.anonKey
        )
    }
}

/// 登录状态（Supabase Auth）。会话存在 iOS Keychain 里，重启 App 仍保持登录。
@MainActor
final class AuthViewModel: ObservableObject {
    @Published var session: Session?
    @Published var isLoading = true
    @Published var authError: String?

    /// 本机资料：头像（Assets 资源名）、性别。按邮箱分开存，和网页版同款 key。
    @Published var avatarAssetName = "AvatarImage"
    @Published var gender = "male"

    private let client = SupabaseManager.shared.client

    var isSignedIn: Bool { session != nil }
    var currentUser: User? { session?.user }

    /// 昵称：取 Supabase user_metadata.nickname，取不到用邮箱。
    var displayName: String {
        if let name = currentUser?.userMetadata["nickname"]?.stringValue, !name.isEmpty {
            return name
        }
        return currentUser?.email ?? "未登录"
    }

    /// 好友号：取 Supabase user_metadata.num（6 位数字，可能是字符串或数字）。
    var friendNumber: String {
        if let s = currentUser?.userMetadata["num"]?.stringValue, !s.isEmpty {
            return s
        }
        if let n = currentUser?.userMetadata["num"]?.intValue {
            return String(n)
        }
        return "—"
    }

    /// 当前邮箱。
    var email: String { currentUser?.email ?? "" }

    func signIn(email: String, password: String) async {
        authError = nil
        do {
            let newSession = try await client.auth.signIn(email: email, password: password)
            session = newSession
            isLoading = false
            loadLocalProfile()
        } catch {
            authError = error.localizedDescription
        }
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
            session = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - 本机资料（头像 / 性别，按邮箱存）

    private func avatarKey(for email: String) -> String {
        "zhyuetong-avatar-" + email
    }

    private func genderKey(for email: String) -> String {
        "zhyuetong-gender-" + email
    }

    /// 登录后（或会话恢复后）读出本机存的头像和性别。
    func loadLocalProfile() {
        let email = self.email
        guard !email.isEmpty else { return }
        let savedAvatar = UserDefaults.standard.string(forKey: avatarKey(for: email)) ?? ""
        let savedGender = UserDefaults.standard.string(forKey: genderKey(for: email)) ?? ""
        avatarAssetName = Self.avatarAssetNames.contains(savedAvatar) ? savedAvatar : "AvatarImage"
        gender = (savedGender == "female" || savedGender == "male") ? savedGender : "male"
    }

    func saveLocalProfile() {
        let email = self.email
        guard !email.isEmpty else { return }
        UserDefaults.standard.set(avatarAssetName, forKey: avatarKey(for: email))
        UserDefaults.standard.set(gender, forKey: genderKey(for: email))
    }

    /// 全部头像资源名。男：默认头像 + m1 + m2；女：f1 + f2（和网页版一致）。
    static let maleAvatars = ["AvatarImage", "AvatarM1", "AvatarM2"]
    static let femaleAvatars = ["AvatarF1", "AvatarF2"]
    static let avatarAssetNames = maleAvatars + femaleAvatars

    /// 当前性别可选的头像。
    var avatarOptions: [String] {
        gender == "female" ? Self.femaleAvatars : Self.maleAvatars
    }

    // MARK: - 改资料（Supabase updateUser）

    /// 把更新后的用户写回当前会话，让“我的”页封面立刻刷新。
    private func applyUpdatedUser(_ user: User) {
        if var s = session {
            s.user = user
            session = s
        }
    }

    /// 改昵称 / 好友号（写 user_metadata）。GoTrue 会把 data 合并进现有 metadata。
    @discardableResult
    func updateProfileData(nickname: String, friendNumber: String) async throws -> User {
        let updated = try await client.auth.update(user: UserAttributes(data: [
            "nickname": .string(nickname),
            "num": .string(friendNumber),
        ]))
        applyUpdatedUser(updated)
        return updated
    }

    /// 改邮箱。Supabase 会往新邮箱发确认邮件，点确认后才生效，确认前仍用旧邮箱登录。
    @discardableResult
    func updateEmail(_ newEmail: String) async throws -> User {
        let updated = try await client.auth.update(user: UserAttributes(email: newEmail))
        applyUpdatedUser(updated)
        return updated
    }

    /// 改密码。
    @discardableResult
    func updatePassword(_ newPassword: String) async throws -> User {
        let updated = try await client.auth.update(user: UserAttributes(password: newPassword))
        applyUpdatedUser(updated)
        return updated
    }

    /// 从服务器重新取一次当前用户（刷新 metadata）。
    func refreshUser() async {
        do {
            let user = try await client.auth.user()
            applyUpdatedUser(user)
        } catch {
            // 静默失败：界面仍用旧数据。
        }
    }
}

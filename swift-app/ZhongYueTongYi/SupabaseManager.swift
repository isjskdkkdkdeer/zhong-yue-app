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

    func signIn(email: String, password: String) async {
        authError = nil
        do {
            let newSession = try await client.auth.signIn(email: email, password: password)
            session = newSession
            isLoading = false
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
}

import SwiftUI

struct NativeFriend: Codable, Identifiable, Equatable, Hashable {
    /// 6 位好友号，即好友的唯一标识。
    var id: String
    var nickname: String
}

/// 好友列表存在本机（UserDefaults）。
/// 限制：网页版的好友存在各手机浏览器的 localStorage 里，原生 App 读不到，
/// 所以这里的好友列表和网页版不互通；好友连接（真实聊天/通话）后续步骤接入。
@MainActor
final class FriendStore: ObservableObject {
    @Published private(set) var friends: [NativeFriend] = []
    private let storageKey = "zy-native-friends"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([NativeFriend].self, from: data)
        else {
            friends = []
            return
        }
        friends = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 添加好友（本机列表）。6 位数字、未重复才成功。
    @discardableResult
    func add(number: String) -> Bool {
        guard number.count == 6,
              number.allSatisfy({ $0.isNumber }),
              !friends.contains(where: { $0.id == number })
        else { return false }
        friends.append(NativeFriend(id: number, nickname: "好友 \(number)"))
        save()
        return true
    }

    func remove(at offsets: IndexSet) {
        friends.remove(atOffsets: offsets)
        save()
    }
}

struct FriendsView: View {
    /// 好友列表由 MainTabView 统一持有，和消息列表共用同一份数据。
    @EnvironmentObject var store: FriendStore
    @State private var showAddFriend = false

    var body: some View {
        NavigationStack {
            Group {
                if store.friends.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.secondary)
                        Text("还没有好友")
                            .font(.headline)
                        Text("好友列表暂存于本机，与网页版不互通。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("添加好友") { showAddFriend = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        Section {
                            ForEach(store.friends) { friend in
                                NavigationLink {
                                    ChatView(conversationId: friend.id, isBot: false, title: friend.nickname)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color(.systemGray5))
                                            Text(String(friend.nickname.prefix(1)))
                                                .font(.headline)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 44, height: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friend.nickname)
                                            Text("好友号 \(friend.id)")
                                                .font(.footnote)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .onDelete(perform: store.remove)
                        } footer: {
                            Text("好友列表暂存于本机，与网页版不互通。")
                        }
                    }
                }
            }
            .navigationTitle("好友")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddFriend = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendView(store: store)
            }
        }
    }
}

struct AddFriendView: View {
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6 位好友号", text: $number)
                        .keyboardType(.numberPad)
                        .onChange(of: number) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            number = String(filtered.prefix(6))
                        }
                } footer: {
                    Text("本次仅保存到本机列表，好友连接后续步骤接入。")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if store.add(number: number) {
                            dismiss()
                        } else {
                            errorMessage = "请输入 6 位数字好友号，且不要重复添加。"
                        }
                    }
                    .disabled(number.count != 6)
                }
            }
        }
    }
}

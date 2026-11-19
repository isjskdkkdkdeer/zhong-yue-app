import SwiftUI
import UIKit

/// 快速翻译（照网页版第 34 轮）：不用加好友，直接中越互翻；
/// 方向可换，结果点一下复制。
struct QuickTranslateView: View {
    @Environment(\.dismiss) private var dismiss

    /// 方向默认跟“我说的语言”走：我说中文就中→越，我说越南话就越→中。
    @State private var from: ChatLanguage = AppLanguage.speakLang
    @State private var input = ""
    @State private var result = ""
    @State private var isTranslating = false
    @State private var failed = false
    @State private var copied = false

    private var to: ChatLanguage { from.other }
    private var directionLabel: String {
        from == .zh ? "中文 → 越南语" : "越南语 → 中文"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Button(action: { from = to }) {
                    HStack {
                        Text(directionLabel)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundColor(Color(red: 0, green: 0.48, blue: 1))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                TextEditor(text: $input)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .overlay(
                        Group {
                            if input.isEmpty {
                                Text("输入要翻译的话…")
                                    .foregroundColor(Color(.placeholderText))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    )

                Button(action: translate) {
                    if isTranslating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("翻译一下")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(red: 0, green: 0.48, blue: 1))
                .foregroundColor(.white)
                .cornerRadius(12)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranslating)
                .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranslating ? 0.5 : 1)

                // 结果：点一下复制。
                if failed {
                    Text("翻译失败，请再试一次")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !result.isEmpty {
                    Button(action: copyResult) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result)
                                .font(.system(size: 17))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(copied ? "已复制" : "点一下翻译结果可以复制")
                                .font(.footnote)
                                .foregroundColor(copied ? .green : .secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }

                Text("不用加好友，直接翻。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(16)
            .navigationTitle("快速翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isTranslating = true
        failed = false
        result = ""
        copied = false
        let fromLang = from
        Task {
            do {
                let out = try await TranslationService.shared.translate(text: text, from: fromLang, to: fromLang.other)
                result = out
            } catch {
                failed = true
            }
            isTranslating = false
        }
    }

    private func copyResult() {
        guard !result.isEmpty else { return }
        UIPasteboard.general.string = result
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

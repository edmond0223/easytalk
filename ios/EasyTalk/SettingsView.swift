import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sonioxKey = Keychain.get(Keychain.sonioxAccount) ?? ""
    @AppStorage(Prefs.scene) private var scene = TalkScene.work.rawValue
    @AppStorage(Prefs.topic) private var topic = ""
    @AppStorage(Prefs.terms) private var terms = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("粘贴 Soniox API Key", text: $sonioxKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Soniox")
                } footer: {
                    Text(sonioxKey.isEmpty ? "还没有填写。" : "已填写（\(sonioxKey.count) 个字符）。只保存在这台 iPhone 的钥匙串里。")
                }

                Section("对话场景") {
                    Picker("场景", selection: $scene) {
                        ForEach(TalkScene.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }

                Section("会议演讲主题（可选）") {
                    TextField("例如：Q3 sales review、糖尿病讲座", text: $topic)
                }

                Section {
                    TextEditor(text: $terms)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("词表（\(parseTerms(terms).terms.count) 个）")
                } footer: {
                    Text("每行一个常用词或易错说法，例如 due on Monday；写成「OHIP = 安省医保」还能指定翻译。下次点「开始」时生效。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Keychain.set(Keychain.sonioxAccount,
                                     sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

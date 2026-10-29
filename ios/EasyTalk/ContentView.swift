import SwiftUI
import UIKit

struct ContentView: View {
    @State private var session = TalkSession()
    @State private var showSettings = false
    @State private var confirmClear = false
    @AppStorage(Prefs.fontSize) private var fontSize: Double = 24
    @AppStorage("zhOnly") private var zhOnly = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("模式", selection: $session.mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .disabled(session.running)

                transcript

                if session.mode == .lecture { lectureBar }
                controls
            }
            .navigationTitle("EasyTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusBadge(text: session.status, running: session.running)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(session.running)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("提示", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("好") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .confirmationDialog("清空当前记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { session.clear() }
            }
        }
    }

    // MARK: transcript

    private var visible: [Utterance] {
        session.utterances.filter { !$0.enText.isEmpty || !$0.zhText.isEmpty }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visible.isEmpty { HintView(mode: session.mode) }
                    ForEach(visible) { u in
                        if session.mode == .lecture {
                            ParagraphView(utterance: u,
                                          speaker: session.distinctSpeakers > 1 ? session.speakerName(u.speaker) : nil,
                                          fontSize: fontSize, zhOnly: zhOnly)
                        } else {
                            BubbleView(utterance: u,
                                       isMe: session.me.contains(u.speaker),
                                       name: session.speakerName(u.speaker)) {
                                session.toggleMe(u.speaker)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: session.revision) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: bars

    private var lectureBar: some View {
        HStack(spacing: 10) {
            Toggle("仅看中文", isOn: $zhOnly)
                .toggleStyle(.button)
            Button("A−") { fontSize = max(18, fontSize - 2) }
            Button("A+") { fontSize = min(40, fontSize + 2) }
            Spacer()
            ShareLink(item: exportText) { Label("导出", systemImage: "square.and.arrow.up") }
                .disabled(visible.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                Rectangle().fill(.green)
                    .frame(width: g.size.width * CGFloat(min(1, session.level * 1.4)))
            }
            .frame(height: 3)
            HStack(spacing: 12) {
                Button("清空") { confirmClear = true }
                    .disabled(session.running || visible.isEmpty)
                Button {
                    if session.running { session.stop() } else { Task { await session.start() } }
                } label: {
                    Text(session.running ? "停止" : "开始")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.running ? Color.red : Color.blue)
            }
            .padding()
        }
        .background(.bar)
    }

    private var exportText: String {
        let multi = session.distinctSpeakers > 1
        var lines = ["EasyTalk \(Date().formatted(date: .abbreviated, time: .shortened))"]
        let topic = UserDefaults.standard.string(forKey: Prefs.topic) ?? ""
        if session.mode == .lecture, !topic.isEmpty { lines.append("主题：\(topic)") }
        lines.append("")
        for u in visible {
            if multi { lines.append("【\(session.speakerName(u.speaker))】") }
            if !u.enText.isEmpty { lines.append(u.enText) }
            if !u.zhText.isEmpty { lines.append(u.zhText) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - pieces

struct StatusBadge: View {
    let text: String
    let running: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(running ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 4)
    }
}

struct HintView: View {
    let mode: Mode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .chat {
                Text("点下方「开始」，把手机放在你和对方之间。")
                Text("对方的话显示英文和**大字中文**；你说话后，点那条字幕上的标签把自己标成「我」。")
            } else {
                Text("点下方「开始」，把手机朝向讲话的人。")
                Text("中文在上、英文在下；可以在设置里填会议主题，识别专业词会更准。")
            }
            Text("锁屏后会继续收音。不保存录音；清空后记录就没了。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct BubbleView: View {
    let utterance: Utterance
    let isMe: Bool
    let name: String
    let onTag: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onTag) {
                Text(isMe ? "我 · 不是我" : "\(name) · 这是我?").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            if !utterance.enText.isEmpty {
                Text(utterance.enText)
                    .font(isMe ? Font.body : Font.subheadline)
                    .foregroundStyle(isMe ? Color.primary : Color.englishText)
            }
            if !utterance.zhText.isEmpty {
                Text(utterance.zhText)
                    .font(isMe ? Font.footnote : Font.system(size: 23, weight: .semibold))
                    .foregroundStyle(isMe ? Color.secondary : Color.primary)
            }
        }
        .opacity(utterance.hasPending ? 0.8 : 1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isMe ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .padding(.leading, isMe ? 40 : 0)
        .padding(.trailing, isMe ? 0 : 40)
        .textSelection(.enabled)
    }
}

struct ParagraphView: View {
    let utterance: Utterance
    let speaker: String?
    let fontSize: Double
    let zhOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker {
                Text(speaker).font(.caption).foregroundStyle(.blue)
            }
            if !utterance.zhText.isEmpty {
                Text(utterance.zhText)
                    .font(.system(size: fontSize, weight: .semibold))
            }
            if !zhOnly, !utterance.enText.isEmpty {
                Text(utterance.enText)
                    .font(.system(size: fontSize * 0.62))
                    .foregroundStyle(Color.englishText)
            }
            Divider().padding(.top, 6)
        }
        .opacity(utterance.hasPending ? 0.8 : 1)
        .textSelection(.enabled)
    }
}

extension Color {
    /// English captions: a clear sky blue on dark backgrounds, a deep blue on light ones.
    static let englishText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.53, green: 0.80, blue: 1.00, alpha: 1)   // #87CCFF
            : UIColor(red: 0.07, green: 0.33, blue: 0.75, alpha: 1)   // #1254BF
    })
}

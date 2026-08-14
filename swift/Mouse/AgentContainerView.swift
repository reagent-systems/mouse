import SwiftUI

/// The Agent container (kind 6): a coding agent working on the ring's workspace.
///
/// Laid out the way the reference is: the exchange scrolls above, a follow-up field with a
/// microphone sits at the bottom, and the status line under it carries the workspace and the
/// agent picker. Vertical scroll and taps only, per the gesture law — the horizontal drag
/// belongs to the shell.
struct AgentContainerView: View {
    var deck: CarouselDeck?

    @State private var session = AgentSession()
    @State private var dictation = Dictation()
    @State private var draft = ""
    @State private var pickerOpen = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(session.agent.name.lowercased()) on \(deck?.workspace?.repoFullName ?? "no project")")
                .font(.custom(AppFont.asciiName, size: 11))
                .opacity(0.55)
                .lineLimit(1)
                .truncationMode(.middle)
            Color.clear.frame(height: 12)
            exchange
            Spacer(minLength: 0)
            if let problem = session.problem ?? dictation.problem {
                Text(problem)
                    .font(.custom(AppFont.asciiName, size: 11))
                    .opacity(0.85)
                    .padding(.bottom, 6)
            }
            if pickerOpen { picker }
            input
            statusLine
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .onAppear { session.attach(root: deck?.workspace?.root) }
        .onChange(of: deck?.workspace?.root) { _, root in session.attach(root: root) }
    }

    // MARK: - The exchange

    private var exchange: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        row(message).id(message.id)
                    }
                    if session.working {
                        ThinkingOrbLabel(state: .working, text: "working…")
                    } else if dictation.listening {
                        ThinkingOrbLabel(state: .listening, text: "agent listening…")
                    } else if session.messages.isEmpty {
                        ThinkingOrbLabel(state: .idle, text: "ask \(session.agent.name.lowercased())")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ message: AgentSession.Message) -> some View {
        switch message.author {
        case .you:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .agent:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 13))
                .textSelection(.enabled)
        case .note:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
        }
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, axis: .vertical)
                .font(.custom(AppFont.asciiName, size: 13))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
            // The microphone fills the field rather than sending: dictation misreads identifiers,
            // and a prompt you cannot correct before it runs is worse than typing it.
            Button {
                Task { await toggleDictation() }
            } label: {
                Image(systemName: dictation.listening ? "mic.fill" : "mic")
                    .font(.system(size: 15))
                    .foregroundStyle(dictation.listening ? .red : .white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!dictation.available)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(draft.isEmpty ? 0.25 : 0.9))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty || session.working)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Picker and status

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CodingAgent.all) { entry in
                Button {
                    session.agent = entry
                    pickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(entry.blocked == nil ? 1 : 0.5)
                        Text(entry.runtime.rawValue)
                            .font(.custom(AppFont.asciiName, size: 10))
                            .opacity(0.4)
                        Spacer(minLength: 0)
                        if entry.id == session.agent.id {
                            Text("•").font(.custom(AppFont.asciiName, size: 13))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let blocked = entry.blocked {
                    Text(blocked)
                        .font(.custom(AppFont.asciiName, size: 10))
                        .opacity(0.4)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                pickerOpen.toggle()
            } label: {
                Text("\(session.agent.name) \(pickerOpen ? "^" : "v")")
                    .font(.custom(AppFont.asciiName, size: 10))
                    .opacity(0.55)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func send() {
        let text = draft
        draft = ""
        Task { await session.send(text) }
    }

    private func toggleDictation() async {
        if dictation.listening {
            dictation.stop()
            let spoken = dictation.take()
            if !spoken.isEmpty {
                draft = draft.isEmpty ? spoken : draft + " " + spoken
            }
        } else {
            await dictation.start()
        }
    }
}

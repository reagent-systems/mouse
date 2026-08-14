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
    @State private var settings = AgentSettings.shared
    @State private var setupDraft = ""
    @State private var addressDraft = ""
    @FocusState private var inputFocused: Bool
    @FocusState private var addressFocused: Bool
    @FocusState private var setupFocused: Bool

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
            // A blocked agent does not ask for setup. Hermes needs a gateway address, but
            // nothing here can use one yet, and a field that collects a value the app ignores is
            // worse than no field — it reads as "configure me and I will work".
            // The address asks on its own terms, not behind the key. Gating it on the key being
            // empty meant it could never be reached once a key was saved — and a keychain entry
            // survives deleting the app, so "reinstall to fix it" does not work either. Submit an
            // address, even the default one, and the row goes.
            if session.agent.embedded || session.agent.endpointVariable != nil, session.agent.blocked == nil,
               settings.address(for: session.agent).isEmpty {
                addressField
            }
            if let setting = session.agent.setting, session.agent.blocked == nil,
               !settings.isSet(for: session.agent) {
                setup(setting)
            }
            if let blocked = session.agent.blocked {
                Text(blocked)
                    .font(.custom(AppFont.asciiName, size: 10))
                    .opacity(0.4)
                    .padding(.bottom, 8)
            }
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
            // The orb IS the microphone. It already had a listening state and it already sits
            // where the reference puts it, so a separate glyph beside it was two things saying
            // one thing. Tapping starts dictation and the orb picks up; tapping again stops it.
            // It fills the field rather than sending: dictation misreads identifiers, and a
            // prompt you cannot correct before it runs is worse than typing it.
            Button {
                Task { await toggleDictation() }
            } label: {
                ThinkingOrb(state: dictation.listening ? .listening : .idle, size: 20)
                    .frame(width: 32, height: 32)
                    .opacity(dictation.available ? 1 : 0.3)
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

    private var addressField: some View {
        HStack(spacing: 8) {
            Text("address")
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
            TextField("model endpoint (host[:port])", text: $addressDraft)
                .font(.custom(AppFont.asciiName, size: 12))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($addressFocused)
                // Saved on return AND on tapping away: on a phone, leaving a field is how
                // most people finish it, and a value that quietly evaporates on blur is a
                // setting that never sticks.
                .onSubmit { settings.setAddress(addressDraft, for: session.agent) }
                .onChange(of: addressFocused) { was, is_ in
                    if was, !is_, !addressDraft.isEmpty {
                        settings.setAddress(addressDraft, for: session.agent)
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 6)
        .onAppear { addressDraft = settings.address(for: session.agent) }
        .onChange(of: session.agent.id) { _, _ in
            addressDraft = settings.address(for: session.agent)
        }
    }

    /// The one field an agent needs before it can answer, shown only while it is empty. Saved
    /// on submit and not asked again — a key retyped every launch is a container nobody opens.
    private func setup(_ setting: CodingAgent.Setting) -> some View {
        HStack(spacing: 8) {
            Text(setting.name)
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
            Group {
                if setting.secret {
                    SecureField(setting.placeholder, text: $setupDraft)
                } else {
                    TextField(setting.placeholder, text: $setupDraft)
                }
            }
            .font(.custom(AppFont.asciiName, size: 12))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($setupFocused)
            .onSubmit { commitSetup() }
            // The same blur rule as the address: finished is finished, whether the finger
            // found return or the next field.
            .onChange(of: setupFocused) { was, is_ in
                if was, !is_, !setupDraft.isEmpty { commitSetup() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 8)
    }

    private func commitSetup() {
        // Commit the address too: someone who fills both fields and finishes once should not
        // silently lose the one they did not submit.
        if session.agent.embedded || session.agent.endpointVariable != nil, !addressDraft.isEmpty {
            settings.setAddress(addressDraft, for: session.agent)
        }
        settings.set(setupDraft, for: session.agent)
        setupDraft = ""
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
                Text(session.agent.name)
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

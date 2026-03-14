import SwiftUI
import SwiftData

/// Chat overlay — press-and-hold voice input, no text field.
struct ChatOverlay: View {
    @Environment(SpeechService.self) private var speechService
    @Environment(SpeechSynthesisService.self) private var tts
    @Environment(APIKeyStore.self) private var apiKeyStore
    @Environment(\.openURL) private var openURL
    @Query(sort: \CareContact.updatedAt, order: .reverse)
    private var contacts: [CareContact]

    @Binding var viewModel: ChatViewModel?
    var perceptionState: PerceptionStateStore? = nil
    var faceRecognitionService: FaceRecognitionService? = nil

    @State private var isHolding = false
    @State private var pendingCallContact: CareContact?
    @State private var showCallConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if !speechService.recognizedText.isEmpty {
                Text(speechService.recognizedText)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }

            holdToTalkButton
        }
        .onAppear {
            speechService.checkPermission()
            if viewModel == nil {
                viewModel = buildViewModel()
            }
        }
        .alert("确认拨号", isPresented: $showCallConfirmation) {
            Button("取消", role: .cancel) {
                cancelDial()
            }
            Button(String(localized: "拨打")) {
                dialPendingContact()
            }
        } message: {
            Text(callConfirmationMessage)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel?.messages ?? []) { msg in
                        chatBubble(msg).id(msg.id)
                    }
                }
                .padding(.horizontal).padding(.top, 12)
            }
            .onChange(of: viewModel?.messages.count) {
                if let id = viewModel?.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Hold to Talk

    private var holdToTalkButton: some View {
        VStack(spacing: 8) {
            Image(systemName: isHolding ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(isHolding ? .red : .white.opacity(0.8))
                .symbolEffect(.pulse, isActive: isHolding)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isHolding else { return }
                            isHolding = true
                            speechService.startListening()
                        }
                        .onEnded { _ in
                            isHolding = false
                            speechService.stopListening()
                            let text = speechService.recognizedText
                            if !text.isEmpty {
                                handleUserUtterance(text)
                                speechService.recognizedText = ""
                            }
                        }
                )
            Text(isHolding ? "松开发送" : "按住说话")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 12)
    }

    // MARK: - Bubble

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 60) }
            Text(msg.text.isEmpty ? " " : msg.text)
                .font(.title3).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(
                    msg.role == .user ? Color.indigo.opacity(0.7) : Color.black.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 20)
                )
            if msg.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private func buildViewModel() -> ChatViewModel {
        ChatViewModel(
            apiClient: apiKeyStore.buildAPIClient(),
            deepSeekAPIKey: apiKeyStore.deepSeekAPIKey,
            tts: tts,
            perceptionState: perceptionState,
            faceRecognitionService: faceRecognitionService
        )
    }

    private var callConfirmationMessage: String {
        guard let contact = pendingCallContact else { return String(localized: "是否拨打电话？") }
        return String(localized: "是否要给\(contact.confirmationName)打电话？")
    }

    private func handleUserUtterance(_ text: String) {
        if viewModel == nil {
            viewModel = buildViewModel()
        }
        guard let vm = viewModel else { return }

        if let intent = ContactCallIntentResolver.resolve(text: text, contacts: contacts) {
            vm.appendLocalUserMessage(text)
            vm.appendLocalAssistantMessage(String(localized: "是否要给\(intent.contact.confirmationName)打电话？"))
            pendingCallContact = intent.contact
            showCallConfirmation = true
            return
        }

        vm.sendMessage(text)
    }

    private func cancelDial() {
        guard let vm = viewModel, let contact = pendingCallContact else { return }
        vm.appendLocalAssistantMessage(String(localized: "好的，已取消给\(contact.confirmationName)拨号。"))
        vm.recordPatientBehavior("患者取消拨打联系人：\(contact.displayName)")
        pendingCallContact = nil
    }

    private func dialPendingContact() {
        guard let vm = viewModel, let contact = pendingCallContact else { return }
        let dialable = contact.dialableNumber
        guard !dialable.isEmpty, let url = URL(string: "tel://\(dialable)") else {
            vm.appendLocalAssistantMessage(String(localized: "这个电话号码格式不正确，暂时无法拨打。"))
            vm.recordPatientBehavior("患者尝试拨打联系人失败：号码格式无效，联系人=\(contact.displayName)")
            pendingCallContact = nil
            return
        }

        let dialTarget = contact.confirmationName
        vm.appendLocalAssistantMessage(String(localized: "正在为你拨打\(dialTarget)。"))
        vm.recordPatientBehavior("患者发起拨号：联系人=\(contact.displayName)，号码=\(contact.phoneNumber)")
        openURL(url) { accepted in
            if !accepted {
                Task { @MainActor in
                    vm.appendLocalAssistantMessage(String(localized: "当前设备暂不支持拨号，请让照护者协助。"))
                    vm.recordPatientBehavior("患者尝试拨号但设备不支持：联系人=\(contact.displayName)")
                }
            }
        }
        pendingCallContact = nil
    }
}

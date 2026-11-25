import SwiftUI

@main
struct PadDisplayApp: App {
    var body: some Scene {
        WindowGroup { PadDisplayView() }
    }
}

private struct PadDisplayView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = PadSession()

    var body: some View {
        Group {
            if session.phase == .display, let surface = session.surface {
                ConnectedDisplay(session: session, surface: surface)
            } else {
                ConnectionSetup(session: session)
            }
        }
        .overlay {
            if scenePhase != .active { Color.black.ignoresSafeArea() }
        }
        .onAppear { if scenePhase == .active { session.start() } }
        .onChange(of: scenePhase) { phase in
            if phase == .active { session.start() }
            if phase == .background { session.suspend() }
        }
    }
}

private struct ConnectionSetup: View {
    @ObservedObject var session: PadSession
    @FocusState private var enteringCode: Bool

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "display.2")
                            .font(.system(size: 40, weight: .medium)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("İkinci Ekran").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text("Mac’te paylaşımı başlat ve iki cihazı aynı Wi-Fi ağına bağla.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mac seç").font(.headline).accessibilityAddTraits(.isHeader)
                        if let error = session.discoveryError {
                            Text(error).foregroundStyle(.secondary)
                            Button("Yeniden ara") { session.disconnect() }
                        } else if session.peers.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Ağdaki Mac’ler aranıyor…").foregroundStyle(.secondary)
                            }
                            Text("İstenirse iPad’de yerel ağ erişimine izin ver.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(session.peers) { peer in
                                Button {
                                    session.select(peer)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "laptopcomputer")
                                        Text(peer.name).multilineTextAlignment(.leading)
                                        Spacer()
                                        if session.selection == peer { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                    }
                                    .padding(12).frame(minHeight: 46)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(session.selection == peer ? [.isSelected] : [])
                                .disabled(session.phase == .connecting)
                            }
                        }
                    }
                    if session.selection != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mac’teki eşleştirme kodu").font(.headline)
                            TextField("XXXX-XXXX-XXXX-XXXX", text: $session.code)
                                .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                                .keyboardType(.asciiCapable).textInputAutocapitalization(.characters)
                                .disableAutocorrection(true).submitLabel(.go).focused($enteringCode)
                                .accessibilityLabel("Eşleştirme kodu")
                                .onSubmit { connect() }.disabled(session.phase == .connecting)
                        }
                    }
                    if let error = session.connectionError {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.primary)
                    }
                    if session.phase == .connecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Bağlanıyor…")
                            Spacer()
                            Button("Vazgeç", action: session.disconnect)
                        }
                    } else if session.selection != nil {
                        Button(action: connect) {
                            Label("Bağlan", systemImage: "display").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canConnect)
                    }
                }
                .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }
    }

    private func connect() {
        guard session.canConnect else { return }
        enteringCode = false
        session.connect()
    }
}

private struct ConnectedDisplay: View {
    @ObservedObject var session: PadSession
    let surface: VideoSurface
    @State private var controlsShown = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoCanvas(surface: surface).ignoresSafeArea().accessibilityHidden(true)
            Button {
                controlsShown.toggle()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain).ignoresSafeArea()
            .accessibilityLabel(controlsShown ? "Denetimleri gizle" : "Bağlantı denetimlerini göster")

            if !session.hasPicture {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Mac’in ekranı bekleniyor…").foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .allowsHitTesting(false)
            }
            if controlsShown || !session.hasPicture {
                Button(action: session.disconnect) {
                    Label("Bağlantıyı kes", systemImage: "xmark.circle.fill")
                        .font(.callout.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                        .foregroundColor(.white).background(Color.black.opacity(0.8), in: Capsule())
                }
                .padding(12)
            }
        }
        .background(Color.black.ignoresSafeArea()).statusBar(hidden: true)
        .task(id: controlsShown && session.hasPicture) {
            guard controlsShown, session.hasPicture else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            controlsShown = false
        }
    }
}

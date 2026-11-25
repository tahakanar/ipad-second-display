import AppKit
import SwiftUI

struct HostView: View {
    let controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "macbook.and.ipad")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("iPad ile ikinci ekran").font(.title2.bold())
                    Text(verbatim: controller.computerName).foregroundStyle(.secondary)
                }
            }

            Divider()
            details
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if controller.phase == .sharing {
                    Button("Ekranları yerleştir…") { controller.openDisplaySettings() }
                } else if controller.phase == .permissionRequired {
                    Button("İzin ayarlarını aç…") { controller.openCaptureSettings() }
                }
                Spacer()
                if controller.isServing {
                    Button("Paylaşımı durdur") { controller.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(controller.phase == .idle ? "Paylaşımı başlat" : "Yeniden dene") {
                        controller.start()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 470)
    }

    @ViewBuilder
    private var details: some View {
        switch controller.phase {
        case .idle:
            Text("iPad’i bu Mac ile aynı Wi-Fi ağına bağlayın. Paylaşımı başlatınca iPad’de kullanacağınız eşleme kodu burada görünür.")
        case .permissionRequired:
            message("Ekran kaydı izni gerekiyor",
                    "Sistem Ayarları’nda bu uygulamaya ekran kaydı izni verin. macOS yeniden açmanızı isterse uygulamayı kapatıp açın.")
        case .preparing:
            ProgressView("Yerel ağ bağlantısı hazırlanıyor…").controlSize(.small)
        case .waiting:
            VStack(alignment: .leading, spacing: 12) {
                Text("iPad’de İkinci Ekran’ı açın, bu Mac’i seçin ve kodu girin.")
                HStack {
                    Text(verbatim: controller.pairingCode)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    if !controller.pairingCode.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.pairingCode, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Eşleme kodunu kopyala")
                        .accessibilityLabel("Eşleme kodunu kopyala")
                    }
                }
            }
        case .startingDisplay:
            ProgressView("iPad bağlandı. İkinci ekran açılıyor…").controlSize(.small)
        case .sharing:
            message("iPad ekranı bağlı",
                    "Bir pencereyi iPad’e taşımak için Mac ekranının kenarından sürükleyin. iPad’in hangi tarafta olduğunu Ekranlar ayarından seçebilirsiniz.")
        case .failed(let reason):
            message("Paylaşım durdu", reason)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: detail).foregroundStyle(.secondary)
        }
    }
}

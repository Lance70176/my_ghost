import AppKit
import SwiftUI

/// The Web Access window: a switch that turns MyGhost Web on, the addresses it
/// can be reached on, and a QR code for the selected one so a phone can join
/// without typing an IP.
struct WebAccessView: View {
    @ObservedObject var manager: WebAccessManager
    @State private var selected: WebAccessURL?
    @State private var copied = false

    private var current: WebAccessURL? {
        selected ?? manager.urls.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let reason = manager.unavailableReason {
                Text(reason)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.isRunning {
                addressList
                Divider()
                qrSection
            } else {
                Text("Turn this on to use your terminal tabs, file browser, and AI usage "
                     + "from a browser on Windows, a phone, or any other device.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                options
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { manager.refresh() }
        .onChange(of: manager.urls) { urls in
            if let selected, urls.contains(selected) { return }
            selected = urls.first
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundColor(manager.isRunning ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Web Access").font(.headline)
                Text(manager.isRunning ? "On — starts automatically at login" : "Off")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if manager.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { manager.isRunning },
                    set: { manager.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(manager.unavailableReason != nil)
            }
        }
    }

    private var options: some View {
        HStack(spacing: 12) {
            Toggle("No password", isOn: $manager.noAuth)
                .help("Skip the access token. Only for networks where every device is yours.")
            Spacer()
            HStack(spacing: 4) {
                Text("Port")
                TextField("", value: $manager.port, formatter: NumberFormatter())
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.callout)
    }

    private var addressList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(manager.urls) { entry in
                Button {
                    selected = entry
                    copied = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.id == current?.id
                              ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundColor(entry.id == current?.id ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(entry.kind.label) · \(entry.address)")
                                .font(.system(size: 12).monospacedDigit())
                            Text(entry.kind.detail)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var qrSection: some View {
        VStack(spacing: 10) {
            if let current, let image = WebAccessManager.qrImage(for: current.url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)

                Text(current.url)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(current.url, forType: .string)
                        copied = true
                    }
                    Button("Open in Browser") {
                        if let url = URL(string: current.url) { NSWorkspace.shared.open(url) }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

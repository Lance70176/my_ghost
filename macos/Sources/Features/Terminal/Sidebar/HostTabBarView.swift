import SwiftUI

// MARK: - Host entry model

/// A host tab in the top host tab bar. Each host owns a subset of the
/// sidebar's tabs: the local machine's tabs, or the tabs connected to one
/// remote SSH host. Switching hosts swaps the sidebar tab list and the
/// terminal content, so working on a remote machine feels the same as local.
class SidebarHostEntry: ObservableObject, Identifiable {
    let id = UUID()

    /// Display name shown on the host tab.
    @Published var name: String

    /// SSH destination ("user@host" or ssh config alias). nil = local machine.
    let target: String?

    /// Extra ssh options (port, identity file) used for new tabs on this host.
    var sshOptions: [String]

    /// The sidebar tab that was selected when this host was last active,
    /// restored when switching back to this host.
    var lastSelectedTabID: UUID?

    /// The highlighted item (possibly a group child) when this host was last active.
    var lastHighlightedItemID: UUID?

    var isLocal: Bool { target == nil }

    /// Stable bucketing key matching SidebarTabEntry.remoteTarget.
    var key: String { target ?? Self.localKey }

    static let localKey = "local"

    init(name: String, target: String?, sshOptions: [String] = []) {
        self.name = name
        self.target = target
        self.sshOptions = sshOptions
    }

    /// The entry representing this Mac, named after the machine.
    static func local() -> SidebarHostEntry {
        let name = Foundation.Host.current().localizedName ?? "Local"
        return SidebarHostEntry(name: name, target: nil)
    }
}

// MARK: - Host tab bar

/// The horizontal host tab bar at the top of the window. The first tab is
/// always the local machine. At the right end, the globe picks the interface
/// language and the computer opens a saved remote host in a new host tab. The
/// sidebar tab list follows the selected host.
struct HostTabBarView: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @ObservedObject var controller: SidebarTerminalController

    /// Whether the "Add Remote Host" sheet is visible.
    @State private var showAddRemoteHostSheet = false

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.hostTabs) { host in
                        HostTabItem(
                            host: host,
                            isSelected: controller.selectedHostID == host.id,
                            onSelect: { controller.selectHost(host) },
                            onClose: host.isLocal ? nil : { controller.closeHostTab(host) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                languageMenu
                remoteHostMenu
            }
            .padding(.trailing, 10)
        }
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showAddRemoteHostSheet) {
            AddRemoteHostSheet { host in
                RemoteHostManager.shared.addManualHost(host)
                controller.openHostTab(host: host)
            }
        }
    }

    /// Menu for the interface language: follow the system, or one of the
    /// languages MyGhost is translated into. Each is listed in its own
    /// language, so the way back is readable whatever is showing now.
    private var languageMenu: some View {
        Menu {
            Picker(L("Language"), selection: $lang.choice) {
                Text(L("System (%@)", AppLanguage.system.nativeName))
                    .tag(AppLanguage?.none)
                Divider()
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(AppLanguage?.some(language))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            SidebarActionIcon(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Language"))
    }

    /// Menu for opening a host tab. "Add Remote Host…" and the manually saved
    /// hosts come first — the ~/.ssh/config list can be very long, and putting
    /// them at the bottom meant scrolling through it every time.
    private var remoteHostMenu: some View {
        Menu {
            let configHosts = RemoteHostManager.shared.sshConfigHosts()
            let manualHosts = RemoteHostManager.shared.manualHosts()

            Button(L("Add Remote Host…")) {
                showAddRemoteHostSheet = true
            }

            if !manualHosts.isEmpty {
                Menu(L("Remove Saved Host")) {
                    ForEach(manualHosts) { host in
                        Button(host.name) {
                            RemoteHostManager.shared.removeManualHost(host)
                        }
                    }
                }
            }

            if !manualHosts.isEmpty {
                Divider()

                ForEach(manualHosts) { host in
                    Button {
                        controller.openHostTab(host: host)
                    } label: {
                        Label(host.name, systemImage: "network")
                    }
                }
            }

            if !configHosts.isEmpty {
                Divider()

                ForEach(configHosts) { host in
                    Button {
                        controller.openHostTab(host: host)
                    } label: {
                        Label(host.name, systemImage: "doc.text")
                    }
                }
            }
        } label: {
            SidebarActionIcon(systemName: "desktopcomputer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Connect to a remote host (SSH + tmux)"))
    }
}

// MARK: - Host tab item

private struct HostTabItem: View {
    /// Re-renders this view when the interface language changes.
    @ObservedObject private var lang = LanguageManager.shared

    @ObservedObject var host: SidebarHostEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: host.isLocal ? "laptopcomputer" : "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundColor(host.isLocal ? .secondary : .cyan)

            Text(host.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
                .help(L("Close host tab (remote sessions keep running)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.3)
                      : (isHovering ? Color.primary.opacity(0.08) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

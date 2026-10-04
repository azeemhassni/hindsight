import HindsightProtocol
import SwiftUI

/// The Coolify resources on a server: project → environment → resource.
///
/// Fed by what the agent discovered, because discovery needs the ssh
/// connection. Where the list came from is shown rather than implied: a
/// label-only list cannot see a resource whose containers are stopped, and
/// someone looking for one deserves to know that rather than conclude it is
/// gone.
public struct CoolifyTreeView: View {
    let report: CoolifyTreeReport?
    let isLoading: Bool
    let failure: String?
    let onRefresh: () async -> Void
    let onBackUp: (CoolifyResourceReport) -> Void
    let onRestore: (CoolifyResourceReport) -> Void

    @State private var selection: String?

    public init(
        report: CoolifyTreeReport?,
        isLoading: Bool,
        failure: String? = nil,
        onRefresh: @escaping () async -> Void,
        onBackUp: @escaping (CoolifyResourceReport) -> Void,
        onRestore: @escaping (CoolifyResourceReport) -> Void
    ) {
        self.report = report
        self.isLoading = isLoading
        self.failure = failure
        self.onRefresh = onRefresh
        self.onBackUp = onBackUp
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            Divider()
            content
        }
        .task {
            // Only on first appearance: discovery is an ssh round trip, and
            // re-running it on every tab switch would be rude to the server.
            if report == nil { await onRefresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, report == nil {
            ProgressView("Looking for Coolify resources…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report, !report.resources.isEmpty {
            List(selection: $selection) {
                ForEach(report.grouped, id: \.project) { group in
                    Section(group.project) {
                        ForEach(group.environments, id: \.name) { environment in
                            DisclosureGroup(environment.name) {
                                ForEach(environment.resources) { resource in
                                    CoolifyResourceRow(
                                        resource: resource,
                                        onBackUp: { onBackUp(resource) },
                                        onRestore: { onRestore(resource) }
                                    )
                                    .tag(resource.uuid)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(report == nil ? "Not looked yet" : "Nothing found")
                    .font(.headline)
                Text(emptyDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Look again") { Task { await onRefresh() } }
                    .accessibilityLabel("Look for Coolify resources again")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: bannerSymbol)
                .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            Text(bannerText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let version = report?.coolifyVersion {
                Text("Coolify \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await onRefresh() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Ask the server again")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .combine)
    }

    private var bannerSymbol: String {
        if failure != nil { return "exclamationmark.triangle" }
        return report?.source == "api" ? "checkmark.circle" : "info.circle"
    }

    private var bannerText: String {
        if let failure { return "Could not look on this server: \(failure)" }
        return report?.sourceExplanation
            ?? "Hindsight has not looked for Coolify on this server yet."
    }

    private var emptyDescription: String {
        if let failure {
            return """
            \(failure)

            Nothing is assumed from a failed look: what Hindsight last saw, if \
            anything, is shown instead.
            """
        }
        guard let report else {
            return "Looking needs a connection to the server."
        }
        if report.mayBeIncomplete {
            return """
            Nothing was visible. Container labels cannot see a resource whose \
            containers are stopped, and a Coolify API token only sees its own \
            team's servers — so this may not mean the instance is empty.
            """
        }
        return "No Coolify resources were found on this server."
    }
}

struct CoolifyResourceRow: View {
    let resource: CoolifyResourceReport
    let onBackUp: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name)
                HStack(spacing: 6) {
                    Text(subtitle)
                    if !resource.isRunning {
                        Text("stopped").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.age(of: resource.lastBackupAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Button("Back up now", systemImage: "arrow.clockwise", action: onBackUp)
                Button("Restore…", systemImage: "arrow.counterclockwise", action: onRestore)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contextMenu {
            Button("Back up now", systemImage: "arrow.clockwise", action: onBackUp)
            Button("Restore…", systemImage: "arrow.counterclockwise", action: onRestore)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(resource.kind) \(resource.name), \(subtitle), "
                + "last backup \(Format.age(of: resource.lastBackupAt))"
        )
    }

    private var symbol: String {
        switch resource.kind {
        case "application": "globe"
        case "service": "square.stack.3d.up"
        case "database": "cylinder.split.1x2"
        default: "shippingbox"
        }
    }

    private var subtitle: String {
        var parts = [resource.engine ?? resource.kind]
        if resource.volumeCount > 0 {
            parts.append("\(resource.volumeCount) volume\(resource.volumeCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

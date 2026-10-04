import HindsightCoolify
import HindsightCore
import SwiftUI

/// Project → Environment → Resource.
public struct CoolifyTreeView: View {
    let tree: CoolifyTree
    let lastBackup: (String) -> Date?
    let onBackUp: (CoolifyResource) -> Void
    let onRestore: (CoolifyResource) -> Void

    @State private var selection: String?

    public init(
        tree: CoolifyTree,
        lastBackup: @escaping (String) -> Date?,
        onBackUp: @escaping (CoolifyResource) -> Void,
        onRestore: @escaping (CoolifyResource) -> Void
    ) {
        self.tree = tree
        self.lastBackup = lastBackup
        self.onBackUp = onBackUp
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceBanner
            if tree.projects.isEmpty {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "shippingbox",
                    description: Text(emptyDescription)
                )
            } else {
                List(selection: $selection) {
                    ForEach(tree.projects, id: \.name) { project in
                        Section(project.name) {
                            ForEach(project.environments, id: \.name) { environment in
                                DisclosureGroup(environment.name) {
                                    ForEach(environment.resources) { resource in
                                        CoolifyResourceRow(
                                            resource: resource,
                                            lastBackup: lastBackup(resource.uuid),
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
            }
        }
        .navigationTitle("Coolify")
    }

    /// Where the tree came from matters: a label-only tree cannot show stopped
    /// resources, and someone looking for one deserves to know that rather
    /// than conclude it is gone.
    private var sourceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: tree.source == .api ? "checkmark.circle" : "info.circle")
                .accessibilityHidden(true)
            Text(tree.source.explanation)
                .font(.callout)
            Spacer()
            if let version = tree.coolifyVersion {
                Text("Coolify \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .combine)
    }

    private var emptyDescription: String {
        if tree.mayBeIncomplete {
            return """
            Nothing was visible to the token Hindsight has. A Coolify token \
            belongs to one team and only sees that team's servers, so this may \
            not mean the instance is empty.
            """
        }
        return "No Coolify resources were found on this server."
    }
}

struct CoolifyResourceRow: View {
    let resource: CoolifyResource
    let lastBackup: Date?
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
            Text(Format.age(of: lastBackup))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Back up now", systemImage: "arrow.clockwise", action: onBackUp)
            Button("Restore…", systemImage: "arrow.counterclockwise", action: onRestore)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(resource.kind.rawValue) \(resource.name), \(subtitle), "
                + "last backup \(Format.age(of: lastBackup))"
        )
    }

    private var symbol: String {
        switch resource.kind {
        case .application: "globe"
        case .service: "square.stack.3d.up"
        case .database: "cylinder.split.1x2"
        }
    }

    private var subtitle: String {
        resource.databaseEngineName ?? resource.subType ?? resource.kind.rawValue
    }
}

import SwiftUI

public struct ReplicaResult: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var path: String
    public var notes: String
    public var warnings: [String]

    public init(path: String, notes: String, warnings: [String]) {
        self.path = path
        self.notes = notes
        self.warnings = warnings
    }
}

/// What the replica image is, and what it deliberately is not.
public struct ReplicaResultSheet: View {
    let result: ReplicaResult
    let onClose: () -> Void

    public init(result: ReplicaResult, onClose: @escaping () -> Void) {
        self.result = result
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Replica image written").font(.title3.bold())
                Text(result.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        """
                        This carries no data. It rebuilds the machine — \
                        hostname, packages and services — on a fresh cloud \
                        image of the same distribution. Restore the data onto \
                        it afterwards with Restore, choosing it under "Where".
                        """,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(8)

                    if !result.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Worth knowing").font(.headline)
                            ForEach(result.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(6)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("How to use it").font(.headline)
                        Text("""
                        Create a machine from your provider's cloud image of the \
                        same distribution, attach this ISO as a second disk or \
                        CD, and boot it. cloud-init reads it once, on first \
                        boot.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(8)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Show in Finder") { revealInFinder() }
                    .help("Open the folder holding the image")
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func revealInFinder() {
        #if canImport(AppKit)
        NSWorkspace.shared.selectFile(result.path, inFileViewerRootedAtPath: "")
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif

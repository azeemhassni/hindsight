import HindsightProtocol
import SwiftUI

/// What has run, and what each run said.
///
/// The list and the log are side by side because the question is almost always
/// "that one failed — why?", and an answer that needs a second window is a
/// worse answer.
public struct JobHistoryView: View {
    let jobs: [JobReport]
    let log: [JobLogLine]
    @Binding var selection: String?
    let onReload: () async -> Void

    @State private var levelFilter: String?

    public init(
        jobs: [JobReport],
        log: [JobLogLine],
        selection: Binding<String?>,
        onReload: @escaping () async -> Void
    ) {
        self.jobs = jobs
        self.log = log
        _selection = selection
        self.onReload = onReload
    }

    public var body: some View {
        HSplitView {
            jobList
                .frame(minWidth: 200, idealWidth: 300, maxWidth: 420)
            logPane
                .frame(minWidth: 280)
        }
        .task { await onReload() }
    }

    private var jobList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(jobs.count) runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await onReload() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Read the history again")
            }
            .padding(8)
            Divider()
            if jobs.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing has run yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(jobs, selection: $selection) { job in
                    JobRow(job: job).tag(job.id)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var logPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $levelFilter) {
                    Text("Everything").tag(String?.none)
                    Text("Warnings").tag(String?.some("warning"))
                    Text("Errors").tag(String?.some("error"))
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 150, idealWidth: 260, maxWidth: 260)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyLog() }
                    .disabled(visible.isEmpty)
                    .help("Copy this log, in full")
            }
            .padding(8)
            Divider()
            if selection == nil {
                Text("Choose a run to see its log.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                Text(log.isEmpty ? "This run recorded no log lines." : "Nothing at this level.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { line in
                            LogLineRow(line: line)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let job = jobs.first(where: { $0.id == selection }), let error = job.errorText {
                Divider()
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visible: [JobLogLine] {
        guard let levelFilter else { return log }
        return log.filter { $0.level == levelFilter }
    }

    private func copyLog() {
        let text = visible
            .map { "[\(Format.timestamp($0.at))] \($0.level.uppercased()): \($0.message)" }
            .joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct JobRow: View {
    let job: JobReport

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.kind.capitalized)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let added = job.bytesAdded {
                Text(Format.bytes(added))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(job.kind), \(job.state), \(subtitle)")
    }

    private var subtitle: String {
        var parts = [Format.age(of: job.finishedAt ?? job.startedAt ?? job.queuedAt)]
        if let started = job.startedAt, let finished = job.finishedAt {
            parts.append(Format.duration(finished.timeIntervalSince(started)))
        }
        if job.resourceUUID != nil { parts.append("one resource") }
        if !job.succeeded, job.isFinished { parts.append(job.state) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch job.state {
        case "succeeded": "checkmark.circle"
        case "failed": "xmark.octagon"
        case "cancelled": "slash.circle"
        case "running": "arrow.triangle.2.circlepath"
        default: "clock"
        }
    }

    private var tint: Color {
        switch job.state {
        case "succeeded": .green
        case "failed": .red
        case "running": .accentColor
        default: .secondary
        }
    }
}

struct LogLineRow: View {
    let line: JobLogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.timestamp(line.at))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(line.message)
                .font(.caption.monospaced())
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.level) at \(Format.timestamp(line.at)). \(line.message)")
    }

    private var tint: Color {
        switch line.level {
        case "error": .red
        case "warning": .orange
        default: .primary
        }
    }
}

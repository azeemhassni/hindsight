import HindsightCore
import SwiftUI

/// Per-server settings.
public struct ServerSettingsView: View {
    @Binding var cadence: Cadence
    @Binding var onlyOnACPower: Bool
    @Binding var retention: RetentionPolicy
    @Binding var bandwidthLimitKiB: Int?
    @Binding var repositoryPath: String
    @Binding var checkRotationWeeks: Int
    @Binding var excludePatterns: [String]

    @State private var cronText = ""
    @State private var newExclude = ""

    public init(
        cadence: Binding<Cadence>,
        onlyOnACPower: Binding<Bool>,
        retention: Binding<RetentionPolicy>,
        bandwidthLimitKiB: Binding<Int?>,
        repositoryPath: Binding<String>,
        checkRotationWeeks: Binding<Int>,
        excludePatterns: Binding<[String]>
    ) {
        _cadence = cadence
        _onlyOnACPower = onlyOnACPower
        _retention = retention
        _bandwidthLimitKiB = bandwidthLimitKiB
        _repositoryPath = repositoryPath
        _checkRotationWeeks = checkRotationWeeks
        _excludePatterns = excludePatterns
    }

    private func reveal(_ path: String) {
        #if canImport(AppKit)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        #endif
    }

    public var body: some View {
        Form {
            Section("Schedule") {
                Picker("Back up", selection: cadenceKind) {
                    Text("Every hour").tag(CadenceKind.hourly)
                    Text("Every few hours").tag(CadenceKind.everyHours)
                    Text("Daily").tag(CadenceKind.daily)
                    Text("Weekly").tag(CadenceKind.weekly)
                    Text("On a schedule I write").tag(CadenceKind.cron)
                }
                if case .cron = cadence {
                    TextField("Cron expression", text: $cronText)
                        .monospaced()
                        .onSubmit { cadence = .cron(cronText) }
                        .help("Five fields: minute, hour, day of month, month, day of week")
                }
                Toggle("Only when plugged in", isOn: $onlyOnACPower)
                    .help("A backup due on battery waits until power is back rather than being skipped")
            }

            Section("Keep") {
                Stepper("Everything for \(retention.keepWithinHours) hours", value: keepWithin, in: 0...168)
                Stepper("\(retention.keepDaily) daily", value: keepDaily, in: 0...365)
                Stepper("\(retention.keepWeekly) weekly", value: keepWeekly, in: 0...104)
                Stepper("\(retention.keepMonthly) monthly", value: keepMonthly, in: 0...120)
                Stepper("\(retention.keepYearly) yearly", value: keepYearly, in: 0...50)
                if keepsNothing {
                    Label(
                        "A policy that keeps nothing would delete every snapshot.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }

            Section("Transfer") {
                Toggle("Limit upload speed", isOn: hasBandwidthLimit)
                if let limit = bandwidthLimitKiB {
                    Stepper(
                        "\(limit) KiB/s",
                        value: Binding(
                            get: { limit },
                            set: { bandwidthLimitKiB = max(1, $0) }
                        ),
                        in: 1...1_000_000,
                        step: 256
                    )
                }
            }

            Section("Where backups are kept") {
                HStack {
                    Text(repositoryPath.isEmpty ? "Not chosen" : repositoryPath)
                        .foregroundStyle(repositoryPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal in Finder") { reveal(repositoryPath) }
                        .disabled(repositoryPath.isEmpty)
                        .help("Show this server's repository in the Finder")
                }
                Text("""
                Chosen when the server was added. Moving a repository means \
                moving its files and telling Hindsight where they went, which \
                it cannot do yet — so this is shown rather than offered.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Integrity") {
                Stepper(
                    "Read and verify everything over \(checkRotationWeeks) weeks",
                    value: $checkRotationWeeks,
                    in: 1...52
                )
                Text("""
                A structural check runs after every prune. Reading all the data \
                is slower, so it is spread across this window.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Never back up") {
                ForEach(excludePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).monospaced()
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            excludePatterns.removeAll { $0 == pattern }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Stop excluding \(pattern); it will be backed up from now on")
                    }
                }
                HStack {
                    TextField("Add a pattern", text: $newExclude)
                        .monospaced()
                    Button("Add") {
                        let trimmed = newExclude.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        excludePatterns.append(trimmed)
                        newExclude = ""
                    }
                    .disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Leave paths matching this pattern out of every backup of this server")
                }
            }
        }
        .formStyle(.grouped)
    }

    enum CadenceKind: Hashable {
        case hourly, everyHours, daily, weekly, cron
    }

    private var cadenceKind: Binding<CadenceKind> {
        Binding(
            get: {
                switch cadence {
                case .hourly: .hourly
                case .everyHours: .everyHours
                case .dailyAt: .daily
                case .weeklyAt: .weekly
                case .cron: .cron
                }
            },
            set: { kind in
                cadence = switch kind {
                case .hourly: .hourly
                case .everyHours: .everyHours(6)
                case .daily: .dailyAt((try? TimeOfDay(hour: 3, minute: 0)) ?? defaultTime)
                case .weekly: .weeklyAt(.sunday, (try? TimeOfDay(hour: 3, minute: 0)) ?? defaultTime)
                case .cron: .cron(cronText.isEmpty ? "0 3 * * *" : cronText)
                }
            }
        )
    }

    private var defaultTime: TimeOfDay {
        // Constructed from literals, so this cannot actually fail.
        try! TimeOfDay(hour: 3, minute: 0)
    }

    private var keepsNothing: Bool {
        retention.keepWithinHours == 0 && retention.keepDaily == 0
            && retention.keepWeekly == 0 && retention.keepMonthly == 0
            && retention.keepYearly == 0
    }

    private var hasBandwidthLimit: Binding<Bool> {
        Binding(
            get: { bandwidthLimitKiB != nil },
            set: { bandwidthLimitKiB = $0 ? 4096 : nil }
        )
    }

    private var keepWithin: Binding<Int> {
        Binding(get: { retention.keepWithinHours }, set: { retention.keepWithinHours = $0 })
    }

    private var keepDaily: Binding<Int> {
        Binding(get: { retention.keepDaily }, set: { retention.keepDaily = $0 })
    }

    private var keepWeekly: Binding<Int> {
        Binding(get: { retention.keepWeekly }, set: { retention.keepWeekly = $0 })
    }

    private var keepMonthly: Binding<Int> {
        Binding(get: { retention.keepMonthly }, set: { retention.keepMonthly = $0 })
    }

    private var keepYearly: Binding<Int> {
        Binding(get: { retention.keepYearly }, set: { retention.keepYearly = $0 })
    }
}

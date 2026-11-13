import Charts
import SwiftUI
import Domain
import DesignSystem
import DemoBackend

public struct DashboardView: View {
    @State private var model: DashboardViewModel
    @Environment(\.scenePhase) private var scenePhase

    public init(backend: any ServerBackend, serverName: String) {
        _model = State(initialValue: DashboardViewModel(backend: backend, serverName: serverName))
    }

    public var body: some View {
        ScrollView {
            if let snapshot = model.snapshot {
                content(snapshot)
                    .padding()
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Status unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
                .padding(.top, 60)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, 120)
            }
        }
        .navigationTitle(model.serverName)
        .refreshable { await model.refresh() }
        // Only the visible screen polls, and only while the app is active.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.runPolling()
        }
    }

    @ViewBuilder
    private func content(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(snapshot)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                if let cpu = snapshot.cpuLoad {
                    MetricCard("CPU", value: Format.percent(cpu), systemImage: "cpu", tint: .blue) {
                        UsageBar(fraction: cpu)
                    }
                }
                if let memory = snapshot.memoryUsage {
                    MetricCard("Memory", value: Format.percent(memory), systemImage: "memorychip", tint: .purple) {
                        VStack(alignment: .leading, spacing: 6) {
                            UsageBar(fraction: memory)
                            if let total = snapshot.memoryTotalBytes {
                                Text("of \(Format.memory(total))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let network = snapshot.network {
                    MetricCard("Network", value: "↓ \(Format.throughput(network.rxBytesPerSecond))", systemImage: "network", tint: .teal) {
                        Text("↑ \(Format.throughput(network.txBytesPerSecond))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let temperature = snapshot.temperature {
                    MetricCard("Temperature", value: Format.temperature(temperature), systemImage: "thermometer.medium", tint: snapshot.temperatureWarning ? .red : .orange) {
                        if snapshot.temperatureWarning {
                            Text("Above threshold").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }

            if model.history.count > 1 {
                CardSection("CPU & Memory") {
                    Chart(model.history) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Load", sample.cpu))
                            .foregroundStyle(by: .value("Metric", String(localized: "CPU")))
                        LineMark(x: .value("Time", sample.date), y: .value("Load", sample.memory))
                            .foregroundStyle(by: .value("Metric", String(localized: "Memory")))
                    }
                    .chartYScale(domain: 0...1)
                    .chartYAxis {
                        AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                        }
                    }
                    .chartForegroundStyleScale([String(localized: "CPU"): Color.blue, String(localized: "Memory"): Color.purple])
                    .frame(height: 160)
                }

                CardSection("Network") {
                    Chart(model.history) { sample in
                        AreaMark(x: .value("Time", sample.date), y: .value("Rate", sample.rx))
                            .foregroundStyle(by: .value("Direction", String(localized: "Download")))
                            .opacity(0.5)
                        AreaMark(x: .value("Time", sample.date), y: .value("Rate", sample.tx))
                            .foregroundStyle(by: .value("Direction", String(localized: "Upload")))
                            .opacity(0.5)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { Text(Format.throughput(value.as(Double.self) ?? 0)) }
                        }
                    }
                    .chartForegroundStyleScale([String(localized: "Download"): Color.teal, String(localized: "Upload"): Color.indigo])
                    .frame(height: 140)
                }
            }

            if !snapshot.volumes.isEmpty {
                CardSection("Volumes") {
                    ForEach(snapshot.volumes) { volume in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(volume.name).font(.subheadline.weight(.medium))
                                if let fs = volume.fileSystem {
                                    Text(fs).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                HealthBadge(volume.status)
                            }
                            UsageBar(fraction: volume.usage, height: 8)
                            Text("\(Format.bytes(volume.usedBytes)) of \(Format.bytes(volume.totalBytes)) used (\(Format.percent(volume.usage)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if volume.id != snapshot.volumes.last?.id { Divider() }
                    }
                }
            }

            if !snapshot.disks.isEmpty {
                CardSection("Drives") {
                    ForEach(snapshot.disks) { disk in
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(Palette.health(disk.status))
                            VStack(alignment: .leading) {
                                Text(disk.name).font(.subheadline)
                                if let model = disk.model {
                                    Text(model).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let temperature = disk.temperature {
                                Text(Format.temperature(temperature))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HealthBadge(disk.status)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func header(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(snapshot.model)
                Text("·")
                Text(snapshot.osVersion)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let uptime = snapshot.uptime {
                Label("Up \(Format.duration(uptime))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DashboardView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
}

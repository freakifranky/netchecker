import SwiftUI
import Network
import Foundation
import Combine
import AppKit

@main
struct NetCheckerApp: App {
    @StateObject private var monitor = NetworkMonitor()
    @StateObject private var speedTester = SpeedTester()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                Label(monitor.statusText, systemImage: monitor.symbolName)
                    .font(.headline)

                Text(monitor.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Network Test")
                        .font(.subheadline.weight(.semibold))

                    Text(speedTester.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !speedTester.lastTestedText.isEmpty {
                        Text("Last tested: \(speedTester.lastTestedText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        metricBlock(
                            title: "Ping",
                            value: speedTester.pingText,
                            color: speedTester.pingColor
                        )

                        metricBlock(
                            title: "Down",
                            value: speedTester.downloadText,
                            color: speedTester.downloadColor
                        )

                        metricBlock(
                            title: "Up",
                            value: speedTester.uploadText,
                            color: speedTester.uploadColor
                        )
                    }
                }

                Button(speedTester.isRunning ? "Testing…" : "Run Network Test") {
                    Task {
                        await speedTester.runAllTests()
                    }
                }
                .disabled(speedTester.isRunning)

                Divider()

                Button("Refresh") {
                    monitor.refreshSnapshot()
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 260)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: monitor.symbolName)
                Text(monitor.shortLabel)
                    .font(.caption2.weight(.semibold))
            }
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private func metricBlock(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

final class NetworkMonitor: ObservableObject {
    @Published var statusText: String = "Checking…"
    @Published var detailText: String = "Waiting for network status"
    @Published var symbolName: String = "ellipsis.circle"
    @Published var shortLabel: String = "…"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.update(from: path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func refreshSnapshot() {
        update(from: monitor.currentPath)
    }

    private func update(from path: NWPath) {
        guard path.status == .satisfied else {
            statusText = "Offline"
            detailText = "No active internet connection"
            symbolName = "wifi.slash"
            shortLabel = "Off"
            return
        }

        if path.usesInterfaceType(.wiredEthernet) {
            statusText = "Ethernet Connected"
            detailText = "Your Mac is currently using a LAN cable"
            symbolName = "cable.connector"
            shortLabel = "LAN"
        } else if path.usesInterfaceType(.wifi) {
            statusText = "Wi-Fi Connected"
            detailText = "Your Mac is currently using Wi-Fi"
            symbolName = "wifi"
            shortLabel = "Wi-Fi"
        } else if path.usesInterfaceType(.cellular) {
            statusText = "Cellular / Tethering"
            detailText = "Connection appears to be cellular"
            symbolName = "antenna.radiowaves.left.and.right"
            shortLabel = "Cell"
        } else {
            statusText = "Network Connected"
            detailText = "Connected through another interface"
            symbolName = "network"
            shortLabel = "Net"
        }
    }
}

@MainActor
final class SpeedTester: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "Not tested yet"
    @Published var pingText = "—"
    @Published var downloadText = "—"
    @Published var uploadText = "—"
    @Published var lastTestedText = ""

    var pingColor: Color { colorForPingText(pingText) }
    var downloadColor: Color { colorForSpeedText(downloadText) }
    var uploadColor: Color { colorForSpeedText(uploadText) }

    func runAllTests() async {
        guard !isRunning else { return }

        isRunning = true
        statusLine = "Running ping, download, and upload tests…"
        pingText = "…"
        downloadText = "…"
        uploadText = "…"

        defer { isRunning = false }

        async let ping = measurePing()
        async let download = measureDownloadMbps()
        async let upload = measureUploadMbps()

        let pingResult = await ping
        let downloadResult = await download
        let uploadResult = await upload

        pingText = pingResult.map { String(format: "%.0f ms", $0) } ?? "Ping Err"
        downloadText = downloadResult.map { String(format: "%.1f Mbps", $0) } ?? "Down Err"
        uploadText = uploadResult.map { String(format: "%.1f Mbps", $0) } ?? "Up Err"

        statusLine = "Finished quick network test"
        lastTestedText = Self.timeFormatter.string(from: Date())
    }

    private func measurePing() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace") else {
            return nil
        }

        var best: Double?

        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()

            do {
                let (_, response) = try await URLSession.shared.data(from: url)

                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

                if best == nil || elapsedMs < best! {
                    best = elapsedMs
                }
            } catch {
                print("Ping test failed:", error.localizedDescription)
            }
        }

        return best
    }

    private func measureDownloadMbps() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000") else {
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let duration = max(CFAbsoluteTimeGetCurrent() - start, 0.001)
            let bits = Double(data.count * 8)
            return bits / duration / 1_000_000
        } catch {
            print("Download test failed:", error.localizedDescription)
            return nil
        }
    }

    private func measureUploadMbps() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else {
            return nil
        }

        let payload = Data(repeating: 0x61, count: 8_000_000)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: payload)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let duration = max(CFAbsoluteTimeGetCurrent() - start, 0.001)
            let bits = Double(payload.count * 8)
            return bits / duration / 1_000_000
        } catch {
            print("Upload test failed:", error.localizedDescription)
            return nil
        }
    }

    private func colorForPingText(_ text: String) -> Color {
        guard let value = extractLeadingDouble(from: text) else { return .secondary }
        if value < 20 { return .green }
        if value < 50 { return .yellow }
        return .red
    }

    private func colorForSpeedText(_ text: String) -> Color {
        guard let value = extractLeadingDouble(from: text) else { return .secondary }
        if value >= 100 { return .green }
        if value >= 25 { return .yellow }
        return .red
    }

    private func extractLeadingDouble(from text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let prefix = normalized.prefix { $0.isNumber || $0 == "." }
        return Double(prefix)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

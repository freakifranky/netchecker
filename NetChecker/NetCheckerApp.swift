import SwiftUI
import Network
import Foundation
import Combine
import AppKit
import CoreWLAN
import CoreLocation
import Security
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("NetChecker should remain active as a menu bar utility")

        // Reading/joining Wi-Fi networks via CoreWLAN only returns real data once
        // Location access is authorized (macOS ties Wi-Fi info to location privacy).
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()

        LocalNotifier.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessInfo.processInfo.enableAutomaticTermination("NetChecker terminating")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // No-op: WiFiController checks the current interface lazily whenever it needs it.
    }
}
@main
struct NetCheckerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @StateObject private var monitor = NetworkMonitor()
    @StateObject private var speedTester = SpeedTester()
    @StateObject private var priorityStore: NetworkPriorityStore
    @StateObject private var healthMonitor: ConnectionHealthMonitor
    @StateObject private var coordinator: FailoverCoordinator

    init() {
        let store = NetworkPriorityStore()
        let health = ConnectionHealthMonitor()
        let coord = FailoverCoordinator(priorityStore: store, healthMonitor: health)

        _priorityStore = StateObject(wrappedValue: store)
        _healthMonitor = StateObject(wrappedValue: health)
        _coordinator = StateObject(wrappedValue: coord)

        health.start()
    }

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

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(healthColor)
                            .frame(width: 8, height: 8)
                        Text(healthText)
                            .font(.subheadline.weight(.semibold))
                    }

                    if !coordinator.lastActionText.isEmpty {
                        Text(coordinator.lastActionText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if healthMonitor.health != .good,
                       !priorityStore.autoSwitchEnabled,
                       let candidate = coordinator.recommendedCandidate {
                        Button(coordinator.isSwitching ? "Switching…" : "Switch to \(candidate.label)") {
                            Task {
                                await coordinator.switchTo(candidate)
                            }
                        }
                        .disabled(coordinator.isSwitching)
                    }

                    Toggle("Auto-switch when connection drops", isOn: $priorityStore.autoSwitchEnabled)
                        .toggleStyle(.switch)
                        .font(.caption)

                    Button("Manage Priority Networks…") {
                        openWindow(id: "priority-networks")
                    }
                    .font(.caption)
                }

                Divider()

                Button("Refresh") {
                    monitor.refreshSnapshot()
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 300)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: monitor.symbolName)
                Text(monitor.shortLabel)
                    .font(.caption2.weight(.semibold))
            }
        }
        .menuBarExtraStyle(.window)

        Window("Priority Networks", id: "priority-networks") {
            PriorityNetworksView(store: priorityStore)
        }
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

    private var healthColor: Color {
        switch healthMonitor.health {
        case .good: return .green
        case .degraded: return .yellow
        case .down: return .red
        }
    }

    private var healthText: String {
        switch healthMonitor.health {
        case .good: return "Connection healthy"
        case .degraded: return "Connection degrading…"
        case .down: return "Connection down"
        }
    }
}

// MARK: - Priority Networks settings window

struct PriorityNetworksView: View {
    @ObservedObject var store: NetworkPriorityStore

    @State private var newLabel = ""
    @State private var newSSID = ""
    @State private var newPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Priority Networks")
                .font(.title2.bold())

            Text("When your connection degrades, NetChecker tries these Wi-Fi networks in order, top to bottom. Ethernet/LAN is always preferred automatically and doesn't need an entry here.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading) {
                            Text(profile.label.isEmpty ? profile.ssid : profile.label)
                                .font(.body.weight(.medium))
                            Text(profile.ssid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            store.removeProfile(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove(perform: store.move)
            }
            .frame(minHeight: 160)

            Divider()

            Text("Add Network")
                .font(.headline)

            HStack {
                TextField("Label (e.g. Reliable Wi-Fi)", text: $newLabel)
                TextField("SSID", text: $newSSID)
            }
            SecureField("Password (leave blank for open networks)", text: $newPassword)

            HStack {
                Spacer()
                Button("Add") {
                    let ssid = newSSID.trimmingCharacters(in: .whitespaces)
                    guard !ssid.isEmpty else { return }
                    let label = newLabel.trimmingCharacters(in: .whitespaces)
                    store.addProfile(ssid: ssid, label: label.isEmpty ? ssid : label, password: newPassword)
                    newLabel = ""
                    newSSID = ""
                    newPassword = ""
                }
                .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            Toggle("Auto-switch when connection degrades", isOn: $store.autoSwitchEnabled)
                .toggleStyle(.switch)

            Text("When off, NetChecker shows a one-click \"Switch Now\" button in the menu bar instead of switching automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 500)
    }
}

// MARK: - Ethernet / Wi-Fi / Offline status

final class NetworkMonitor: ObservableObject {
    @Published var statusText: String = "Checking…"
    @Published var detailText: String = "Waiting for network status"
    @Published var symbolName: String = "ellipsis.circle"
    @Published var shortLabel: String = "…"

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")
    private var observers: [NSObjectProtocol] = []

    init() {
        startMonitor()
        observeSleepWake()
    }

    deinit {
        stopMonitor()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func refreshSnapshot() {
        guard let path = monitor?.currentPath else { return }
        update(from: path)
    }

    private func startMonitor() {
        stopMonitor()

        let newMonitor = NWPathMonitor()
        newMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.update(from: path)
            }
        }

        newMonitor.start(queue: queue)
        monitor = newMonitor

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshSnapshot()
        }
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    private func observeSleepWake() {
        let willSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusText = "Sleeping"
            self?.detailText = "Mac is sleeping"
            self?.symbolName = "moon.zzz"
            self?.shortLabel = "Sleep"
        }

        let didWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusText = "Waking…"
            self?.detailText = "Reconnecting network status"
            self?.symbolName = "arrow.clockwise"
            self?.shortLabel = "Wake"

            self?.startMonitor()
        }

        observers.append(willSleep)
        observers.append(didWake)
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

// MARK: - On-demand speed test

enum SpeedMeasurementError: Error {
    case timeout
    case badResponse
    case network(String)
}

@MainActor
final class SpeedTester: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "Not tested yet"
    @Published var pingText = "—"
    @Published var downloadText = "—"
    @Published var uploadText = "—"
    @Published var lastTestedText = ""

    var pingColor: Color { colorForResultText(pingText) }
    var downloadColor: Color { colorForResultText(downloadText) }
    var uploadColor: Color { colorForResultText(uploadText) }

    // Bounded, dedicated sessions so a bad connection fails fast with a clear
    // "Timeout" message instead of the default 60s hang.
    private let pingSession: URLSession
    private let transferSession: URLSession

    private let downloadBytes = 12_000_000
    private let uploadBytes = 5_000_000

    private static let pingURL = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
    private static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    private static func downloadURL(bytes: Int) -> URL {
        URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")!
    }

    init() {
        let pingConfig = URLSessionConfiguration.ephemeral
        pingConfig.timeoutIntervalForRequest = 4
        pingConfig.timeoutIntervalForResource = 4
        pingConfig.waitsForConnectivity = false
        pingSession = URLSession(configuration: pingConfig)

        let transferConfig = URLSessionConfiguration.ephemeral
        transferConfig.timeoutIntervalForRequest = 20
        transferConfig.timeoutIntervalForResource = 20
        transferConfig.waitsForConnectivity = false
        transferSession = URLSession(configuration: transferConfig)
    }

    func runAllTests() async {
        guard !isRunning else { return }

        isRunning = true
        statusLine = "Testing ping…"
        pingText = "…"
        downloadText = "…"
        uploadText = "…"

        defer { isRunning = false }

        // Measured sequentially (not concurrently) so each result reflects its
        // own isolated transfer instead of three tests fighting for bandwidth.
        let pingResult = await measurePing()
        pingText = format(pingResult, unit: "Ping") { String(format: "%.0f ms", $0) }

        statusLine = "Testing download…"
        let downloadResult = await measureDownloadMbps()
        downloadText = format(downloadResult, unit: "Down") { String(format: "%.1f Mbps", $0) }

        statusLine = "Testing upload…"
        let uploadResult = await measureUploadMbps()
        uploadText = format(uploadResult, unit: "Up") { String(format: "%.1f Mbps", $0) }

        statusLine = "Finished quick network test"
        lastTestedText = Self.timeFormatter.string(from: Date())
    }

    private func format(
        _ result: Result<Double, SpeedMeasurementError>,
        unit: String,
        formatter: (Double) -> String
    ) -> String {
        switch result {
        case .success(let value):
            return formatter(value)
        case .failure(.timeout):
            return "Timeout"
        case .failure:
            return "\(unit) Err"
        }
    }

    private func measurePing() async -> Result<Double, SpeedMeasurementError> {
        var best: Double?
        var lastError: SpeedMeasurementError = .badResponse

        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()

            do {
                let (_, response) = try await pingSession.data(from: Self.pingURL)

                guard let http = response as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode) else {
                    lastError = .badResponse
                    continue
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

                if best == nil || elapsedMs < best! {
                    best = elapsedMs
                }
            } catch let error as URLError where error.code == .timedOut {
                lastError = .timeout
            } catch {
                lastError = .network(error.localizedDescription)
            }
        }

        if let best {
            return .success(best)
        }
        return .failure(lastError)
    }

    private func measureDownloadMbps() async -> Result<Double, SpeedMeasurementError> {
        let start = CFAbsoluteTimeGetCurrent()
        let url = Self.downloadURL(bytes: downloadBytes)

        // Cloudflare's speed-test endpoints reject requests that don't look like
        // they came from https://speed.cloudflare.com itself (no Referer/Origin
        // gets a silent 403), so we set the same headers a browser would send.
        var request = URLRequest(url: url)
        request.setValue("https://speed.cloudflare.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://speed.cloudflare.com", forHTTPHeaderField: "Origin")

        do {
            let (data, response) = try await transferSession.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("NetChecker download test: bad response, status=%d, url=%@", code, url.absoluteString)
                return .failure(.badResponse)
            }

            let duration = max(CFAbsoluteTimeGetCurrent() - start, 0.001)
            let bits = Double(data.count * 8)
            return .success(bits / duration / 1_000_000)
        } catch let error as URLError where error.code == .timedOut {
            NSLog("NetChecker download test: timed out, url=%@", url.absoluteString)
            return .failure(.timeout)
        } catch {
            NSLog("NetChecker download test failed: %@ (code=%d) url=%@", error.localizedDescription, (error as NSError).code, url.absoluteString)
            return .failure(.network(error.localizedDescription))
        }
    }

    private func measureUploadMbps() async -> Result<Double, SpeedMeasurementError> {
        let payload = Data(repeating: 0x61, count: uploadBytes)

        var request = URLRequest(url: Self.uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("https://speed.cloudflare.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://speed.cloudflare.com", forHTTPHeaderField: "Origin")

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let (_, response) = try await transferSession.upload(for: request, from: payload)

            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else {
                return .failure(.badResponse)
            }

            let duration = max(CFAbsoluteTimeGetCurrent() - start, 0.001)
            let bits = Double(payload.count * 8)
            return .success(bits / duration / 1_000_000)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func colorForResultText(_ text: String) -> Color {
        if text == "Timeout" || text.hasSuffix("Err") { return .red }
        guard let value = extractLeadingDouble(from: text) else { return .secondary }

        // Reused for both ping (lower is better) and speed (higher is better)
        // by checking which metric this text came from via its unit ms/Mbps.
        if text.hasSuffix("ms") {
            if value < 20 { return .green }
            if value < 50 { return .yellow }
            return .red
        } else {
            if value >= 100 { return .green }
            if value >= 25 { return .yellow }
            return .red
        }
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

// MARK: - Continuous connection health monitor

enum ConnectionHealth: Equatable {
    case good
    case degraded
    case down
}

@MainActor
final class ConnectionHealthMonitor: ObservableObject {
    @Published private(set) var health: ConnectionHealth = .good
    @Published private(set) var consecutiveFailures = 0

    /// Called on the main actor whenever health moves away from `.good`.
    var onDegraded: (() -> Void)?
    /// Called once when health returns to `.good` after being degraded/down.
    var onRecovered: (() -> Void)?

    private var timer: Timer?
    private let session: URLSession
    private let checkURL = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
    private let checkInterval: TimeInterval = 5
    private let degradedThreshold = 2
    private let downThreshold = 5
    private var isChecking = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func start() {
        stop()

        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { await check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let (_, response) = try await session.data(from: checkURL)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let wasUnhealthy = health != .good
            consecutiveFailures = 0
            health = .good
            if wasUnhealthy { onRecovered?() }
        } catch {
            consecutiveFailures += 1

            if consecutiveFailures >= downThreshold {
                health = .down
            } else if consecutiveFailures >= degradedThreshold {
                health = .degraded
            }

            if health != .good {
                onDegraded?()
            }
        }
    }
}

// MARK: - Priority network storage

struct NetworkProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var ssid: String
    var label: String
}

@MainActor
final class NetworkPriorityStore: ObservableObject {
    @Published var profiles: [NetworkProfile] {
        didSet { persistProfiles() }
    }
    @Published var autoSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: Keys.autoSwitch) }
    }

    private enum Keys {
        static let profiles = "NetChecker.NetworkProfiles"
        static let autoSwitch = "NetChecker.AutoSwitchEnabled"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([NetworkProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        autoSwitchEnabled = UserDefaults.standard.bool(forKey: Keys.autoSwitch)
    }

    func password(for profile: NetworkProfile) -> String? {
        KeychainHelper.readPassword(for: profile.ssid)
    }

    func setPassword(_ password: String, for profile: NetworkProfile) {
        if password.isEmpty {
            KeychainHelper.deletePassword(for: profile.ssid)
        } else {
            KeychainHelper.savePassword(password, for: profile.ssid)
        }
    }

    func addProfile(ssid: String, label: String, password: String) {
        let profile = NetworkProfile(ssid: ssid, label: label)
        profiles.append(profile)
        setPassword(password, for: profile)
    }

    func removeProfile(_ profile: NetworkProfile) {
        profiles.removeAll { $0.id == profile.id }
        KeychainHelper.deletePassword(for: profile.ssid)
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }
}

// MARK: - Keychain-backed password storage

enum KeychainHelper {
    private static let service = "com.netchecker.wifi-passwords"

    static func savePassword(_ password: String, for account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func readPassword(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Wi-Fi join/switch

enum WiFiSwitchError: LocalizedError {
    case noInterface
    case associationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInterface:
            return "No Wi-Fi interface available"
        case .associationFailed(let message):
            return message
        }
    }
}

@MainActor
final class WiFiController {
    private let workQueue = DispatchQueue(label: "NetChecker.WiFiController")

    private var interface: CWInterface? {
        CWWiFiClient.shared().interface()
    }

    var currentSSID: String? {
        interface?.ssid()
    }

    func connect(to profile: NetworkProfile, password: String?) async throws {
        guard let interface else { throw WiFiSwitchError.noInterface }
        let ssid = profile.ssid

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async {
                do {
                    try? interface.setPower(true)

                    let scanned = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
                    guard let network = scanned.first(where: { $0.ssid == ssid }) ?? scanned.first else {
                        throw WiFiSwitchError.associationFailed("\(ssid) not found nearby")
                    }

                    try interface.associate(to: network, password: password)
                    continuation.resume()
                } catch let error as WiFiSwitchError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: WiFiSwitchError.associationFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Failover coordination

@MainActor
final class FailoverCoordinator: ObservableObject {
    @Published var isSwitching = false
    @Published var lastActionText = ""

    private let priorityStore: NetworkPriorityStore
    private let wifiController = WiFiController()
    private var lastAutoSwitchAttempt: Date?
    private let cooldown: TimeInterval = 30
    private var recentlyFailedIDs: Set<UUID> = []

    init(priorityStore: NetworkPriorityStore, healthMonitor: ConnectionHealthMonitor) {
        self.priorityStore = priorityStore

        healthMonitor.onDegraded = { [weak self] in
            self?.handleDegraded()
        }
        healthMonitor.onRecovered = { [weak self] in
            self?.recentlyFailedIDs.removeAll()
        }
    }

    var recommendedCandidate: NetworkProfile? {
        candidate(excluding: recentlyFailedIDs)
    }

    private func candidate(excluding failedIDs: Set<UUID>) -> NetworkProfile? {
        let current = wifiController.currentSSID
        return priorityStore.profiles.first { $0.ssid != current && !failedIDs.contains($0.id) }
            ?? priorityStore.profiles.first { $0.ssid != current }
    }

    private func handleDegraded() {
        guard priorityStore.autoSwitchEnabled, !isSwitching else { return }

        if let last = lastAutoSwitchAttempt, Date().timeIntervalSince(last) < cooldown {
            return
        }

        guard let candidate = candidate(excluding: recentlyFailedIDs) else { return }
        lastAutoSwitchAttempt = Date()

        Task { await switchTo(candidate) }
    }

    func switchTo(_ profile: NetworkProfile) async {
        guard !isSwitching else { return }
        isSwitching = true
        lastActionText = "Switching to \(profile.label)…"

        do {
            let password = priorityStore.password(for: profile)
            try await wifiController.connect(to: profile, password: password)
            recentlyFailedIDs.removeAll()
            lastActionText = "Switched to \(profile.label) at \(Self.timeFormatter.string(from: Date()))"
            LocalNotifier.notify(title: "NetChecker", body: "Switched to \(profile.label)")
        } catch {
            recentlyFailedIDs.insert(profile.id)
            lastActionText = "Couldn't switch to \(profile.label): \(error.localizedDescription)"
            LocalNotifier.notify(title: "NetChecker", body: "Failed to switch to \(profile.label): \(error.localizedDescription)")
        }

        isSwitching = false
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Local notifications

enum LocalNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

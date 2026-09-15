import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected: Bool = false
    @Published var isWiFi: Bool = false
    @Published var interfaceName: String = "Checking…"
    @Published var localIP: String? = nil

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.koro.networkmonitor", qos: .background)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.update(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    private func update(path: NWPath) {
        isConnected = (path.status == .satisfied)
        isWiFi = path.usesInterfaceType(.wifi)

        if path.status != .satisfied {
            interfaceName = "Offline"
            localIP = nil
        } else if path.usesInterfaceType(.wifi) {
            interfaceName = "Wi-Fi"
            localIP = getWiFiIPAddress()
        } else if path.usesInterfaceType(.cellular) {
            interfaceName = "Cellular"
            localIP = nil
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceName = "Ethernet"
            localIP = nil
        } else {
            interfaceName = "Connected"
            localIP = nil
        }
    }

    func refresh() {
        if isWiFi {
            localIP = getWiFiIPAddress()
        }
    }

    private func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if addr.sa_family == UInt8(AF_INET) {
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
            }
        }
        return address
    }
}

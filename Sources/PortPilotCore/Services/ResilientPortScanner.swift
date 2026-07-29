import Foundation

public enum PortScanSource: Sendable, Equatable {
    case lsof
    case libprocFallback
}

public enum PortScanError: Error, Sendable, Equatable {
    case launchFailed
    case nonzeroExit(Int32)
    case unavailable
    case allScannersFailed
}

public enum PortScanResult: Sendable, Equatable {
    case success(entries: [PortEntry], source: PortScanSource)
    case failure(PortScanError)
}

/// Uses the comprehensive lsof scan when available and falls back to libproc
/// only when lsof explicitly fails. A healthy empty lsof result is authoritative.
public struct ResilientPortScanner: PortScanning, Sendable {
    private let primary: any PortScanning
    private let fallback: any PortScanning

    public init(
        primary: any PortScanning = LsofScanner(),
        fallback: any PortScanning = PortScanner()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func scan() async -> PortScanResult {
        switch await primary.scan() {
        case .success(let entries, let source):
            return .success(entries: entries, source: source)
        case .failure:
            break
        }

        switch await fallback.scan() {
        case .success(let entries, let source):
            let listeners = entries.filter {
                $0.protocol == .tcp && $0.state == .listen
            }
            return .success(entries: listeners, source: source)
        case .failure:
            return .failure(.allScannersFailed)
        }
    }
}

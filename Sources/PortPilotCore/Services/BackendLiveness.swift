import Foundation

/// Outcome of checking whether a local backend could accept a connection.
/// Ambiguity is `.unknown`, never `.dead`: a false "dead" teaches users to
/// ignore the finding, while a missed one only delays it.
public enum BackendLiveness: Sendable, Equatable {
    case alive
    case dead
    case unknown
}

import Darwin

/// Quality of service requested for external commands spawned from the
/// current task.
///
/// Periodic background observation (`xcrun xcdevice` / `devicectl` polls)
/// runs at utility QoS so macOS can place those processes, and the
/// CoreDevice work they request over XPC, on efficiency cores and coalesce
/// it with other deferrable work. Foreground checks, deployment and recovery
/// keep the default QoS so user-visible latency does not change.
///
/// The value is task-local: wrap the background workflow in
/// `CommandSpawnQualityOfService.$current.withValue(.utility) { ... }` and
/// every command started synchronously from that task tree inherits it.
enum CommandSpawnQualityOfService: Equatable, Sendable {
    /// Leave the spawned process at the system default QoS.
    case inherited
    /// Clamp the spawned process to utility QoS.
    case utility

    @TaskLocal static var current: CommandSpawnQualityOfService = .inherited

    /// `posix_spawnattr_set_qos_class_np` only accepts utility or
    /// background classes; `nil` means the attribute is left untouched.
    var spawnQOSClass: qos_class_t? {
        switch self {
        case .inherited:
            return nil
        case .utility:
            return QOS_CLASS_UTILITY
        }
    }
}

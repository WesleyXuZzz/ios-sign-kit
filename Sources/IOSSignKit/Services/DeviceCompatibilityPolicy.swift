enum DeviceCompatibilityPolicy {
    static let minimumWirelessPairingMajorVersion = 27

    static var wiredConnectionGuidance: String {
        "iOS \(minimumWirelessPairingMajorVersion) 以下设备需要使用数据线连接 Mac。"
    }
}

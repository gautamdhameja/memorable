import Metal

enum DeviceCompatibility {
    static let unsupportedMessage = "Memorable requires an iPhone with an A14 chip or later."

    static func isSupported(isSimulator: Bool, supportsApple7: Bool) -> Bool {
        isSimulator || supportsApple7
    }

    static var isCurrentDeviceSupported: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return isSupported(
            isSimulator: false,
            supportsApple7: MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true
        )
        #endif
    }
}

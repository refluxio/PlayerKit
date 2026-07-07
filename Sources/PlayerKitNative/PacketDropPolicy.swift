struct PacketDropPolicy {
    let lagThreshold: Double = 0.2

    func shouldDrop(packetPTS: Double, audioTime: Double, isKeyframe: Bool) -> Bool {
        guard !isKeyframe else { return false }
        return packetPTS < audioTime - lagThreshold
    }
}

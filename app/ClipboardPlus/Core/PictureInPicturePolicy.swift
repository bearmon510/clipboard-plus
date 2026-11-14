enum PictureInPicturePolicy {
    static func canStartAutomatically(isEnabled: Bool, isRecording: Bool, automaticallyStarts: Bool) -> Bool {
        isEnabled && isRecording && automaticallyStarts
    }
}

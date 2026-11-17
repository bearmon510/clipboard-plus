import Foundation

enum PCSyncTransportEvent {
    case status(PCSyncController.Status)
    case ready(id: UUID, writeLimit: Int, receiveLimit: Int)
    case packet(Data)
    case writable
    case disconnected
}

/// All callbacks and calls run on MainActor. write hands off exactly one GATT value.
/// stop must detach callbacks; packets from an earlier connection must never reach a new one.
@MainActor
protocol PCSyncTransport: AnyObject {
    var onEvent: ((PCSyncTransportEvent) -> Void)? { get set }
    var canSend: Bool { get }
    func start(remembered: UUID?)
    func stop()
    func write(_ packet: Data)
    func authenticated(_ id: UUID)
    func reconnect(rejectForTenMinutes: Bool)
}

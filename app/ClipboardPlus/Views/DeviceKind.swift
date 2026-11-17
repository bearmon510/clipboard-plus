import UIKit

/// iPhone or iPad, for the words and guidance that differ between them. An iPhone shows one
/// app at a time and has the Action Button; an iPad has Slide Over, Stage Manager and
/// AssistiveTouch as the usual way to start a shortcut.
enum DeviceKind {
    case phone, pad

    @MainActor static var current: DeviceKind {
        UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
    }

    /// The name used in messages, such as "このiPhoneでは使えません".
    var name: String { self == .phone ? "iPhone" : "iPad" }
}

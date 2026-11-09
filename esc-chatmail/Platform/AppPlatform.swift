/// The platform the app is running on, as a value. Pure policies take it as
/// an input instead of branching on `#if`, so their Mac rules run under the
/// iOS test plan too.
enum AppPlatform: Equatable, Sendable {
    case iOS
    case macOS

    static var current: AppPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

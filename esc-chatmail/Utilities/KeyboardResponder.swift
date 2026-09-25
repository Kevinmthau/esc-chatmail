import SwiftUI
import Combine

@MainActor
final class KeyboardResponder: ObservableObject {
    @Published var currentHeight: CGFloat = 0
    @Published var isKeyboardVisible: Bool = false
    /// Duration of the animation the latest `currentHeight` change was
    /// published with. Deliberately not `@Published`: it is set before
    /// `currentHeight` and `isKeyboardVisible` are published, so a change
    /// handler in the same update (the chat transcript's bottom-inset handler)
    /// reads the duration that change arrived with. For inset changes the
    /// keyboard did not cause, it is the last keyboard animation's duration.
    private(set) var animationDuration: TimeInterval = KeyboardResponder.minimumAnimationDuration
    private var cancellables = Set<AnyCancellable>()

    private static let minimumAnimationDuration: TimeInterval = 0.25

    // Shared instance to prevent multiple subscriptions
    static let shared = KeyboardResponder()

    private init() {
        // Use .default queue to avoid main thread congestion
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        let willChangeFrame = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)

        Publishers.Merge3(willShow, willHide, willChangeFrame)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleKeyboardNotification(notification)
            }
            .store(in: &cancellables)
    }

    private func handleKeyboardNotification(_ notification: Notification) {
        // Safely extract userInfo - iOS sometimes sends notifications with nil userInfo
        guard let userInfo = notification.userInfo else {
            // Handle hide notification even without userInfo
            if notification.name == UIResponder.keyboardWillHideNotification {
                self.animationDuration = Self.minimumAnimationDuration
                withAnimation(.easeOut(duration: Self.minimumAnimationDuration)) {
                    self.currentHeight = 0
                    self.isKeyboardVisible = false
                }
            }
            return
        }

        guard let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        // Use default duration if not provided
        let notificationDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? Self.minimumAnimationDuration

        let visibleKeyboardHeight = Self.visibleHeight(for: keyboardFrame)
        let keyboardHeight: CGFloat
        let keyboardIsVisible: Bool
        if notification.name == UIResponder.keyboardWillHideNotification || visibleKeyboardHeight <= 0 {
            keyboardHeight = 0
            keyboardIsVisible = false
        } else {
            keyboardHeight = visibleKeyboardHeight
            keyboardIsVisible = true
        }

        let effectiveAnimationDuration = max(notificationDuration, Self.minimumAnimationDuration)
        self.animationDuration = effectiveAnimationDuration
        // Visibility is published inside the same animation as the height:
        // the chat composer's keyboard offset is gated on it, and publishing
        // it outside made the composer snap to the bottom on every hide while
        // the keyboard (and now the transcript) eased down after it, opening
        // a blank band between the newest message and the composer.
        withAnimation(.easeOut(duration: effectiveAnimationDuration)) {
            self.isKeyboardVisible = keyboardIsVisible
            self.currentHeight = keyboardHeight
        }
    }

    private static func visibleHeight(for keyboardFrame: CGRect) -> CGFloat {
        let screenBottom = UIScreen.main.bounds.maxY
        let visibleHeight = max(0, screenBottom - keyboardFrame.minY)
        return min(keyboardFrame.height, visibleHeight)
    }

    deinit {
        cancellables.removeAll()
    }
}

import SwiftUI
import Combine

@MainActor
final class KeyboardResponder: ObservableObject {
    @Published var currentHeight: CGFloat = 0
    @Published var isKeyboardVisible: Bool = false
    private var cancellables = Set<AnyCancellable>()

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
                withAnimation(.easeOut(duration: 0.25)) {
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
        let animationDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25

        let keyboardHeight: CGFloat
        if notification.name == UIResponder.keyboardWillHideNotification {
            keyboardHeight = 0
            isKeyboardVisible = false
        } else {
            // Don't subtract safe area - we want full keyboard height
            keyboardHeight = keyboardFrame.height
            isKeyboardVisible = true
        }

        withAnimation(.easeOut(duration: max(animationDuration, 0.25))) {
            self.currentHeight = keyboardHeight
        }
    }

    deinit {
        cancellables.removeAll()
    }
}
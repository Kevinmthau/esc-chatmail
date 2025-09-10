import SwiftUI
import Combine

final class KeyboardResponder: ObservableObject {
    @Published var currentHeight: CGFloat = 0
    @Published var isKeyboardVisible: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        let willChangeFrame = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        
        Publishers.Merge3(willShow, willHide, willChangeFrame)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleKeyboardNotification(notification)
            }
            .store(in: &cancellables)
    }
    
    private func handleKeyboardNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let animationDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
            return
        }
        
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
}
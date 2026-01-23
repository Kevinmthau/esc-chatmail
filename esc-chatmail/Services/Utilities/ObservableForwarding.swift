import Combine

/// Extension for forwarding objectWillChange from child ObservableObjects to parent.
///
/// When a ViewModel composes other ObservableObjects, SwiftUI won't automatically
/// detect changes in the nested objects. This extension provides a clean way to
/// forward those changes to the parent.
///
/// Usage:
/// ```swift
/// class ParentViewModel: ObservableObject {
///     private var cancellables = Set<AnyCancellable>()
///     let childService: SomeObservableService
///
///     init() {
///         self.childService = SomeObservableService()
///         forwardChanges(from: childService, storing: &cancellables)
///     }
/// }
/// ```
extension ObservableObject where Self.ObjectWillChangePublisher == ObservableObjectPublisher {

    /// Forwards objectWillChange notifications from a child observable to this object.
    ///
    /// - Parameters:
    ///   - child: The child ObservableObject to observe
    ///   - cancellables: The cancellables set to store the subscription
    func forwardChanges<T: ObservableObject>(
        from child: T,
        storing cancellables: inout Set<AnyCancellable>
    ) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        child.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}

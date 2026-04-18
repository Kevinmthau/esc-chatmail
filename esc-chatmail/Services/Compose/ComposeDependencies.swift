struct ComposeDependencies {
    let storage: StorageDependencies
    let messaging: MessagingDependencies
    let makeRecipientManager: @MainActor () -> RecipientManager
    let makeContactAutocompleteService: @MainActor () -> ContactAutocompleteService
    let makeComposeAttachmentManager: @MainActor () -> ComposeAttachmentManager
}

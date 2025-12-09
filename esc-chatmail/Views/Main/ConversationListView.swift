import SwiftUI
import CoreData
import Contacts

struct ConversationListView: View {
    @FetchRequest private var conversations: FetchedResults<Conversation>

    init() {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "hidden == NO")
        request.fetchBatchSize = 20  // Load conversations in batches for better memory usage
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]  // Prefetch to avoid N+1
        _conversations = FetchRequest(fetchRequest: request)
    }

    enum ConversationFilter: String, CaseIterable {
        case all = "All"
        case contacts = "Contacts"
        case other = "Other"

        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease"
            case .contacts: return "person.crop.circle"
            case .other: return "person.crop.circle.badge.questionmark"
            }
        }
    }

    @StateObject private var syncEngine = SyncEngine.shared
    @StateObject private var contactsService = ContactsService()
    @State private var selectedConversation: Conversation?
    @State private var searchText = ""
    @State private var showingComposer = false
    @State private var showingSettings = false
    @State private var syncTimer: Timer?
    @State private var hasPerformedInitialSync = false
    @State private var currentFilter: ConversationFilter = .all
    @State private var showingFilterMenu = false
    @State private var contactEmailsCache: Set<String> = []
    @State private var isSelecting = false
    @State private var selectedConversationIDs: Set<NSManagedObjectID> = []
    
    var body: some View {
        ZStack {
            List {
                    ForEach(filteredConversations) { conversation in
                        HStack(spacing: 0) {
                            if isSelecting {
                                Button {
                                    toggleSelection(for: conversation)
                                } label: {
                                    Image(systemName: selectedConversationIDs.contains(conversation.objectID) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundColor(selectedConversationIDs.contains(conversation.objectID) ? .blue : .gray)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 16)
                                .padding(.trailing, 8)
                            }

                            if isSelecting {
                                ConversationRowView(conversation: conversation)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleSelection(for: conversation)
                                    }
                            } else {
                                ZStack {
                                    NavigationLink(destination: ChatView(conversation: conversation)) {
                                        EmptyView()
                                    }
                                    .opacity(0)

                                    ConversationRowView(conversation: conversation)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                    }
                    .onDelete(perform: isSelecting ? nil : deleteConversations)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(isSelecting ? "\(selectedConversationIDs.count) Selected" : "Chats")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelecting {
                            Button(selectedConversationIDs.count == filteredConversations.count ? "Deselect All" : "Select All") {
                                selectAll()
                            }
                        } else {
                            Button(action: { showingSettings = true }) {
                                Image(systemName: "gear")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(isSelecting ? "Cancel" : "Select") {
                            withAnimation {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedConversationIDs.removeAll()
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await performSync()
                }
                .sheet(isPresented: $showingComposer) {
                    NewMessageView()
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                    }
                }
                .onAppear {
                    performInitialSync()
                    startPeriodicSync()
                    prefetchPersonData()
                    loadContactsCache()
                    refreshConversationNames()
                }
                .onDisappear {
                    stopPeriodicSync()
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 80)
                }

            // Floating bottom navigation bar
            VStack {
                Spacer()
                if isSelecting && !selectedConversationIDs.isEmpty {
                    // Selection action buttons
                    HStack(spacing: 20) {
                        // Archive button
                        Button(action: { archiveSelectedConversations() }) {
                            HStack(spacing: 10) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 20, weight: .medium))
                                Text("Archive")
                                    .font(.system(size: 17, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.25))
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.5)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.white.opacity(0.6),
                                                Color.white.opacity(0.15)
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                        }

                        // Delete button
                        Button(action: { deleteSelectedConversations() }) {
                            HStack(spacing: 10) {
                                Image(systemName: "trash")
                                    .font(.system(size: 20, weight: .medium))
                                Text("Delete")
                                    .font(.system(size: 17, weight: .medium))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.25))
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.5)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.white.opacity(0.6),
                                                Color.white.opacity(0.15)
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                } else {
                    // Normal navigation bar
                    HStack(spacing: 14) {
                        // Filter button
                        Menu {
                            ForEach(ConversationFilter.allCases, id: \.self) { filter in
                                Button {
                                    currentFilter = filter
                                } label: {
                                    SwiftUI.Label(filter.rawValue, systemImage: filter.icon)
                                }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(UIColor.systemBackground).opacity(0.85))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)

                                Image(systemName: currentFilter.icon)
                                    .font(.system(size: 26, weight: .regular))
                                    .foregroundColor(.primary)
                            }
                            .frame(width: 56, height: 56)
                        }

                        // Search bar with microphone
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 20, weight: .medium))

                            TextField("Search", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 19, weight: .regular))

                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 20, weight: .medium))
                                }
                            }

                            // Microphone button
                            Button(action: { }) {
                                Image(systemName: "mic")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.25))
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .opacity(0.5)
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color.white.opacity(0.6),
                                            Color.white.opacity(0.15)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)

                        // Compose button
                        Button(action: { showingComposer = true }) {
                            ZStack {
                                Circle()
                                    .fill(Color(UIColor.systemBackground).opacity(0.85))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)

                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 26, weight: .regular))
                                    .foregroundColor(.primary)
                            }
                            .frame(width: 56, height: 56)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }
    
    private func performInitialSync() {
        guard !hasPerformedInitialSync else { return }

        // Only mark as performed if we're actually authenticated
        guard AuthSession.shared.isAuthenticated else {
            print("Skipping initial sync - not authenticated")
            return
        }

        hasPerformedInitialSync = true

        Task {
            do {
                // Try incremental sync first, it will fall back to initial sync if needed
                try await syncEngine.performIncrementalSync()
            } catch {
                print("Initial sync error: \(error)")
            }
        }
    }

    private func toggleSelection(for conversation: Conversation) {
        if selectedConversationIDs.contains(conversation.objectID) {
            selectedConversationIDs.remove(conversation.objectID)
        } else {
            selectedConversationIDs.insert(conversation.objectID)
        }
    }

    private func selectAll() {
        if selectedConversationIDs.count == filteredConversations.count {
            selectedConversationIDs.removeAll()
        } else {
            selectedConversationIDs = Set(filteredConversations.map { $0.objectID })
        }
    }

    private func archiveSelectedConversations() {
        let context = CoreDataStack.shared.viewContext
        for objectID in selectedConversationIDs {
            if let conversation = try? context.existingObject(with: objectID) as? Conversation {
                conversation.hidden = true
            }
        }
        CoreDataStack.shared.saveIfNeeded(context: context)
        selectedConversationIDs.removeAll()
        isSelecting = false
    }

    private func deleteSelectedConversations() {
        let context = CoreDataStack.shared.viewContext
        for objectID in selectedConversationIDs {
            if let conversation = try? context.existingObject(with: objectID) as? Conversation {
                context.delete(conversation)
            }
        }
        CoreDataStack.shared.saveIfNeeded(context: context)
        selectedConversationIDs.removeAll()
        isSelecting = false
    }

    private var filteredConversations: [Conversation] {
        var result = Array(conversations)

        // Apply search filter
        if !searchText.isEmpty {
            result = result.filter { conversation in
                conversation.displayName?.localizedCaseInsensitiveContains(searchText) ?? false ||
                conversation.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }

        // Apply contact filter
        switch currentFilter {
        case .all:
            break
        case .contacts:
            result = result.filter { isConversationWithContact($0) }
        case .other:
            result = result.filter { !isConversationWithContact($0) }
        }

        return result
    }

    private func isConversationWithContact(_ conversation: Conversation) -> Bool {
        guard let participants = conversation.participants else { return false }

        for participant in participants {
            if let email = participant.person?.email {
                if contactEmailsCache.contains(email.lowercased()) {
                    return true
                }
            }
        }
        return false
    }
    
    private func refresh() {
        Task {
            await performSync()
        }
    }
    
    private func performSync() async {
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            print("Sync error: \(error)")
        }
    }
    
    private func deleteConversations(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let conversation = filteredConversations[index]

                // Archive in Gmail first
                await archiveConversationInGmail(conversation)

                // Then hide locally
                conversation.hidden = true
            }
            do {
                try CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
            } catch {
                print("Failed to delete conversation: \(error)")
                // Show error to user
            }
        }
    }

    private func archiveConversationInGmail(_ conversation: Conversation) async {
        // Get all message IDs from the conversation
        guard let messages = conversation.value(forKey: "messages") as? Set<Message> else { return }
        let messageIds = messages.compactMap { $0.value(forKey: "id") as? String }

        guard !messageIds.isEmpty else { return }

        do {
            try await GmailAPIClient.shared.archiveMessages(ids: messageIds)
            print("Archived \(messageIds.count) messages in Gmail")
        } catch {
            print("Failed to archive messages in Gmail: \(error)")
            // Continue with local deletion even if Gmail archive fails
        }
    }
    
    private func startPeriodicSync() {
        // Stop any existing timer
        stopPeriodicSync()

        // Start a new timer that fires every 60 seconds (increased from 30)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak syncEngine] _ in
            Task { @MainActor [weak syncEngine] in
                guard let syncEngine = syncEngine else { return }
                // Only sync if not already syncing
                if !syncEngine.isSyncing {
                    print("Performing periodic sync at \(Date())")
                    do {
                        try await syncEngine.performIncrementalSync()
                    } catch {
                        print("Periodic sync error: \(error)")
                    }
                }
            }
        }
    }
    
    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func prefetchPersonData() {
        Task {
            // Prefetch Person data for visible conversations to avoid N+1 queries
            let allEmails = conversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else {
                    return []
                }
                return participants.compactMap { $0.person?.email }
            }
            await PersonCache.shared.prefetch(emails: Array(Set(allEmails)))
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func loadContactsCache() {
        Task.detached {
            // Request access if not authorized
            let authStatus = await MainActor.run { self.contactsService.authorizationStatus }
            if authStatus != .authorized {
                let granted = await self.contactsService.requestAccess()
                if !granted { return }
            }

            // Load all contact emails on background thread
            let contactStore = CNContactStore()
            let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)

            do {
                var emails: Set<String> = []
                try contactStore.enumerateContacts(with: request) { contact, _ in
                    for emailAddress in contact.emailAddresses {
                        emails.insert((emailAddress.value as String).lowercased())
                    }
                }
                let finalEmails = emails
                await MainActor.run {
                    self.contactEmailsCache = finalEmails
                }
            } catch {
                print("Failed to load contacts: \(error)")
            }
        }
    }

    private func refreshConversationNames() {
        // One-time refresh of all conversation display names to use new format
        let hasRefreshedKey = "hasRefreshedConversationNamesV1"
        guard !UserDefaults.standard.bool(forKey: hasRefreshedKey) else { return }

        Task {
            let conversationManager = ConversationManager()
            await conversationManager.updateAllConversationRollups(in: CoreDataStack.shared.viewContext)
            UserDefaults.standard.set(true, forKey: hasRefreshedKey)
            print("Refreshed all conversation names to new format")
        }
    }
}
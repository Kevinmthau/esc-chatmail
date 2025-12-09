import SwiftUI
import CoreData
import Contacts

struct ConversationListView: View {
    @FetchRequest private var conversations: FetchedResults<Conversation>
    @StateObject private var messageActions = MessageActions()

    init() {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "hidden == NO")
        request.fetchBatchSize = 20
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
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
            conversationList
            bottomBar
        }
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                if isSelecting {
                    HStack(spacing: 0) {
                        selectionButton(for: conversation)
                        ConversationRowView(conversation: conversation)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleSelection(for: conversation) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.visible)
                } else {
                    NavigationLink(destination: ChatView(conversation: conversation)) {
                        ConversationRowView(conversation: conversation)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.visible)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            archiveConversation(conversation)
                        } label: {
                            SwiftUI.Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isSelecting ? "\(selectedConversationIDs.count) Selected" : "Chats")
        .toolbar { toolbarContent }
        .refreshable { await performSync() }
        .sheet(isPresented: $showingComposer) { NewMessageView() }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .onAppear {
            performInitialSync()
            startPeriodicSync()
            prefetchPersonData()
            loadContactsCache()
            refreshConversationNames()
        }
        .onDisappear { stopPeriodicSync() }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
    }

    private func selectionButton(for conversation: Conversation) -> some View {
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack {
            Spacer()
            if isSelecting && !selectedConversationIDs.isEmpty {
                selectionActionBar
            } else {
                navigationBar
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 20) {
            archiveButton
            deleteButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var archiveButton: some View {
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
            .background(glassBackground)
        }
    }

    private var deleteButton: some View {
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
            .background(glassBackground)
        }
    }

    private var glassBackground: some View {
        ZStack {
            Color.white.opacity(0.25)
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(0.5)
        }
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

    private var navigationBar: some View {
        HStack(spacing: 14) {
            filterMenuButton
            searchBar
            composeButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var filterMenuButton: some View {
        Menu {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
                Button {
                    currentFilter = filter
                } label: {
                    SwiftUI.Label(filter.rawValue, systemImage: filter.icon)
                }
            }
        } label: {
            circleButton(icon: currentFilter.icon)
        }
    }

    private var searchBar: some View {
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

            Button(action: { }) {
                Image(systemName: "mic")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(glassBackground)
    }

    private var composeButton: some View {
        Button(action: { showingComposer = true }) {
            circleButton(icon: "square.and.pencil")
        }
    }

    private func circleButton(icon: String) -> some View {
        ZStack {
            Circle()
                .fill(Color(UIColor.systemBackground).opacity(0.85))
                .overlay(
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)

            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(.primary)
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - Actions

    private func performInitialSync() {
        guard !hasPerformedInitialSync else { return }
        guard AuthSession.shared.isAuthenticated else {
            print("Skipping initial sync - not authenticated")
            return
        }

        hasPerformedInitialSync = true

        Task {
            do {
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
        let conversationsToArchive = selectedConversationIDs.compactMap { objectID in
            try? context.existingObject(with: objectID) as? Conversation
        }

        // Clear selection immediately for responsive UI
        let count = conversationsToArchive.count
        selectedConversationIDs.removeAll()
        isSelecting = false

        Task { @MainActor in
            for conversation in conversationsToArchive {
                await messageActions.archiveConversation(conversation: conversation)
                conversation.hidden = true
            }
            CoreDataStack.shared.saveIfNeeded(context: context)
            print("Archived \(count) conversations")
        }
    }

    private func archiveConversation(_ conversation: Conversation) {
        Task { @MainActor in
            await messageActions.archiveConversation(conversation: conversation)
            conversation.hidden = true
            CoreDataStack.shared.saveIfNeeded(context: CoreDataStack.shared.viewContext)
        }
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

        if !searchText.isEmpty {
            result = result.filter { conversation in
                conversation.displayName?.localizedCaseInsensitiveContains(searchText) ?? false ||
                conversation.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }

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

    private func performSync() async {
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            print("Sync error: \(error)")
        }
    }

    private func startPeriodicSync() {
        stopPeriodicSync()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak syncEngine] _ in
            Task { @MainActor [weak syncEngine] in
                guard let syncEngine = syncEngine else { return }
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
            let allEmails = conversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else {
                    return []
                }
                return participants.compactMap { $0.person?.email }
            }
            await PersonCache.shared.prefetch(emails: Array(Set(allEmails)))
        }
    }

    private func loadContactsCache() {
        Task.detached {
            let authStatus = await MainActor.run { self.contactsService.authorizationStatus }
            if authStatus != .authorized {
                let granted = await self.contactsService.requestAccess()
                if !granted { return }
            }

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

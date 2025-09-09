//
//  ContentView.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    
    var body: some View {
        Group {
            if authSession.isAuthenticated {
                NavigationStack {
                    ConversationListView()
                }
            } else {
                SignInView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthSession.shared)
}

//
//  ContentView.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var dependencies: Dependencies
    
    var body: some View {
        Group {
            if authSession.canAccessMailbox {
                NavigationStack {
                    ConversationListView(deps: dependencies)
                }
            } else {
                SignInView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(Dependencies.shared)
        .environmentObject(Dependencies.shared.authSession)
}

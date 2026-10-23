//
//  ContentView.swift
//  ShotTracker
//
//  Created by Michael Bedar on 4/11/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        AppRootView()
    }
}

#Preview {
    ContentView()
        .modelContainer(try! MedicationModelContainer.makeSharedContainer(inMemory: true))
        .environment(\.appDependencies, .shared)
}

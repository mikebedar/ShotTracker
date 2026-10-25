//
//  ContentView.swift
//  ShotTracker
//
//  Created by Michael Bedar on 4/11/26.
//

import SwiftUI
import SwiftData
#if DEBUG
import Atelier
#endif

struct ContentView: View {
    var body: some View {
        AppRootView()
            #if DEBUG
            .background {
                if LaunchOptions.holdsToastForCapture { ToastCaptureLifetime() }
            }
            #endif
    }
}

#Preview {
    ContentView()
        .modelContainer(try! MedicationModelContainer.makeSharedContainer(inMemory: true))
        .environment(\.appDependencies, .shared)
}

#if DEBUG
/// Only the screenshot matrix opts into a longer lifetime. The normal interaction tests use production timing.
private struct ToastCaptureLifetime: View {
    @Environment(\.presenter) private var presenter
    var body: some View {
        Color.clear.onChange(of: presenter.toasts.current?.id) { _, id in
            if let id { presenter.toasts.update(id) { $0.duration = 120 } }
        }
    }
}
#endif

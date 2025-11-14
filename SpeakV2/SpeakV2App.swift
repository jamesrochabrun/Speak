//
//  SpeakV2App.swift
//  SpeakV2
//
//  Created by James Rochabrun on 11/9/25.
//

import SwiftUI

@main
struct SpeakV2App: App {
  @State private var settingsManager = SettingsManager()
  @State private var serviceManager = OpenAIServiceManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(settingsManager)
        .environment(serviceManager)
        .onChange(of: settingsManager.apiKey) { _, newValue in
          serviceManager.updateService(apiKey: newValue)
        }
        .onAppear {
          // Initialize service on app launch
          serviceManager.updateService(apiKey: settingsManager.apiKey)
        }
    }
  }
}

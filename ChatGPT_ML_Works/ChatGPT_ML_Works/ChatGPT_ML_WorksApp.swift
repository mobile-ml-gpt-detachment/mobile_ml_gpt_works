//
//  ChatGPT_ML_WorksApp.swift
//  ChatGPT_ML_Works
//
//  Created by Dariy Kordiyak on 20.06.2023.
//

import SwiftUI

@main
struct ChatGPT_ML_WorksApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

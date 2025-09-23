//
//  NovelApp.swift
//  Novel
//
//  Created by Chukwuebuka Ohiomoba on 9/23/25.
//

import SwiftUI
import CoreData

@main
struct NovelApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

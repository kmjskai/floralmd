//
//  FloralMDApp.swift
//  FloralMD
//
//  Created by Yingkai Sun on 2026/8/9.
//

import SwiftUI
import Sparkle

@main
struct FloralMDApp: App {
    @NSApplicationDelegateAdaptor(FloralMDAppDelegate.self) private var appDelegate
#if FLORALMD_PRODUCTION
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
#endif

    init() {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "FloralMDBuildCommit") as? String,
              !commit.isEmpty, !commit.contains("$(") else { return }
        NSLog("FloralMD build commit: %@", commit)
    }

    var body: some Scene {
        WindowGroup("FloralMD", id: FloralMDWindow.workspaceID, for: WorkspaceWindowState.self) { $windowState in
            WorkspaceHostView(windowState: $windowState)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            FloralMDApplicationCommands()
            FloralMDWorkspaceCommands()
#if FLORALMD_PRODUCTION
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updaterController.checkForUpdates(nil)
                }
            }
#endif
            CommandGroup(after: .newItem) {
                if HarnessModuleSelection.current.supportsHarnessModes {
                    Button("切换 Harness 视图") {
                        HarnessModuleSelection.current.toggleCentralMode()
                    }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            FloralMDSettingsView()
        }
        .commands {
            FloralMDApplicationCommands()
        }
    }
}

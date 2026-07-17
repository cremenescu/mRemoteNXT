// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import Sparkle

// Publishes whether the user may currently trigger an update check, so the menu
// item can enable/disable itself. This is Sparkle's official SwiftUI pattern
// (bind to the updater's canCheckForUpdates KVO publisher).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

// Menu item that triggers a Sparkle update check, greying out while a check or
// install is already running. The intermediate view (rather than a bare Button
// in the CommandGroup) is required for the menu item's disabled state to update.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(t("Menu.CheckForUpdates"), action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

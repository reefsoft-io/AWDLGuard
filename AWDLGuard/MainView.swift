import AppKit
import SwiftUI

/// The AWDL Guard window: the App Rules list under a standard toolbar with the title and
/// Add App.
/// Everything about the current state lives in the menu bar panel.
struct MainView: View {
    @Bindable var model: AppModel
    @State private var isAdding = false

    var body: some View {
        RulesList(model: model, isAdding: $isAdding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("AWDL Guard")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add App", systemImage: "plus") { isAdding = true }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddAppSheet(model: model)
            }
            .tint(Theme.accent)
            .frame(minWidth: 560, minHeight: 400)
            // AWDL Guard is a menu bar app; it shows in the Dock and app switcher only while
            // this window is open.
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                model.isRulesWindowOpen = true
            }
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
                model.isRulesWindowOpen = false
            }
    }
}

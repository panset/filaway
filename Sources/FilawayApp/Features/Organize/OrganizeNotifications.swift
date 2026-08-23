import Foundation

/// The cross-feature notifications the organize pipeline posts.
///
/// This file used to hold `AIStatusIndicator`, the toolbar pill M2-09 shipped
/// before Settings existed. M4-02 retired it: `Features/Settings/AIStatusPill`
/// said the same six things in the same six states, and two vocabularies for
/// one status ("AI off" / "Connect AI") is one too many. `ShellView` now hosts
/// the Settings pill through `AIStatusPillHost`.
///
/// The notification names stay here, where the things that post them live.
extension Notification.Name {
    /// Posted when the user asks for the AI settings — the status pill, the
    /// ⌘K panel's "connect your AI" notice, the sidebar prompt.
    ///
    /// `SettingsWindow.observeOpenRequests()` is the one listener; it opens the
    /// Settings scene on its **AI** tab (M4-02).
    static let filawayOpenAISettings = Notification.Name("com.tejaspanse.filaway.openAISettings")
    /// Posted by the Activity menu item; the window scene observes it.
    static let filawayShowActivity = Notification.Name("com.tejaspanse.filaway.showActivity")
}

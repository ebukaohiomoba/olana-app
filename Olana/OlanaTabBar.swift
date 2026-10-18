//
//  OlanaTabBar.swift
//  Olana
//
//  Home, Calendar, Circles, Settings, and Add as the separate trailing glass
//  button. This is the system iOS 26 tab bar, so Liquid Glass, the drag lens,
//  the scroll edge effect and accessibility all come from iOS. Add uses the
//  prominent tab role (iOS 27; search on iOS 26) only for its place and
//  shape: selecting it opens the add sheet and never switches screens. (The custom bar with a raised + in a
//  bump had to rebuild every one of those by hand.)
//

import SwiftUI

enum OlanaTab: Int, CaseIterable {
    case home, calendar, circles, settings
    /// Not a screen: opens the add sheet.
    case add

    var title: String {
        switch self {
        case .home:     return "Home"
        case .calendar: return "Calendar"
        case .circles:  return "Circles"
        case .settings: return "Settings"
        case .add:      return "Add event"
        }
    }

    var symbol: String {
        switch self {
        case .home:     return "house"
        case .calendar: return "calendar"
        case .circles:  return "person.3"
        case .settings: return "gearshape"
        case .add:      return "plus"
        }
    }
}

struct OlanaTabView<Home: View, Calendar: View, Circles: View, Settings: View>: View {
    @Binding var selection: OlanaTab
    var onAdd: () -> Void
    @ViewBuilder var home: () -> Home
    @ViewBuilder var calendar: () -> Calendar
    @ViewBuilder var circles: () -> Circles
    @ViewBuilder var settings: () -> Settings

    @Environment(\.homePalette) private var c

    var body: some View {
        TabView(selection: Binding(get: { selection }, set: { tab in
            if tab == .add {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onAdd()
            } else {
                selection = tab
            }
        })) {
            Tab(OlanaTab.home.title, systemImage: OlanaTab.home.symbol, value: OlanaTab.home) { home() }
            Tab(OlanaTab.calendar.title, systemImage: OlanaTab.calendar.symbol, value: OlanaTab.calendar) { calendar() }
            Tab(OlanaTab.circles.title, systemImage: OlanaTab.circles.symbol, value: OlanaTab.circles) { circles() }
            Tab(OlanaTab.settings.title, systemImage: OlanaTab.settings.symbol, value: OlanaTab.settings) { settings() }
            Tab(OlanaTab.add.title, systemImage: OlanaTab.add.symbol, value: OlanaTab.add, role: Self.addRole) { Color.clear }
        }
        .tint(c.goldText)
    }

    /// iOS 27 sets one tab apart with `.prominent`; a search tab only gets
    /// that by default, and on iOS 27 it stayed in the row as a fifth tab.
    /// iOS 26 has no prominent role and sets the search tab apart.
    private static var addRole: TabRole {
        if #available(iOS 27.0, *) { return .prominent }
        return .search
    }
}

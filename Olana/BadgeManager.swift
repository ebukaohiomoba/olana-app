//
//  BadgeManager.swift
//  Olana
//
//  Badge logic has been stubbed — social models moved to Firestore.
//  Badge awarding via XPManager/UserDefaults will be wired in a future update.
//

import Foundation

// MARK: - Badge Category XP Extension
extension BadgeCategory {
    var xpBonus: Int {
        switch self {
        case .streak:       return 50
        case .productivity: return 30
        case .milestone:    return 100
        case .social:       return 40
        case .achievement:  return 75
        }
    }
}

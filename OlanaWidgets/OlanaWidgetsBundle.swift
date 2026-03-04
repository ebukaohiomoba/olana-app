//
//  OlanaWidgetsBundle.swift
//  OlanaWidgets
//
//  Created by Chukwuebuka Ohiomoba on 3/2/26.
//

import WidgetKit
import SwiftUI

@main
struct OlanaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        OlanaWidgets()
        OlanaWidgetsControl()
        OlanaWidgetsLiveActivity()
    }
}

//
//  Item.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

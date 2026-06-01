//
//  Item.swift
//  PrintParty
//
//  Created by Carson Loyal on 5/31/26.
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

//
//  Item.swift
//  NetChecker
//
//  Created by Franky Gabriel Sanjaya on 28/03/26.
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

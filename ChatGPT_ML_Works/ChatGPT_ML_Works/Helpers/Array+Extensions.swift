//
//  Array+Extensions.swift
//  ChatGPT_ML_Works
//
//  Created by Dariy Kordiyak on 20.06.2023.
//

import Foundation

extension Array where Element == Message {
    var contentCount: Int { map { $0.content }.count }
    var content: String { reduce("") { $0 + $1.content } }
}

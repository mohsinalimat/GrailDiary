// Copyright © 2018 Brian's Brain. All rights reserved.

import UIKit

import TextBundleKit

public protocol EditableDocument: DocumentProtocol {
  typealias StringChange = RangeReplaceableChange<Substring>
  func applyChange(_ change: StringChange)
  var previousError: Swift.Error? { get }
  var text: NSAttributedString { get }
}

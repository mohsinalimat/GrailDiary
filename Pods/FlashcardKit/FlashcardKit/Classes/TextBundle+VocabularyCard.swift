// Copyright © 2018 Brian's Brain. All rights reserved.

import CwlSignal
import Foundation
import TextBundleKit

extension TextBundleDocument {

  var vocabularyAssocationsPublisher: Signal<[VocabularyAssociation]> {
    let signalBridge = text.signal
    let result = signalBridge.map({ (valueDescription) -> [VocabularyAssociation] in
      return VocabularyAssociation.makeAssociations(
        from: valueDescription.value,
        document: self
        ).0
    }).continuous()
    return result
  }

  var vocabularyAssociations: TextBundleKit.Result<[VocabularyAssociation]> {
    return text.currentResult.flatMap({ (text) -> [VocabularyAssociation] in
      return VocabularyAssociation.makeAssociations(from: text, document: self).0
    })
  }

  func setVocabularyAssociations(_ vocabularyAssociations: [VocabularyAssociation]) {
    /// TODO: This overwrites the entire document.
    /// What it *should* do is find the vocabulary table in the document
    /// and just replace that.
    self.text.setValue(vocabularyAssociations.makeTable())
  }

  func appendVocabularyAssociation(_ vocabularyAssociation: VocabularyAssociation) {
    self.text.changeValue { (initialText) -> String in
      var text = initialText
      var (existingAssociations, range) = VocabularyAssociation.makeAssociations(
        from: initialText,
        document: self
      )
      existingAssociations.append(vocabularyAssociation)
      text.replaceSubrange(range, with: existingAssociations.makeTable())
      return text
    }
  }

  func replaceVocabularyAssociation(
    _ vocabularyAssociation: VocabularyAssociation,
    with newAssociation: VocabularyAssociation
  ) {
    self.text.changeValue { (initialText) -> String in
      var text = initialText
      var (existingAssociations, range) = VocabularyAssociation.makeAssociations(
        from: initialText,
        document: self
      )
      if let index = existingAssociations.firstIndex(of: vocabularyAssociation) {
        existingAssociations[index] = newAssociation
      } else {
        existingAssociations.append(vocabularyAssociation)
      }
      text.replaceSubrange(range, with: existingAssociations.makeTable())
      return text
    }
  }
}

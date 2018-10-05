// Copyright © 2018 Brian's Brain. All rights reserved.

import CommonplaceBook
import Foundation
import IGListKit

public final class DocumentDataSource: NSObject {

  public init(stylesheet: Stylesheet) {
    self.stylesheet = stylesheet
  }

  private let stylesheet: Stylesheet
  private var models: [FileMetadataWrapper] = []
  public weak var adapter: ListAdapter?

  public func deleteMetadata(_ fileMetadata: FileMetadataWrapper) {
    if let index = models.firstIndex(where: { $0 == fileMetadata }) {
      try? FileManager.default.removeItem(at: fileMetadata.value.fileURL)
      models.remove(at: index)
      adapter?.performUpdates(animated: true)
    }
  }
}

extension DocumentDataSource: MetadataQueryDelegate {
  public func metadataQuery(_ metadataQuery: MetadataQuery, didFindItems items: [NSMetadataItem]) {
    models = items
      .map { FileMetadataWrapper(metadataItem: $0) }
      .sorted(by: { $0.value.displayName < $1.value.displayName })
    for fileMetadata in models {
      fileMetadata.downloadIfNeeded()
    }
    adapter?.performUpdates(animated: true)
  }
}

extension DocumentDataSource: ListAdapterDataSource {
  public func objects(for listAdapter: ListAdapter) -> [ListDiffable] {
    return models
  }

  public func listAdapter(
    _ listAdapter: ListAdapter,
    sectionControllerFor object: Any
  ) -> ListSectionController {
    return DocumentSectionController(dataSource: self, stylesheet: stylesheet)
  }

  public func emptyView(for listAdapter: ListAdapter) -> UIView? {
    return nil
  }
}

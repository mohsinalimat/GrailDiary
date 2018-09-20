// Copyright © 2018 Brian's Brain. All rights reserved.

import Foundation
import IGListKit
import SwipeCellKit

public final class DocumentSectionController: ListSectionController {
  private let dataSource: DocumentDataSource

  init(dataSource: DocumentDataSource) {
    self.dataSource = dataSource
  }

  private var fileMetadata: FileMetadata!

  public override func cellForItem(at index: Int) -> UICollectionViewCell {
    let cell = collectionContext!.dequeueReusableCell(
      of: DocumentCollectionViewCell.self,
      for: self,
      at: index
    ) as! DocumentCollectionViewCell // swiftlint:disable:this force_cast
    cell.titleLabel.text = fileMetadata.displayName
    cell.delegate = self
    return cell
  }

  public override func sizeForItem(at index: Int) -> CGSize {
    return CGSize(width: collectionContext!.containerSize.width, height: 44)
  }

  public override func didUpdate(to object: Any) {
    self.fileMetadata = (object as! FileMetadata) // swiftlint:disable:this force_cast
  }

  public override func didSelectItem(at index: Int) {
    guard let textEditor = TextEditViewController(fileMetadata: fileMetadata) else { return }
    viewController?.navigationController?.pushViewController(
      textEditor,
      animated: true
    )
  }
}

extension DocumentSectionController: SwipeCollectionViewCellDelegate {
  public func collectionView(
    _ collectionView: UICollectionView,
    editActionsForItemAt indexPath: IndexPath,
    for orientation: SwipeActionsOrientation
  ) -> [SwipeAction]? {
    guard orientation == .right else { return nil }

    let dataSource = self.dataSource
    let fileMetadata = self.fileMetadata
    let deleteAction = SwipeAction(style: .destructive, title: "Delete") { action, _ in
      dataSource.deleteMetadata(fileMetadata!)
      // handle action by updating model with deletion
      action.fulfill(with: .delete)
    }

    // TODO: customize the action appearance
    deleteAction.image = UIImage(named: "delete")
    deleteAction.hidesWhenSelected = true

    return [deleteAction]
  }
}

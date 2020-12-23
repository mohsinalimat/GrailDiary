//  Licensed to the Apache Software Foundation (ASF) under one
//  or more contributor license agreements.  See the NOTICE file
//  distributed with this work for additional information
//  regarding copyright ownership.  The ASF licenses this file
//  to you under the Apache License, Version 2.0 (the
//  "License"); you may not use this file except in compliance
//  with the License.  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing,
//  software distributed under the License is distributed on an
//  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
//  KIND, either express or implied.  See the License for the
//  specific language governing permissions and limitations
//  under the License.

import Combine
import CoreServices
import CoreSpotlight
import Logging
import SnapKit
import UIKit

private extension NSComparisonPredicate {
  convenience init(conformingToUTI uti: String) {
    self.init(
      leftExpression: NSExpression(forKeyPath: "kMDItemContentTypeTree"),
      rightExpression: NSExpression(forConstantValue: uti),
      modifier: .any,
      type: .like,
      options: []
    )
  }
}

extension UIResponder {
  func printResponderChain() {
    var responder: UIResponder? = self
    while let currentResponder = responder {
      print(currentResponder)
      responder = currentResponder.next
    }
  }
}

/// Implements a filterable list of documents in an interactive notebook.
final class DocumentListViewController: UIViewController {
  /// Designated initializer.
  ///
  /// - parameter stylesheet: Controls the styling of UI elements.
  init(
    database: NoteDatabase
  ) {
    self.database = database
    super.init(nibName: nil, bundle: nil)
    // assume we are showing "all notes" initially.
    navigationItem.title = NotebookStructureViewController.StructureIdentifier.allNotes.description
    self.databaseSubscription = database.notesDidChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.updateStudySession()
      }
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public let database: NoteDatabase

  public func setFocus(_ focusedStructure: NotebookStructureViewController.StructureIdentifier) {
    let hashtag: String?
    switch focusedStructure {
    case .allNotes:
      hashtag = nil
      title = "All Notes"
    case .hashtag(let selectedHashtag):
      hashtag = selectedHashtag
      title = selectedHashtag
    }
    dataSource?.filteredHashtag = hashtag
    updateStudySession()
  }

  public var didTapFilesAction: (() -> Void)?
  private var dataSource: DocumentTableController?
  private var databaseSubscription: AnyCancellable?
  private var dueDate: Date {
    get {
      return dataSource?.dueDate ?? Date()
    }
    set {
      dataSource?.dueDate = newValue
      updateStudySession()
    }
  }

  private lazy var advanceTimeButton: UIBarButtonItem = {
    let icon = UIImage(systemName: "clock")
    let button = UIBarButtonItem(
      image: icon,
      style: .plain,
      target: self,
      action: #selector(advanceTime)
    )
    button.accessibilityIdentifier = "advance-time-button"
    return button
  }()

  private lazy var tableView: UITableView = DocumentTableController.makeTableView()

  internal func showPage(with noteIdentifier: Note.Identifier) {
    let note: Note
    do {
      note = try database.note(noteIdentifier: noteIdentifier)
    } catch {
      Logger.shared.error("Unexpected error loading page: \(error)")
      return
    }
    let textEditViewController = TextEditViewController()
    textEditViewController.noteIdentifier = noteIdentifier
    textEditViewController.markdown = note.text ?? ""
    let savingWrapper = SavingTextEditViewController(textEditViewController, noteIdentifier: noteIdentifier, noteStorage: database)
    savingWrapper.setTitleMarkdown(note.metadata.title)
    showDetailViewController(savingWrapper)
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    let dataSource = DocumentTableController(
      tableView: tableView,
      database: database,
      delegate: self
    )
    self.dataSource = dataSource
    view.addSubview(tableView)
    tableView.snp.makeConstraints { make in
      make.top.bottom.left.right.equalToSuperview()
    }
    database.studySession(filter: nil, date: Date()) { [weak self] in
      self?.studySession = $0
    }
    dataSource.performUpdates(animated: false)

    let searchController = UISearchController(searchResultsController: nil)
    searchController.searchResultsUpdater = self
    searchController.searchBar.delegate = self
    searchController.showsSearchResultsController = true
    searchController.searchBar.searchTextField.clearButtonMode = .whileEditing
    searchController.obscuresBackgroundDuringPresentation = false
    navigationItem.searchController = searchController

    /// Update the due date as time passes, app foregrounds, etc.
    updateDueDatePipeline = Just(Date())
      .merge(with: makeForegroundDatePublisher(), Timer.publish(every: .hour, on: .main, in: .common).autoconnect())
      .map { Calendar.current.startOfDay(for: $0.addingTimeInterval(.day)) }
      .assign(to: \.dueDate, on: self)
    navigationController?.setToolbarHidden(false, animated: false)
    if AppDelegate.isUITesting {
      navigationItem.rightBarButtonItem = advanceTimeButton
    }
  }

  private var updateDueDatePipeline: AnyCancellable?

  private func makeForegroundDatePublisher() -> AnyPublisher<Date, Never> {
    NotificationCenter.default
      .publisher(for: UIApplication.willEnterForegroundNotification)
      .map { _ in Date() }
      .eraseToAnyPublisher()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    dataSource?.startObservingDatabase()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    dataSource?.stopObservingDatabase()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    updateToolbar()
  }

  /// Stuff we can study based on the current selected documents.
  private var studySession: StudySession? {
    didSet {
      updateToolbar()
    }
  }

  @objc private func startStudySession() {
    guard let studySession = studySession else { return }
    presentStudySessionViewController(for: studySession)
  }

  @objc private func advanceTime() {
    dueDate = dueDate.addingTimeInterval(7 * .day)
  }

  private func updateStudySession() {
    let currentHashtag = dataSource?.filteredHashtag
    let filter: (Note.Identifier, Note.Metadata) -> Bool = (currentHashtag == nil)
      ? { _, _ in true }
      : { [currentHashtag] _, properties in properties.hashtags.contains(currentHashtag!) }
    let hashtag = currentHashtag
    database.studySession(filter: filter, date: dueDate) {
      guard currentHashtag == hashtag else { return }
      self.studySession = $0
    }
  }

  private func updateToolbar() {
    let countLabel = UILabel(frame: .zero)
    let noteCount = dataSource?.noteCount ?? 0
    countLabel.text = noteCount == 1 ? "1 note" : "\(noteCount) notes"
    countLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    countLabel.sizeToFit()

    let itemsToReview = studySession?.count ?? 0
    let reviewButton = UIBarButtonItem(title: "Review (\(itemsToReview))", style: .plain, target: self, action: #selector(performReview))
    reviewButton.accessibilityIdentifier = "study-button"
    reviewButton.isEnabled = itemsToReview > 0

    let countItem = UIBarButtonItem(customView: countLabel)
    var toolbarItems = [
      reviewButton,
      UIBarButtonItem.flexibleSpace(),
      countItem,
      UIBarButtonItem.flexibleSpace(),
    ]
    if splitViewController?.isCollapsed ?? false {
      toolbarItems.append(AppCommandsButtonItems.newNote())
    }
    self.toolbarItems = toolbarItems
  }

  @objc private func performReview() {
    guard let studySession = studySession else { return }
    presentStudySessionViewController(for: studySession)
  }
}

// MARK: - DocumentTableControllerDelegate

extension DocumentListViewController: DocumentTableControllerDelegate {
  func showDetailViewController(_ detailViewController: UIViewController) {
    if let splitViewController = splitViewController {
      let navigationController = UINavigationController(rootViewController: detailViewController)
      navigationController.navigationBar.barTintColor = .grailBackground
      splitViewController.showDetailViewController(
        navigationController,
        sender: self
      )
    } else if let navigationController = navigationController {
      navigationController.pushViewController(detailViewController, animated: true)
    }
  }

  func presentStudySessionViewController(for studySession: StudySession) {
    let studyVC = StudyViewController(
      studySession: studySession.shuffling().ensuringUniquePromptCollections().limiting(to: 20),
      database: database,
      delegate: self
    )
    studyVC.title = navigationItem.title
    studyVC.modalTransitionStyle = .crossDissolve
    studyVC.modalPresentationStyle = .overFullScreen
    present(
      studyVC,
      animated: true,
      completion: nil
    )
  }

  func documentTableDidDeleteDocument(with noteIdentifier: Note.Identifier) {
    guard
      let splitViewController = self.splitViewController,
      splitViewController.viewControllers.count > 1,
      let navigationController = splitViewController.viewControllers.last as? UINavigationController,
      let detailViewController = navigationController.viewControllers.first as? SavingTextEditViewController
    else {
      return
    }
    if detailViewController.noteIdentifier == noteIdentifier {
      // We just deleted the current page. Show a blank document.
      showDetailViewController(
        TextEditViewController.makeBlankDocument(
          database: database,
          currentHashtag: dataSource?.filteredHashtag,
          autoFirstResponder: false
        )
      )
    }
  }

  func showAlert(_ alertMessage: String) {
    let alert = UIAlertController(title: "Oops", message: alertMessage, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    present(alert, animated: true, completion: nil)
  }

  func documentTableController(_ documentTableController: DocumentTableController, didUpdateWithNoteCount noteCount: Int) {
    updateToolbar()
  }
}

// MARK: - Search

/// Everything needed for search.
/// This is a bunch of little protocols and it's clearer to declare conformance in a single extension.
extension DocumentListViewController: UISearchResultsUpdating, UISearchBarDelegate {
  func updateSearchResults(for searchController: UISearchController) {
    guard searchController.isActive else {
      dataSource?.filteredPageIdentifiers = nil
      updateStudySession()
      return
    }
    let pattern = searchController.searchBar.text ?? ""
    Logger.shared.info("Issuing query: \(pattern)")
    do {
      let allIdentifiers = try database.search(for: pattern)
      dataSource?.filteredPageIdentifiers = Set(allIdentifiers)
    } catch {
      Logger.shared.error("Error issuing full text query: \(error)")
    }
  }

  func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
    Logger.shared.info("searchBarTextDidEndEditing")
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    dataSource?.filteredPageIdentifiers = nil
  }
}

extension DocumentListViewController: StudyViewControllerDelegate {
  func studyViewController(
    _ studyViewController: StudyViewController,
    didFinishSession session: StudySession
  ) {
    do {
      try database.updateStudySessionResults(session, on: dueDate, buryRelatedPrompts: true)
      updateStudySession()
    } catch {
      Logger.shared.error("Unexpected error recording study session results: \(error)")
    }
  }

  func studyViewControllerDidCancel(_ studyViewController: StudyViewController) {
    dismiss(animated: true, completion: nil)
  }
}

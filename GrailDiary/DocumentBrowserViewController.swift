// Copyright (c) 2018-2021  Brian Dewey. Covered by the Apache 2.0 license.

import Logging
import UIKit
import UniformTypeIdentifiers

@objc protocol AppCommands {
  func makeNewNote()
  func openNewFile()
}

enum AppCommandsButtonItems {
  static func documentBrowser() -> UIBarButtonItem {
    let button = UIBarButtonItem(title: "Open", style: .plain, target: nil, action: #selector(AppCommands.openNewFile))
    button.accessibilityIdentifier = "open-files"
    return button
  }

  static func newNote() -> UIBarButtonItem {
    let button = UIBarButtonItem(barButtonSystemItem: .compose, target: nil, action: #selector(AppCommands.makeNewNote))
    button.accessibilityIdentifier = "new-document"
    return button
  }
}

/// Our custom DocumentBrowserViewController that knows how to open new files, etc.
final class DocumentBrowserViewController: UIDocumentBrowserViewController {
  override init(forOpening contentTypes: [UTType]?) {
    super.init(forOpening: contentTypes)
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    delegate = self
    restorationIdentifier = "DocumentBrowserViewController"
  }

  private var topLevelViewController: NotebookViewController?

  private let documentURLKey = "documentURLBookmarkData"

  private enum ActivityKey {
    static let openDocumentActivity = "org.brians-brain.GrailDiary.OpenNotebook"
    static let documentURL = "org.brians-brain.GrailDiary.OpenNotebook.URL"
  }

  /// Makes a NSUserActivity that captures the current state of this UI.
  func makeUserActivity() -> NSUserActivity? {
    guard let notebookViewController = topLevelViewController else {
      return nil
    }
    let url = notebookViewController.fileURL
    do {
      let urlData = try url.bookmarkData()
      let activity = NSUserActivity(activityType: ActivityKey.openDocumentActivity)
      activity.title = "View Notebook"
      activity.addUserInfoEntries(from: [ActivityKey.documentURL: urlData])
      topLevelViewController?.updateUserActivity(activity)
      return activity
    } catch {
      Logger.shared.error("Unexpected error creating user activity: \(error)")
      return nil
    }
  }

  func configure(with userActivity: NSUserActivity) {
    guard let urlData = userActivity.userInfo?[ActivityKey.documentURL] as? Data else {
      Logger.shared.error("In DocumentBrowserViewController.configure(with:), but cannot get URL from activity")
      return
    }
    do {
      var isStale = false
      let url = try URL(resolvingBookmarkData: urlData, bookmarkDataIsStale: &isStale)
      try openDocument(at: url, createWelcomeContent: false, animated: false) { [self] _ in
        self.topLevelViewController?.configure(with: userActivity)
      }
    } catch {
      Logger.shared.error("Error opening saved document: \(error)")
    }
  }
}

extension DocumentBrowserViewController: UIDocumentBrowserViewControllerDelegate {
  /// Opens a document.
  /// - parameter url: The URL of the document to open
  /// - parameter controller: The view controller from which to present the DocumentListViewController
  func openDocument(
    at url: URL,
    createWelcomeContent: Bool,
    animated: Bool,
    completion: ((Bool) -> Void)? = nil
  ) throws {
    Logger.shared.info("Opening document at \"\(url.path)\"")
    let database: NoteDatabase
    if url.pathExtension == "grail" {
      database = NoteDatabase(fileURL: url)
    } else {
      throw CocoaError(CocoaError.fileReadUnsupportedScheme)
    }
    Logger.shared.info("Using document at \(database.fileURL)")
    let viewController = NotebookViewController(database: database)
    viewController.modalPresentationStyle = .fullScreen
    viewController.modalTransitionStyle = .crossDissolve
    viewController.view.tintColor = .systemOrange
    present(viewController, animated: animated, completion: nil)
    database.open(completionHandler: { success in
      let properties: [String: String] = [
        "Success": success.description,
//        "documentState": String(describing: noteArchiveDocument.documentState),
//        "previousError": noteArchiveDocument.previousError?.localizedDescription ?? "nil",
      ]
      Logger.shared.info("In open completion handler. \(properties)")
      if success, !AppDelegate.isUITesting {
        if createWelcomeContent {
          database.tryCreatingWelcomeContent()
        }
      }
      completion?(success)
    })
    topLevelViewController = viewController
  }

  func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
    guard let url = documentURLs.first else {
      return
    }
    try? openDocument(at: url, createWelcomeContent: false, animated: true)
  }

  func documentBrowser(
    _ controller: UIDocumentBrowserViewController,
    didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void
  ) {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
      Logger.shared.info("Created directory at \(directoryURL)")
    } catch {
      Logger.shared.error("Unable to create temporary directory at \(directoryURL.path): \(error)")
      importHandler(nil, .none)
    }
    let url = directoryURL.appendingPathComponent("diary").appendingPathExtension("grail")
    let document = NoteDatabase(fileURL: url)
    Logger.shared.info("Attempting to create a document at \(url.path)")
    document.open { openSuccess in
      guard openSuccess else {
        Logger.shared.error("Could not open document")
        importHandler(nil, .none)
        return
      }
      document.tryCreatingWelcomeContent()
      document.save(to: url, for: .forCreating) { saveSuccess in
        if saveSuccess {
          importHandler(url, .move)
        } else {
          Logger.shared.error("Could not create document")
          importHandler(nil, .none)
        }
      }
    }
  }

  func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
    Logger.shared.info("Imported document to \(destinationURL)")
    try? openDocument(at: destinationURL, createWelcomeContent: false, animated: true)
  }

  func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Swift.Error?) {
    Logger.shared.error("Unable to import document at \(documentURL): \(error?.localizedDescription ?? "nil")")
  }
}

// MARK: - AppCommands

//
// Implements system-wide menu responses
extension DocumentBrowserViewController: AppCommands {
  @objc func openNewFile() {
    topLevelViewController = nil
    dismiss(animated: true, completion: nil)
  }

  @objc func makeNewNote() {
    topLevelViewController?.makeNewNote()
  }
}

// MARK: - NoteDatabase

private extension NoteDatabase {
  /// Tries to create a "weclome" note in the database. Logs errors.
  func tryCreatingWelcomeContent() {
    if let welcomeURL = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
      do {
        let welcomeMarkdown = try String(contentsOf: welcomeURL)
        let welcomeNote = Note(markdown: welcomeMarkdown)
        _ = try createNote(welcomeNote)
      } catch {
        Logger.shared.error("Unexpected error creating welcome content: \(error)")
      }
    }
  }
}

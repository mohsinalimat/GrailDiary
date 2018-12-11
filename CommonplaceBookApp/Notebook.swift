// Copyright © 2018 Brian's Brain. All rights reserved.

import CocoaLumberjack
import CommonplaceBook
import CwlSignal
import FlashcardKit
import Foundation
import IGListKit
import MiniMarkdown
import TextBundleKit

extension Tag {
  public static let fromCache = Tag(rawValue: "fromCache")
  public static let placeholder = Tag(rawValue: "placeholder")
  public static let truth = Tag(rawValue: "truth")
}

public protocol NotebookPageChangeListener: AnyObject {

  /// Properties in the index changed.
  func notebookPagesDidChange(_ index: Notebook)

  /// study metadata changed
  func notebookStudyMetadataChanged(_ notebook: Notebook)
}

/// A "notebook" is a directory that contains individual "pages" (either plain text files
/// or textbundle bundles). Each page may contain "cards", which are individual facts to review
/// using a spaced repetition algorithm.
public final class Notebook {

  public static let cachedPropertiesName = "properties.json"

  /// Designated initializer.
  ///
  /// - parameter parsingrules: The rules used to parse the text content of documents.
  /// - parameter metadataProvider: Where we store all of the pages of the notebook (+ metadata)
  public init(
    parsingRules: ParsingRules,
    metadataProvider: FileMetadataProvider
  ) {
    self.parsingRules = parsingRules
    self.metadataProvider = metadataProvider

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.userInfo[.markdownParsingRules] = parsingRules
    self.decoder = decoder
  }

  @discardableResult
  public func loadCachedProperties() -> Notebook {
    if let propertiesDocument = metadataProvider.editableDocument(
      for: FileMetadata(fileName: Notebook.cachedPropertiesName)
    ) {
      openMetadocuments[.notebookProperties] = propertiesDocument
      monitorPropertiesDocument(propertiesDocument)
    } else {
      DDLogError("Unexpected error: Unable to load cached properties. Continuing without cache.")
    }
    return self
  }

  /// Bag of arbitrary data keyed off of MetadocumentKey
  internal var internalNotebookData = [MetadocumentKey: Any]()

  /// Set up the code to monitor for changes to cached properties on disk, plus propagate
  /// cached changes to disk.
  private func monitorPropertiesDocument(_ propertiesDocument: EditableDocument) {
    propertiesDocument.open { (success) in
      // TODO: Handle the failure case here.
      precondition(success)
      self.endpoints += propertiesDocument.textSignal.subscribeValues({ (taggedString) in
        // If we've already loaded information into memory, don't clobber it.
        if self.pages.isEmpty {
          let pages = self.pagesDictionary(from: taggedString.value, tag: .fromCache)
          DDLogInfo("Loaded information about \(pages.count) page(s) from cache")
          self.pages = pages
        }
        self.conditionForKey(.notebookProperties).condition = true
      })
    }
  }

  @discardableResult
  public func monitorMetadataProvider() -> Notebook {
    DispatchQueue.main.async(
      when: conditionForKey(.notebookProperties)
    ) {
      self.metadataProvider.delegate = self
      self.processMetadata(self.metadataProvider.fileMetadata)
    }
    return self
  }

  deinit {
    openMetadocuments.forEach { $0.1.close() }
  }

  private var metadocumentLoadedConditions = [MetadocumentKey: Condition]()

  internal func conditionForKey(_ key: MetadocumentKey) -> Condition {
    if let condition = metadocumentLoadedConditions[key] {
      return condition
    } else {
      let condition = Condition()
      metadocumentLoadedConditions[key] = condition
      return condition
    }
  }
  
  internal var endpoints: [Cancellable] = []

  /// Decoder for this notebook. It depend on the parsing rules, which is why it is an instance
  /// property and not a class property.
  public let decoder: JSONDecoder

  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  /// The rules used to parse the text content of documents.
  public let parsingRules: ParsingRules

  public let metadataProvider: FileMetadataProvider

  /// Provides access to the container URL
  public var containerURL: URL { return metadataProvider.container }

  public struct MetadocumentKey: RawRepresentable, Hashable {
    public init(rawValue: String) {
      self.rawValue = rawValue
      MetadocumentKey.allKnownKeys.insert(rawValue)
    }

    public let rawValue: String

    public static let notebookProperties = MetadocumentKey(rawValue: "properties.json")

    public static var allKnownKeys = Set<String>()
  }

  /// Where we cache our properties.
  internal var openMetadocuments = [MetadocumentKey: EditableDocument]()

  public func pagesDictionary(
    from seralizedString: String,
    tag: Tag
  ) -> [String: Tagged<DocumentProperties>] {
    guard let data = seralizedString.data(using: .utf8) else { return [:] }
    do {
      let properties = try decoder.decode(
        [DocumentProperties].self,
        from: data
      )
      return properties.reduce(
        into: [String: Tagged<DocumentProperties>]()
      ) { (dictionary, properties) in
        dictionary[properties.fileMetadata.fileName] = Tagged(
          tag: tag,
          value: properties
        )
      }
    } catch {
      DDLogError("Error parsing cached properties: \(error)")
    }
    return [:]
  }

  private func saveProperties() {
    guard let propertiesDocument = openMetadocuments[.notebookProperties] else { return }
    // TODO: Move serialization off main thread?
    do {
      let properties = pages.values.map { $0.value }
      let data = try Notebook.encoder.encode(properties)
      propertiesDocument.applyTaggedModification(tag: .memory) { (_) -> String in
        return String(data: data, encoding: .utf8) ?? ""
      }
    } catch {
      DDLogError("\(error)")
    }
  }

  /// The pages of the notebook.
  public internal(set) var pages: [String: Tagged<DocumentProperties>] = [:] {
    didSet {
      notifyListeners()
    }
  }

  private struct WeakListener {
    weak var listener: NotebookPageChangeListener?
    init(_ listener: NotebookPageChangeListener) { self.listener = listener }
  }
  private var listeners: [WeakListener] = []

  /// Registers an NotebookPageChangeListener.
  ///
  /// - parameter listener: The listener to register. It will get notifications of changes.
  public func addListener(_ listener: NotebookPageChangeListener) {
    listeners.append(WeakListener(listener))
  }

  /// Removes the NotebookPageChangeListener. It will no longer get notifications of changes.
  ///
  /// - parameter listener: The listener to unregister.
  public func removeListener(_ listener: NotebookPageChangeListener) {
    guard let index = listeners.firstIndex(where: { $0.listener === listener }) else { return }
    listeners.remove(at: index)
  }

  /// Tell all registered list adapters to perform updates.
  private func notifyListeners() {
    for adapter in listeners {
      adapter.listener?.notebookPagesDidChange(self)
    }
  }

  private func processMetadata(_ metadata: [FileMetadata]) {
    let models = metadata
      .filter { !MetadocumentKey.allKnownKeys.contains($0.fileName) }
    deletePages(except: models)
    let allUpdated = DispatchGroup()
    var loadedProperties = 0
    for fileMetadata in models {
      allUpdated.enter()
      fileMetadata.downloadIfNeeded(in: containerURL)
      updateProperties(for: fileMetadata) { (didLoadNewProperties) in
        if didLoadNewProperties { loadedProperties += 1 }
        allUpdated.leave()
      }
    }
    allUpdated.notify(queue: DispatchQueue.main) {
      if loadedProperties > 0 { self.saveProperties() }
    }
  }

  /// Removes items "pages" except those referenced by `metadata`
  /// - note: This does *not* save cached properties. That is the responsibility of the caller.
  /// TODO: I should redesign the page manipulation APIs to be more foolproof.
  ///       A method that takes a block, executes it, then notifies listeners & saves properties
  ///       afterwards. That will batch saves as well as listener notifications.
  ///       This implementation will send one notification per key.
  private func deletePages(except metadata: [FileMetadata]) {
    let existingKeys = Set<String>(pages.keys)
    let metadataProviderKeys = Set<String>(metadata.map({ $0.fileName }))
    let keysToDelete = existingKeys.subtracting(metadataProviderKeys)
    for key in keysToDelete {
      pages[key] = nil
    }
  }

  private func updateProperties(
    for fileMetadata: FileMetadata,
    completion: @escaping (Bool) -> Void
  ) {
    let name = fileMetadata.fileName

    let newProperties = pages[name].updatingFileMetadata(fileMetadata)
    pages[name] = newProperties
    if newProperties.tag == .truth {
      DDLogInfo("NOTEBOOK: Keeping cached properties for \(name).")
      completion(false)
      return
    }

    DDLogInfo("NOTEBOOK: Loading new properties for \(name)")
    DocumentProperties.loadProperties(
      from: fileMetadata,
      in: metadataProvider,
      parsingRules: parsingRules
    ) { (result) in
      switch result {
      case .success(let properties):
        self.pages[name] = Tagged(tag: .truth, value: properties)
        DDLogInfo("Successfully loaded: " + properties.title)
      case .failure(let error):
        self.pages[name] = nil
        DDLogError("Error loading properties: \(error)")
      }
      completion(true)
    }
  }

  /// Deletes a document and its properties.
  public func deleteFileMetadata(_ fileMetadata: FileMetadata) {
    try? metadataProvider.delete(fileMetadata)
    self.pages[fileMetadata.fileName] = nil
    saveProperties()
  }
}

/// Any IGListKit ListAdapter can be a NotebookPageChangeListener.
extension ListAdapter: NotebookPageChangeListener {
  public func notebookPagesDidChange(_ index: Notebook) {
    performUpdates(animated: true)
  }

  public func notebookStudyMetadataChanged(_ notebook: Notebook) {
    // NOTHING
  }
}

extension Optional where Wrapped == Tagged<DocumentProperties> {

  /// Given an optional Tagged<DocumentProperties>, computes a new Tagged<DocumentProperties>
  /// for given metadata.
  ///
  /// If the receiver has no value, then the result is a Tag.placeholder
  /// with empty DocumentProperties.
  ///
  /// If the receiver has a value, then the result updates the DocumentProperties with the new
  /// FileMetadata (to handle things that change like uploading status). It will be marked
  /// with Tag.truth (meaning no need to re-parse) if the timestamps are close.
  fileprivate func updatingFileMetadata(
    _ fileMetadata: FileMetadata
  ) -> Tagged<DocumentProperties> {
    switch self {
    case .none:
      return Tagged(
        tag: .placeholder,
        value: DocumentProperties(fileMetadata: fileMetadata, nodes: [])
      )
    case .some(let wrapped):
      return Tagged(
        tag: wrapped.value.fileMetadata.closeInTime(to: fileMetadata) ? .truth : .placeholder,
        value: wrapped.value.updatingFileMetadata(fileMetadata)
      )
    }
  }
}

extension FileMetadata {

  /// Determine if two FileMetadata records are "close enough" that we don't have to
  /// re-load and re-parse the file contents.
  fileprivate func closeInTime(to other: FileMetadata) -> Bool {
    return abs(contentChangeDate.timeIntervalSince(other.contentChangeDate)) < 1
  }
}

extension Notebook: FileMetadataProviderDelegate {
  public func fileMetadataProvider(
    _ provider: FileMetadataProvider,
    didUpdate metadata: [FileMetadata]
  ) {
    processMetadata(metadata)
  }
}
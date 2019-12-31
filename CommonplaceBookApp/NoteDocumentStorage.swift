// Copyright © 2017-present Brian's Brain. All rights reserved.

import CocoaLumberjack
import Combine
import CoreSpotlight
import DataCompression
import MiniMarkdown
import MobileCoreServices
import UIKit

/// Concrete implementation of NoteStorage that keeps data in a file system package with a compressed TextSnippetArchive and compressed study log.
public final class NoteDocumentStorage: UIDocument, NoteStorage {
  /// Designated initializer.
  /// - parameter fileURL: The URL of the document
  /// - parameter parsingRules: Defines how to parse markdown inside the notes
  public init(fileURL url: URL, parsingRules: ParsingRules) {
    self.parsingRules = parsingRules
    self.noteArchive = NoteArchive(parsingRules: parsingRules)
    super.init(fileURL: url)
  }

  /// How to parse Markdown in the snippets
  public let parsingRules: ParsingRules

  /// Top-level FileWrapper for our contents
  private var topLevelFileWrapper = FileWrapper(directoryWithFileWrappers: [:])

  /// FileWrapper for image assets.
  private var assetsFileWrapper: FileWrapper {
    if let fileWrapper = topLevelFileWrapper.fileWrappers![BundleWrapperKey.assets] {
      return fileWrapper
    }
    let fileWrapper = FileWrapper(directoryWithFileWrappers: [:])
    fileWrapper.preferredFilename = BundleWrapperKey.assets
    topLevelFileWrapper.addFileWrapper(fileWrapper)
    return fileWrapper
  }

  /// The actual document contents.
  internal var noteArchive: NoteArchive

  /// Protects noteArchive.
  internal let noteArchiveQueue = DispatchQueue(label: "org.brians-brain.note-archive-document")

  /// Holds the outcome of every study session.
  public internal(set) var studyLog = StudyLog()

  /// If there is every an I/O error, this contains it.
  public private(set) var previousError: Error?

  private let challengeTemplateCache = NSCache<NSString, ChallengeTemplate>()

  /// Accessor for the page properties.
  public var noteProperties: [NoteIdentifier: NoteProperties] {
    return noteArchiveQueue.sync {
      noteArchive.noteProperties
    }
  }

  public let notePropertiesDidChange = PassthroughSubject<Void, Never>()

  public func currentTextContents(for noteIdentifier: NoteIdentifier) throws -> String {
    assert(Thread.isMainThread)
    return try noteArchiveQueue.sync {
      try noteArchive.currentText(for: noteIdentifier)
    }
  }

  public func changeTextContents(for noteIdentifier: NoteIdentifier, to text: String) {
    assert(Thread.isMainThread)
    noteArchiveQueue.sync {
      noteArchive.updateText(for: noteIdentifier, to: text, contentChangeTime: Date())
    }
    invalidateSavedSnippets()
    schedulePropertyBatchUpdate()
  }

  public func setNoteProperties(for noteIdentifier: NoteIdentifier, to noteProperties: NoteProperties) {
    assert(Thread.isMainThread)
    noteArchiveQueue.sync {
      noteArchive.updatePageProperties(for: noteIdentifier, to: noteProperties)
    }
    invalidateSavedSnippets()
  }

  private var propertyBatchUpdateTimer: Timer?

  private func schedulePropertyBatchUpdate() {
    guard propertyBatchUpdateTimer == nil else { return }
    propertyBatchUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
      let count = self.noteArchiveQueue.sync {
        self.noteArchive.batchUpdatePageProperties()
      }
      // swiftlint:disable:next empty_count
      if count > 0 {
        self.notePropertiesDidChange.send()
      }
      self.propertyBatchUpdateTimer = nil
    })
  }

  public func deleteNote(noteIdentifier: NoteIdentifier) throws {
    noteArchiveQueue.sync {
      noteArchive.removeNote(for: noteIdentifier)
    }
    CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [noteIdentifier.rawValue], completionHandler: nil)
    invalidateSavedSnippets()
    notePropertiesDidChange.send()
  }

  private enum BundleWrapperKey {
    static let assets = "assets"
    static let compressedSnippets = "text.snippets.gz"
    static let compressedStudyLog = "study.log.gz"
    static let snippets = "text.snippets"
    static let studyLog = "study.log"
  }

  /// Deserialize `noteArchive` from `contents`
  /// - precondition: `contents` is a directory FileWrapper with a "text.snippets" regular file
  /// - throws: NSError in the NoteArchiveDocument domain on any error
  public override func load(fromContents contents: Any, ofType typeName: String?) throws {
    guard let wrapper = contents as? FileWrapper, wrapper.isDirectory else {
      throw error(for: .unexpectedContentType)
    }
    topLevelFileWrapper = wrapper
    studyLog = NoteDocumentStorage.loadStudyLog(from: wrapper)
    do {
      let noteArchive = try NoteDocumentStorage.loadNoteArchive(
        from: wrapper,
        parsingRules: parsingRules
      )
      noteArchive.addToSpotlight()
      let noteProperties = noteArchive.noteProperties
      noteArchiveQueue.sync { self.noteArchive = noteArchive }
      DDLogInfo("Loaded \(noteProperties.count) pages")
      notePropertiesDidChange.send()
    } catch {
      throw wrapError(code: .textSnippetsDeserializeError, innerError: error)
    }
  }

  /// Serialize `noteArchive` to `topLevelFileWrapper` and return `topLevelFileWrapper` for saving
  public override func contents(forType typeName: String) throws -> Any {
    precondition(topLevelFileWrapper.isDirectory)
    if topLevelFileWrapper.fileWrappers![BundleWrapperKey.compressedSnippets] == nil {
      topLevelFileWrapper.addFileWrapper(try compressedSnippetsFileWrapper())
    }
    if topLevelFileWrapper.fileWrappers![BundleWrapperKey.compressedStudyLog] == nil {
      guard let compressedLog = studyLog.description.data(using: .utf8)!.gzip() else {
        throw error(for: .couldNotCompressStudyLog)
      }
      let logWrapper = FileWrapper(
        regularFileWithContents: compressedLog
      )
      logWrapper.preferredFilename = BundleWrapperKey.compressedStudyLog
      topLevelFileWrapper.addFileWrapper(logWrapper)
    }
    purgeUnneededWrappers(from: topLevelFileWrapper)
    DDLogInfo("Saving: \(topLevelFileWrapper.fileWrappers!.keys)")
    return topLevelFileWrapper
  }

  public override func handleError(_ error: Error, userInteractionPermitted: Bool) {
    previousError = error
    super.handleError(error, userInteractionPermitted: userInteractionPermitted)
  }

  /// Lets the UIDocument infrastructure know we have content to save, and also
  /// discards our in-memory representation of the snippet file wrapper.
  internal func invalidateSavedSnippets() {
    if let compressedWrapper = topLevelFileWrapper.fileWrappers![BundleWrapperKey.compressedSnippets] {
      topLevelFileWrapper.removeFileWrapper(compressedWrapper)
    }
    updateChangeCount(.done)
  }

  internal func invalidateSavedStudyLog() {
    if let archiveWrapper = topLevelFileWrapper.fileWrappers![BundleWrapperKey.compressedStudyLog] {
      topLevelFileWrapper.removeFileWrapper(archiveWrapper)
    }
    updateChangeCount(.done)
  }

  /// Gets data contained in a file wrapper
  /// - parameter fileWrapperKey: A path to a named file wrapper. E.g., "assets/image.png"
  /// - returns: The data contained in that wrapper if it exists, nil otherwise.
  public func data<S: StringProtocol>(for fileWrapperKey: S) -> Data? {
    var currentWrapper = topLevelFileWrapper
    for pathComponent in fileWrapperKey.split(separator: "/") {
      guard let nextWrapper = currentWrapper.fileWrappers?[String(pathComponent)] else {
        return nil
      }
      currentWrapper = nextWrapper
    }
    return currentWrapper.regularFileContents
  }
}

/// Load / save support
private extension NoteDocumentStorage {
  static func loadNoteArchive(
    from wrapper: FileWrapper,
    parsingRules: ParsingRules
  ) throws -> NoteArchive {
    let maybeData = wrapper.fileWrappers?[BundleWrapperKey.compressedSnippets]?.regularFileContents?.gunzip()
      ?? wrapper.fileWrappers?[BundleWrapperKey.snippets]?.regularFileContents
    guard
      let data = maybeData,
      let text = String(data: data, encoding: .utf8) else {
      // Is this an error? Or expected for a new document?
      return NoteArchive(parsingRules: parsingRules)
    }
    return try NoteArchive(parsingRules: parsingRules, textSerialization: text)
  }

  static func loadStudyLog(from wrapper: FileWrapper) -> StudyLog {
    let maybeData = wrapper.fileWrappers?[BundleWrapperKey.compressedStudyLog]?.regularFileContents?.gunzip()
      ?? wrapper.fileWrappers?[BundleWrapperKey.studyLog]?.regularFileContents
    guard let logData = maybeData,
      let logText = String(data: logData, encoding: .utf8),
      let studyLog = StudyLog(logText) else {
      return StudyLog()
    }
    return studyLog
  }

  func compressedSnippetsFileWrapper() throws -> FileWrapper {
    let text = try noteArchiveQueue.sync { () -> String in
      try noteArchive.archivePageManifestVersion(timestamp: Date())
      return noteArchive.textSerialized()
    }
    guard let compressed = text.data(using: .utf8)!.gzip() else {
      throw error(for: .couldNotCompressArchive)
    }
    let compressedWrapper = FileWrapper(regularFileWithContents: compressed)
    compressedWrapper.preferredFilename = BundleWrapperKey.compressedSnippets
    return compressedWrapper
  }

  /// Removes unneeded data file wrappers from `directoryWrapper`
  func purgeUnneededWrappers(from directoryWrapper: FileWrapper) {
    precondition(directoryWrapper.isDirectory)
    let unneededKeys = Set(directoryWrapper.fileWrappers!.keys)
      .subtracting([BundleWrapperKey.compressedStudyLog, BundleWrapperKey.compressedSnippets, BundleWrapperKey.assets])
    for key in unneededKeys {
      directoryWrapper.removeFileWrapper(directoryWrapper.fileWrappers![key]!)
    }
  }
}

/// Making NSErrors...
public extension NoteDocumentStorage {
  static let errorDomain = "NoteArchiveDocument"

  enum ErrorCode: String, CaseIterable {
    case couldNotCompressArchive = "Could not compress text.snippets"
    case couldNotCompressStudyLog = "Could not compress study.log"
    case textSnippetsDeserializeError = "Unexpected error deserializing text.snippets"
    case unexpectedContentType = "Unexpected file content type"
  }

  /// Constructs an NSError based upon the the `ErrorCode` string value & index.
  func error(for code: ErrorCode) -> NSError {
    let index = ErrorCode.allCases.firstIndex(of: code)!
    return NSError(
      domain: NoteDocumentStorage.errorDomain,
      code: index,
      userInfo: [NSLocalizedDescriptionKey: code.rawValue]
    )
  }

  /// Constructs an NSError that wraps another arbitrary error.
  func wrapError(code: ErrorCode, innerError: Error) -> NSError {
    let index = ErrorCode.allCases.firstIndex(of: code)!
    return NSError(
      domain: NoteDocumentStorage.errorDomain,
      code: index,
      userInfo: [
        NSLocalizedDescriptionKey: code.rawValue,
        "innerError": innerError,
      ]
    )
  }
}

// MARK: - Study sessions

public extension NoteDocumentStorage {
  /// Blocking function that gets the study session. Safe to call from background threads. Only `internal` and not `private` so tests can call it.
  // TODO: On debug builds, this is *really* slow. Worth optimizing.
  func synchronousStudySession(
    filter: ((NoteIdentifier, NoteProperties) -> Bool)? = nil,
    date: Date = Date()
  ) -> StudySession {
    let filter = filter ?? { _, _ in true }
    let suppressionDates = studyLog.identifierSuppressionDates()
    let properties = noteArchiveQueue.sync { noteArchive.noteProperties }
    return properties
      .filter { filter($0.key, $0.value) }
      .map { (name, reviewProperties) -> StudySession in
        let challengeTemplates = reviewProperties.cardTemplates
          .compactMap(challengeTemplate(for:))
        // TODO: Filter down to eligible cards
        let eligibleCards = challengeTemplates.cards
          .filter { challenge -> Bool in
            guard let suppressionDate = suppressionDates[challenge.challengeIdentifier] else {
              return true
            }
            return date >= suppressionDate
          }
        return StudySession(
          eligibleCards,
          properties: CardDocumentProperties(
            documentName: name,
            attributionMarkdown: reviewProperties.title,
            parsingRules: self.parsingRules
          )
        )
      }
      .reduce(into: StudySession()) { $0 += $1 }
  }

  func challengeTemplate(for keyString: String) -> ChallengeTemplate? {
    guard let key = ChallengeTemplateArchiveKey(keyString) else {
      DDLogError("Expected a challenge key: \(keyString)")
      return nil
    }
    if let cachedTemplate = challengeTemplateCache.object(forKey: keyString as NSString) {
      return cachedTemplate
    }
    do {
      let template = try noteArchive.challengeTemplate(for: key)
      template.templateIdentifier = key.digest
      challengeTemplateCache.setObject(template, forKey: keyString as NSString)
      return template
    } catch {
      DDLogError("Unexpected error getting challenge template: \(error)")
      return nil
    }
  }

  /// Inserts a challenge template into the archive.
  func insertChallengeTemplate(
    _ challengeTemplate: ChallengeTemplate
  ) throws -> ChallengeTemplateArchiveKey {
    // TODO: Use the cache
    return try noteArchiveQueue.sync {
      try noteArchive.insertChallengeTemplate(challengeTemplate)
    }
  }

  func insertNoteProperties(_ noteProperties: NoteProperties) -> NoteIdentifier {
    invalidateSavedSnippets()
    return noteArchiveQueue.sync {
      noteArchive.insertNoteProperties(noteProperties)
    }
  }

  /// Update the notebook with the result of a study session.
  ///
  /// - parameter studySession: The completed study session.
  /// - parameter date: The date the study session took place.
  func updateStudySessionResults(_ studySession: StudySession, on date: Date = Date()) {
    studyLog.updateStudySessionResults(studySession, on: date)
    invalidateSavedStudyLog()
    notePropertiesDidChange.send()
  }
}

// MARK: - MarkdownEditingTextViewImageStoring

extension NoteDocumentStorage: MarkdownEditingTextViewImageStoring {
  public func markdownEditingTextView(
    _ textView: MarkdownEditingTextView,
    store imageData: Data,
    suffix: String
  ) -> String {
    return storeAssetData(imageData, typeHint: suffix)
  }
}

// MARK: - Images

extension NoteDocumentStorage {
  /// Stores asset data into the document.
  /// - parameter data: The asset data to store
  /// - parameter typeHint: A hint about the data type, e.g., "jpeg" -- will be used for the data key
  /// - returns: A key that can be used to get the data later.
  public func storeAssetData(_ data: Data, typeHint: String) -> String {
    let key = "\(data.sha1Digest()).\(typeHint)"
    let assetsWrapper = assetsFileWrapper
    if assetsWrapper.fileWrappers![key] == nil {
      let imageFileWrapper = FileWrapper(regularFileWithContents: data)
      imageFileWrapper.preferredFilename = key
      assetsWrapper.addFileWrapper(imageFileWrapper)
    }
    return "\(BundleWrapperKey.assets)/\(key)"
  }

  /// Adds a renderer tthat knows how to render images using assets from this document
  /// - parameter renderers: The collection of render functions
  public func addImageRenderer(to renderers: inout [NodeType: RenderedMarkdown.RenderFunction]) {
    renderers[.image] = { [weak self] node, attributes in
      guard
        let self = self,
        let imageNode = node as? Image,
        let data = self.data(for: imageNode.url),
        let image = data.image(maxSize: 200)
      else {
        return NSAttributedString(string: node.markdown, attributes: attributes)
      }
      let attachment = NSTextAttachment()
      attachment.image = image
      return NSAttributedString(attachment: attachment)
    }
  }
}

private extension Data {
  func image(maxSize: CGFloat) -> UIImage? {
    guard let imageSource = CGImageSourceCreateWithData(self as CFData, nil) else {
      return nil
    }
    let options: [NSString: NSObject] = [
      kCGImageSourceThumbnailMaxPixelSize: maxSize as NSObject,
      kCGImageSourceCreateThumbnailFromImageAlways: true as NSObject,
      kCGImageSourceCreateThumbnailWithTransform: true as NSObject,
    ]
    let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary?).flatMap { UIImage(cgImage: $0) }
    return image
  }
}

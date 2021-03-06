// Copyright (c) 2018-2021  Brian Dewey. Covered by the Apache 2.0 license.

import Foundation

public extension SyntaxTreeNodeType {
  static let blankLine: SyntaxTreeNodeType = "blank_line"
  static let blockquote: SyntaxTreeNodeType = "blockquote"
  static let code: SyntaxTreeNodeType = "code"
  static let delimiter: SyntaxTreeNodeType = "delimiter"
  static let document: SyntaxTreeNodeType = "document"
  static let emphasis: SyntaxTreeNodeType = "emphasis"
  static let hashtag: SyntaxTreeNodeType = "hashtag"
  static let header: SyntaxTreeNodeType = "header"
  static let image: SyntaxTreeNodeType = "image"
  static let list: SyntaxTreeNodeType = "list"
  static let listItem: SyntaxTreeNodeType = "list_item"
  static let paragraph: SyntaxTreeNodeType = "paragraph"
  static let softTab: SyntaxTreeNodeType = "tab"
  static let strongEmphasis: SyntaxTreeNodeType = "strong_emphasis"
  static let text: SyntaxTreeNodeType = "text"
  static let unorderedListOpening: SyntaxTreeNodeType = "unordered_list_opening"
  static let orderedListNumber: SyntaxTreeNodeType = "ordered_list_number"
  static let orderedListTerminator: SyntaxTreeNodeType = "ordered_list_terminator"
  static let cloze: SyntaxTreeNodeType = "cloze"
  static let clozeHint: SyntaxTreeNodeType = "cloze_hint"
  static let clozeAnswer: SyntaxTreeNodeType = "cloze_answer"
  static let questionAndAnswer: SyntaxTreeNodeType = "question_and_answer"
  static let qnaQuestion: SyntaxTreeNodeType = "qna_question"
  static let qnaAnswer: SyntaxTreeNodeType = "qna_answer"
  static let qnaDelimiter: SyntaxTreeNodeType = "qna_delimiter"
}

public enum ListType {
  case ordered
  case unordered
}

public enum ListTypeKey: SyntaxTreeNodePropertyKey {
  public typealias Value = ListType

  public static let key = "list_type"
}

public final class MiniMarkdownGrammar: PackratGrammar {
  public init(trace: Bool = false) {
    if trace {
      self.start = start.trace()
    }
  }

  /// Singleton for convenience.
  public static let shared = MiniMarkdownGrammar()

  public private(set) lazy var start: ParsingRule = block
    .repeating(0...)
    .wrapping(in: .document)

  lazy var block = Choice(
    blankLine,
    header,
    unorderedList,
    orderedList,
    blockquote,
    questionAndAnswer,
    paragraph
  ).memoize()

  lazy var blankLine = InOrder(
    whitespace.repeating(0...),
    newline
  ).as(.blankLine).memoize()

  lazy var header = InOrder(
    Characters(["#"]).repeating(1 ..< 7).as(.delimiter),
    softTab,
    InOrder(
      InOrder(newline.assertInverse(), dot).repeating(0...),
      Choice(newline, dot.assertInverse())
    ).as(.text)
  ).wrapping(in: .header).memoize()

  /// My custom addition to markdown for handling questions-and-answers
  lazy var questionAndAnswer = InOrder(
    InOrder(Literal("Q:").as(.text), Literal(" ").as(.softTab)).wrapping(in: .qnaDelimiter),
    singleLineStyledText.wrapping(in: .qnaQuestion),
    InOrder(Literal("\nA:").as(.text), Literal(" ").as(.softTab)).wrapping(in: .qnaDelimiter),
    singleLineStyledText.wrapping(in: .qnaAnswer),
    paragraphTermination.zeroOrOne().wrapping(in: .text)
  ).wrapping(in: .questionAndAnswer).memoize()

  lazy var paragraph = InOrder(
    nonDelimitedHashtag.zeroOrOne(),
    styledText,
    paragraphTermination.zeroOrOne().wrapping(in: .text)
  ).wrapping(in: .paragraph).memoize()

  lazy var paragraphTermination = InOrder(
    newline,
    Choice(Characters(["#", "\n"]).assert(), unorderedListOpening.assert(), orderedListOpening.assert(), blockquoteOpening.assert())
  )

  // MARK: - Inline styles

  func delimitedText(_ nodeType: SyntaxTreeNodeType, delimiter: ParsingRule) -> ParsingRule {
    let rightFlanking = InOrder(nonWhitespace.as(.text), delimiter.as(.delimiter)).memoize()
    return InOrder(
      delimiter.as(.delimiter),
      nonWhitespace.assert(),
      InOrder(
        rightFlanking.assertInverse(),
        paragraphTermination.assertInverse(),
        dot
      ).repeating(0...).as(.text),
      rightFlanking
    ).wrapping(in: nodeType).memoize()
  }

  lazy var bold = delimitedText(.strongEmphasis, delimiter: Literal("**"))
  lazy var italic = delimitedText(.emphasis, delimiter: Literal("*"))
  lazy var underlineItalic = delimitedText(.emphasis, delimiter: Literal("_"))
  lazy var code = delimitedText(.code, delimiter: Literal("`"))
  lazy var hashtag = InOrder(
    whitespace.as(.text),
    nonDelimitedHashtag
  )
  lazy var nonDelimitedHashtag = InOrder(Literal("#"), nonWhitespace.repeating(1...)).as(.hashtag).memoize()

  lazy var image = InOrder(
    Literal("!["),
    Characters(CharacterSet(charactersIn: "\n]").inverted).repeating(0...),
    Literal("]("),
    Characters(CharacterSet(charactersIn: "\n)").inverted).repeating(0...),
    Literal(")")
  ).as(.image).memoize()

  lazy var cloze = InOrder(
    Literal("?[").as(.delimiter),
    Characters(CharacterSet(charactersIn: "\n]").inverted).repeating(0...).as(.clozeHint),
    Literal("](").as(.delimiter),
    Characters(CharacterSet(charactersIn: "\n)").inverted).repeating(0...).as(.clozeAnswer),
    Literal(")").as(.delimiter)
  ).wrapping(in: .cloze).memoize()

  lazy var textStyles = Choice(
    bold,
    italic,
    underlineItalic,
    code,
    hashtag,
    image,
    cloze
  ).memoize()

  lazy var styledText = InOrder(
    InOrder(paragraphTermination.assertInverse(), textStyles.assertInverse(), dot).repeating(0...).as(.text),
    textStyles.repeating(0...)
  ).repeating(0...).memoize()

  /// A variant of `styledText` that terminates on the first newline
  lazy var singleLineStyledText = InOrder(
    InOrder(Characters(["\n"]).assertInverse(), textStyles.assertInverse(), dot).repeating(0...).as(.text),
    textStyles.repeating(0...)
  ).repeating(0...).memoize()

  // MARK: - Character primitives

  let dot = DotRule()
  let newline = Characters(["\n"])
  let whitespace = Characters(.whitespaces)
  let nonWhitespace = Characters(CharacterSet.whitespacesAndNewlines.inverted)
  let digit = Characters(.decimalDigits)
  /// One or more whitespace characters that should be interpreted as a single delimiater.
  let softTab = Characters(.whitespaces).repeating(1...).as(.softTab)

  // MARK: - Simple block quotes

  // TODO: Support single block quotes that span multiple lines, and block quotes with multiple
  //       paragraphs.

  lazy var blockquoteOpening = InOrder(
    whitespace.repeating(0 ... 3).as(.text),
    Characters([">"]).as(.text),
    whitespace.zeroOrOne().as(.softTab)
  ).wrapping(in: .delimiter).memoize()

  lazy var blockquote = InOrder(
    blockquoteOpening,
    paragraph
  ).as(.blockquote).memoize()

  // MARK: - Lists

  // https://spec.commonmark.org/0.28/#list-items

  lazy var unorderedListOpening = InOrder(
    whitespace.repeating(0...).as(.text).zeroOrOne(),
    Characters(["*", "-", "+"]).as(.unorderedListOpening),
    whitespace.repeating(1 ... 4).as(.softTab)
  ).wrapping(in: .delimiter).memoize()

  lazy var orderedListOpening = InOrder(
    whitespace.repeating(0...).as(.text).zeroOrOne(),
    digit.repeating(1 ... 9).as(.orderedListNumber),
    Characters([".", ")"]).as(.orderedListTerminator),
    whitespace.repeating(1 ... 4).as(.softTab)
  ).wrapping(in: .delimiter).memoize()

  func list(type: ListType, openingDelimiter: ParsingRule) -> ParsingRule {
    let listItem = InOrder(
      openingDelimiter,
      paragraph
    ).wrapping(in: .listItem).memoize()
    return InOrder(
      listItem,
      blankLine.repeating(0...)
    ).repeating(1...).wrapping(in: .list).property(key: ListTypeKey.self, value: type).memoize()
  }

  lazy var unorderedList = list(type: .unordered, openingDelimiter: unorderedListOpening)
  lazy var orderedList = list(type: .ordered, openingDelimiter: orderedListOpening)
}

import Foundation
import UIKit
import SwiftUI

struct MarkdownTextHelper {
    /// Strips inline Markdown characters and returns clean text for G2P/TTS and layout length matching.
    static func cleanText(from markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }
        if let attrString = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(attrString.characters)
        }
        return markdown
    }

    /// Converts Markdown text into an NSAttributedString with base font, design, line spacing, and opacity,
    /// while preserving bold and italic symbolic traits.
    static func attributedString(
        from markdown: String,
        fontSize: Double,
        fontDesign: ReaderFontDesign,
        lineSpacing: Double,
        textOpacity: Double
    ) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }

        let baseFont = UIFont.systemFont(ofSize: CGFloat(fontSize))
        let designDescriptor = baseFont.fontDescriptor.withDesign(fontDesign.uiFontDesign) ?? baseFont.fontDescriptor
        let baseColor = UIColor.label.withAlphaComponent(CGFloat(textOpacity))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(lineSpacing)

        guard let attrString = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            let defaultFont = UIFont(descriptor: designDescriptor, size: CGFloat(fontSize))
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: baseColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
        }

        let result = NSMutableAttributedString()

        for run in attrString.runs {
            let runText = String(attrString[run.range].characters)
            guard !runText.isEmpty else { continue }

            var symbolicTraits = UIFontDescriptor.SymbolicTraits()
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    symbolicTraits.insert(.traitBold)
                }
                if intent.contains(.emphasized) {
                    symbolicTraits.insert(.traitItalic)
                }
            }

            var fontDescriptor = designDescriptor
            if !symbolicTraits.isEmpty, let traitsDesc = fontDescriptor.withSymbolicTraits(symbolicTraits) {
                fontDescriptor = traitsDesc
            }

            let runFont = UIFont(descriptor: fontDescriptor, size: CGFloat(fontSize))
            let runAttributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraphStyle
            ]

            result.append(NSAttributedString(string: runText, attributes: runAttributes))
        }

        return result
    }
}

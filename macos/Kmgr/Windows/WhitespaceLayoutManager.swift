import AppKit

/// TextKit 1 layout manager that paints quiet, editor-style whitespace marks
/// after the document's ordinary glyphs. The marks never enter the text
/// storage, so they cannot affect editing, selection, copy/paste, undo, or
/// accessibility.
final class WhitespaceLayoutManager: NSLayoutManager {
    var whitespaceVisualizationEnabled = false {
        didSet {
            guard oldValue != whitespaceVisualizationEnabled else { return }
            guard let textStorage else { return }
            // This marks presentation dirty without generating glyphs or
            // scanning the document. Actual drawing remains glyph-range bound.
            invalidateDisplay(
                forCharacterRange: NSRange(location: 0, length: textStorage.length)
            )
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawWhitespaceMarkers(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawWhitespaceMarkers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard whitespaceVisualizationEnabled,
            glyphsToShow.location != NSNotFound,
            glyphsToShow.length > 0,
            let textStorage
        else { return }

        let source = textStorage.mutableString
        let documentLength = source.length
        let markerRange = NSRange(
            location: glyphsToShow.location,
            length: glyphsToShow.length
        )
        guard markerRange.length > 0 else { return }

        let dotPath = NSBezierPath()
        let guidePath = NSBezierPath()
        var controlPictures: [(String, NSPoint, NSFont)] = []
        guidePath.lineWidth = 0.75
        guidePath.lineCapStyle = .round
        guidePath.lineJoinStyle = .round

        for glyphIndex in markerRange.location..<NSMaxRange(markerRange) {
            let characterIndex = characterIndexForGlyph(at: glyphIndex)
            guard characterIndex < documentLength else { continue }

            let character = source.character(at: characterIndex)
            guard character == 0x20
                || character == 0x09
                || character == 0x0A
                || character == 0x0D
                || character == 0xA0
                || character <= 0x1F
                || character == 0x7F
            else { continue }

            let lineRect = lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let location = location(forGlyphAt: glyphIndex)
            let x = origin.x + lineRect.minX + location.x
            let centerY = origin.y + lineRect.minY + lineRect.height * 0.52
            let nextX = markerEndX(
                forGlyphAt: glyphIndex,
                currentLine: lineRect,
                origin: origin,
                markerRange: markerRange
            )
            let lineHeight = max(1, lineRect.height)

            switch character {
            case 0x20, 0xA0:
                let advance = max(1, nextX - x)
                let radius = min(1.0, max(0.55, lineHeight * 0.065))
                dotPath.appendOval(
                    in: NSRect(
                        x: x + advance * 0.5 - radius,
                        y: centerY - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
            case 0x09:
                drawTabGuide(
                    in: guidePath,
                    startX: x,
                    endX: nextX,
                    centerY: centerY,
                    lineHeight: lineHeight
                )
            case 0x0A:
                drawLineBreakGuide(
                    in: guidePath,
                    startX: x,
                    centerY: centerY,
                    lineHeight: lineHeight
                )
            case 0x0D:
                // A CRLF pair is represented by two glyphs at one location.
                // Paint one marker for the pair, at the LF glyph below.
                if characterIndex + 1 < documentLength,
                    source.character(at: characterIndex + 1) == 0x0A
                {
                    continue
                }
                drawLineBreakGuide(
                    in: guidePath,
                    startX: x,
                    centerY: centerY,
                    lineHeight: lineHeight
                )
            case 0x00...0x1F, 0x7F:
                let advance = max(1, nextX - x)
                let pointSize = min(9, max(7, lineHeight * 0.62))
                let font = NSFont.monospacedSystemFont(
                    ofSize: pointSize,
                    weight: .regular
                )
                let pictureCode = character == 0x7F ? 0x2421 : 0x2400 + Int(character)
                let picture = String(UnicodeScalar(pictureCode)!)
                controlPictures.append((
                    picture,
                    NSPoint(
                        x: x + advance * 0.5 - pointSize * 0.35,
                        y: centerY - pointSize * 0.46
                    ),
                    font
                ))
            default:
                break
            }
        }

        // Semantic label colors already carry their intended system alpha.
        // Replacing that alpha would turn this muted color nearly black.
        let markerColor = NSColor.tertiaryLabelColor
        NSGraphicsContext.saveGraphicsState()
        markerColor.setFill()
        markerColor.setStroke()
        dotPath.fill()
        guidePath.stroke()
        for (picture, point, font) in controlPictures {
            picture.draw(
                at: point,
                withAttributes: [
                    .font: font,
                    .foregroundColor: markerColor,
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func markerEndX(
        forGlyphAt glyphIndex: Int,
        currentLine: NSRect,
        origin: NSPoint,
        markerRange: NSRange
    ) -> CGFloat {
        let nextGlyph = glyphIndex + 1
        guard nextGlyph < NSMaxRange(markerRange) else {
            let usedLine = lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            return origin.x + max(currentLine.minX, usedLine.maxX)
        }
        let nextLine = lineFragmentRect(
            forGlyphAt: nextGlyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        guard abs(nextLine.minY - currentLine.minY) < 0.5 else {
            let usedLine = lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            return origin.x + max(currentLine.minX, usedLine.maxX)
        }
        let nextLocation = location(forGlyphAt: nextGlyph)
        return origin.x + nextLine.minX + nextLocation.x
    }

    private func drawTabGuide(
        in path: NSBezierPath,
        startX: CGFloat,
        endX: CGFloat,
        centerY: CGFloat,
        lineHeight: CGFloat
    ) {
        let left = startX + min(2.0, max(0.5, endX - startX) * 0.12)
        let right = endX - min(2.0, max(0.5, endX - startX) * 0.12)
        guard right - left > 2 else { return }
        let head = min(lineHeight * 0.24, max(1.5, (right - left) * 0.18))
        path.move(to: NSPoint(x: left, y: centerY))
        path.line(to: NSPoint(x: right - head, y: centerY))
        path.move(to: NSPoint(x: right - head, y: centerY + head * 0.72))
        path.line(to: NSPoint(x: right, y: centerY))
        path.line(to: NSPoint(x: right - head, y: centerY - head * 0.72))
    }

    private func drawLineBreakGuide(
        in path: NSBezierPath,
        startX: CGFloat,
        centerY: CGFloat,
        lineHeight: CGFloat
    ) {
        // The newline glyph starts immediately after the final visible glyph.
        // Keep the complete marker on its right so the arrow cannot cover the
        // final character, even on tightly kerned or proportionally set text.
        let arrowTipX = startX + max(1.5, lineHeight * 0.1)
        let stemX = arrowTipX + min(6.5, lineHeight * 0.48)
        let shaftY = centerY + 1
        let bottomY = centerY - min(3.5, max(2, lineHeight * 0.26))
        let arrowHead = min(2.2, max(1.5, lineHeight * 0.18))

        path.move(to: NSPoint(x: stemX, y: bottomY))
        path.line(to: NSPoint(x: stemX, y: shaftY))
        path.line(to: NSPoint(x: arrowTipX, y: shaftY))
        path.move(to: NSPoint(x: arrowTipX, y: shaftY))
        path.line(to: NSPoint(x: arrowTipX + arrowHead, y: shaftY + arrowHead))
        path.move(to: NSPoint(x: arrowTipX, y: shaftY))
        path.line(to: NSPoint(x: arrowTipX + arrowHead, y: shaftY - arrowHead))
    }
}

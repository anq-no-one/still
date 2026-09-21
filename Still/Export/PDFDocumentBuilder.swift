import CoreGraphics
import CoreText
import Foundation

enum PDFDocumentBuilder {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func pdf(from text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
        let frame = box.insetBy(dx: margin, dy: margin)
        var start = CFIndex(0)
        let length = attributed(text).length

        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)

            let path = CGPath(rect: CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.height), transform: nil)
            let textFrame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(textFrame, context)

            let visible = CTFrameGetVisibleStringRange(textFrame)
            start += visible.length
            context.endPDFPage()
        } while start < length

        context.closePDF()
        return data as Data
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        var spacing = CGFloat(4)
        let setting = [
            CTParagraphStyleSetting(
                spec: .paragraphSpacing,
                valueSize: MemoryLayout<CGFloat>.size,
                value: &spacing
            )
        ]
        let paragraph = CTParagraphStyleCreate(setting, 1)

        return NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
            ]
        )
    }
}

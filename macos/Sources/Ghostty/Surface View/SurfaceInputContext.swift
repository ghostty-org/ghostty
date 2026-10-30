import AppKit
import Carbon
import ObjectiveC

extension Ghostty {
    /// An input context for a terminal, which cannot replace text already sent to the PTY.
    final class SurfaceInputContext: NSTextInputContext {
        override init(client: NSTextInputClient) {
            super.init(client: client)

            // AppKit advertises document access, including replacement of committed text,
            // for NSTextInputClient. The Korean IME initially uses that capability for
            // direct composition, committing its first consonant before discovering that
            // SurfaceView cannot replace it. Disable it so composition uses marked text.
            // This must precede activate(): an already selected IME caches the capability
            // during activation, before TSMGetActiveDocument() exposes our document.
            guard let offset = Self.documentIDOffset,
                  let document = Unmanaged.passUnretained(self).toOpaque()
                    .advanced(by: offset).load(as: TSMDocumentID?.self) else { return }
            TSMRemoveDocumentProperty(
                document,
                TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
        }

        // There is no public accessor for an inactive context's TSM document. Validate
        // AppKit's private ivar layout before reading it, and retain AppKit's default
        // behavior if a future OS changes that layout. Never modify or own the pointer.
        private static let documentIDOffset: Int? = {
            guard let ivar = class_getInstanceVariable(NSTextInputContext.self, "_documentID"),
                  let encoding = ivar_getTypeEncoding(ivar),
                  String(cString: encoding) == "^v" else { return nil }
            let offset = ivar_getOffset(ivar)
            let layout = MemoryLayout<TSMDocumentID?>.self
            guard offset >= 0,
                  offset % layout.alignment == 0,
                  offset + layout.size <= class_getInstanceSize(NSTextInputContext.self) else { return nil }
            return offset
        }()
    }
}

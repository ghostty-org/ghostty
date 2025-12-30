import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension Transferable {
    /// Converts this Transferable to an NSPasteboardItem with lazy data loading.
    /// Data is only fetched when the pasteboard consumer requests it. This allows
    /// bridging a Transferable to NSDraggingSource.
    func pasteboardItem() -> NSPasteboardItem? {
        let itemProvider = NSItemProvider()
        itemProvider.register(self)

        let types = itemProvider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard !types.isEmpty else { return nil }

        let item = NSPasteboardItem()
        let dataProvider = TransferableDataProvider(itemProvider: itemProvider)
        let pasteboardTypes = types.map { NSPasteboard.PasteboardType($0.identifier) }
        item.setDataProvider(dataProvider, forTypes: pasteboardTypes)

        return item
    }
}

private final class TransferableDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let itemProvider: NSItemProvider

    init(itemProvider: NSItemProvider) {
        self.itemProvider = itemProvider
        super.init()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // NSPasteboardItemDataProvider requires synchronous data return, but
        // NSItemProvider.loadDataRepresentation is async. We use a semaphore
        // to block until the async load completes. This is safe because AppKit
        // calls this method on a background thread during drag operations.
        let semaphore = DispatchSemaphore(value: 0)
        
        var result: Data?
        itemProvider.loadDataRepresentation(forTypeIdentifier: type.rawValue) { data, _ in
            result = data
            semaphore.signal()
        }
        
        // Wait for the data to load
        semaphore.wait()
        
        // Set it. I honestly don't know what happens here if this fails.
        if let data = result {
            item.setData(data, forType: type)
        }
    }
}

//
//  DownloadQuickLookHelper.swift
//  Cherry Browser
//

import AppKit
import Quartz

final class DownloadQuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = DownloadQuickLookHelper()

    private var currentFileURL: URL?

    func previewFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }

        currentFileURL = url

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.reloadData()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.dataSource = self
            panel.delegate = self
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentFileURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentFileURL as? NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown && event.keyCode == 49 { // spacebar
            panel.close()
            return true
        }
        return false
    }
}

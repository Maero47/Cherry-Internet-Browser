//
//  QRCodePopup.swift
//  Cherry Browser
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct QRCodePopup: View {
    let url: URL
    let pageTitle: String
    let onDismiss: () -> Void

    @State private var qrImage: NSImage?

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("QR Code")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                // QR Code image
                if let image = qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .background(Color.white)
                        .cornerRadius(8)
                } else {
                    ProgressView()
                        .frame(width: 200, height: 200)
                }

                // Page info
                VStack(spacing: 4) {
                    Text(pageTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 240)

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        copyImageToClipboard()
                    } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        saveImage()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 4)
            )
        }
        .onAppear {
            qrImage = generateQRCode(from: url)
        }
    }

    private func generateQRCode(from url: URL) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for clarity
        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }

    private func copyImageToClipboard() {
        guard let image = qrImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func saveImage() {
        guard let image = qrImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QRCode-\(pageTitle.prefix(20).replacingOccurrences(of: " ", with: "_")).png"
        panel.begin { response in
            if response == .OK, let saveURL = panel.url {
                try? pngData.write(to: saveURL)
            }
            // Dismiss the popup from the save panel callback. This fires the onChange
            // in BrowserView which restores WKWebView first responder. Without this,
            // if the user had already tapped X before closing the save panel the
            // showQRCode flag is already false so onChange never fires — leaving the
            // browser unresponsive until the next user interaction.
            DispatchQueue.main.async { onDismiss() }
        }
    }
}

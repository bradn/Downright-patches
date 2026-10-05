// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownCore
import MarkdownRender
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Throwaway demo host for `MarkdownReaderView`, the phase 2 UIKit reading
/// surface.
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct DemoDocument: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String
    var url: URL?

    static func bundled(_ name: String, title: String) -> DemoDocument {
        let url = Bundle.main.url(forResource: name, withExtension: "md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "# Missing \(name).md"
        return DemoDocument(id: name, title: title, text: text, url: url)
    }
}

struct ContentView: View {
    @State private var documents = [
        DemoDocument.bundled("Sample", title: "Sample"),
        DemoDocument.bundled("README", title: "README"),
    ]
    @State private var selection = "Sample"
    @State private var importing = false
    @State private var importError: String?
    @State private var reader = ReaderHandle()
    @State private var showingOutline = false

    private var current: DemoDocument {
        documents.first { $0.id == selection } ?? documents[0]
    }

    var body: some View {
        NavigationStack {
            MarkdownView(text: current.text, url: current.url, handle: reader)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(current.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Document", selection: $selection) {
                            ForEach(documents) { Text($0.title).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open", systemImage: "folder") { importing = true }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Outline", systemImage: "list.bullet") { showingOutline = reader.view != nil }
                    }
                }
                .sheet(isPresented: $showingOutline) {
                    if let view = reader.view {
                        OutlineSheet(reader: view)
                            .presentationDetents([.medium, .large])
                    }
                }
                .fileImporter(
                    isPresented: $importing,
                    allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText]
                ) { result in open(result) }
                .alert("Couldn't open file", isPresented: .constant(importError != nil)) {
                    Button("OK") { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
        }
    }

    private func open(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            // Access is granted to the picked file only, so relative images
            // beside it may not load; the URL is still the document's own.
            let document = DemoDocument(id: url.absoluteString, title: url.lastPathComponent, text: text, url: url)
            documents.removeAll { $0.id == document.id }
            documents.append(document)
            selection = document.id
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// Hosts the shared engine's UIKit reading surface.
/// Lets SwiftUI chrome reach the UIKit reader it hosts.
@MainActor
final class ReaderHandle {
    weak var view: MarkdownReaderView?
}

/// The shared outline controller, in a SwiftUI sheet.
struct OutlineSheet: UIViewControllerRepresentable {
    let reader: MarkdownReaderView

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ReaderOutlineController(reader: reader))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

struct MarkdownView: UIViewRepresentable {
    let text: String
    let url: URL?
    let handle: ReaderHandle
    @Environment(\.colorScheme) private var colorScheme

    private func styleSheet() -> StyleSheet {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let theme = ThemeStore.shared.themes.first { $0.name == "System" } ?? ThemeStore.shared.current
        return StyleSheet(theme: theme, appearance: traits)
    }

    func makeUIView(context: Context) -> MarkdownReaderView {
        let view = MarkdownReaderView(styleSheet: styleSheet())
        handle.view = view
        view.documentURL = url
        view.setMarkdown(text)
        context.coordinator.text = text
        context.coordinator.scheme = colorScheme
        return view
    }

    func updateUIView(_ view: MarkdownReaderView, context: Context) {
        if context.coordinator.scheme != colorScheme {
            context.coordinator.scheme = colorScheme
            view.styleSheet = styleSheet()
        }
        if context.coordinator.text != text {
            context.coordinator.text = text
            view.documentURL = url
            view.setMarkdown(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var text = ""
        var scheme: ColorScheme?
    }
}

//
//  MarkdownPreviewView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Renders a note's Markdown in a locked-down WKWebView:
//  • page JavaScript disabled, strict Content-Security-Policy, no remote loads
//  • non-persistent website data store (nothing written to disk)
//  • clicked http(s)/mailto links open in the default browser/mail app
//

import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    var markdown: String
    var fontSize: Double
    /// Lookup keys of existing note titles (missing [[links]] are styled differently).
    var titleKeys: Set<String> = []
    /// Called when a #tag is clicked in the preview.
    var onTagClick: (String) -> Void = { _ in }
    /// Called when a [[link]] is clicked, with its target title.
    var onOpenLink: (String) -> Void = { _ in }
    /// Supplies decrypted attachment bytes for <img src="rnotes-attachment://id">.
    var loadAttachment: (String) -> (data: Data, mime: String)? = { _ in nil }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let attachments = AttachmentSchemeHandler()
        attachments.loader = loadAttachment
        config.setURLSchemeHandler(attachments, forURLScheme: AttachmentSchemeHandler.scheme)
        context.coordinator.attachmentHandler = attachments

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        context.coordinator.onTagClick = onTagClick
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.update(markdown: markdown, fontSize: fontSize, titleKeys: titleKeys)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.attachmentHandler?.loader = loadAttachment
        context.coordinator.onTagClick = onTagClick
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.update(markdown: markdown, fontSize: fontSize, titleKeys: titleKeys)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onTagClick: (String) -> Void = { _ in }
        var onOpenLink: (String) -> Void = { _ in }
        var attachmentHandler: AttachmentSchemeHandler?
        private var lastTitleKeys: Set<String>?
        private var lastMarkdown: String?
        private var lastFontSize: Double?
        private var lastBody = ""
        private var pageLoaded = false
        private var pendingBody: String?

        func update(markdown: String, fontSize: Double, titleKeys: Set<String>) {
            guard markdown != lastMarkdown || fontSize != lastFontSize || titleKeys != lastTitleKeys else { return }
            let fontChanged = fontSize != lastFontSize
            lastMarkdown = markdown
            lastFontSize = fontSize
            lastTitleKeys = titleKeys
            let body = MarkdownRenderer.render(markdown, titleKeys: titleKeys)

            if fontChanged {
                loadFullPage(body: body)
                return
            }
            guard body != lastBody else { return }
            lastBody = body
            if pageLoaded {
                swapBody(body)
            } else {
                pendingBody = body
            }
        }

        private func loadFullPage(body: String) {
            lastBody = body
            pageLoaded = false
            pendingBody = nil
            webView?.loadHTMLString(MarkdownRenderer.page(body: body, fontSize: lastFontSize ?? 14),
                                    baseURL: nil)
        }

        /// Replaces only the article contents, so the scroll position is kept while typing.
        /// Uses an app-injected script in an isolated world (page scripts stay disabled).
        private func swapBody(_ body: String) {
            guard let webView = webView else { return }
            webView.callAsyncJavaScript(
                "document.getElementById('content').innerHTML = html;",
                arguments: ["html": body],
                in: nil,
                in: .defaultClient
            ) { [weak self] result in
                if case .failure = result { self?.loadFullPage(body: body) }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let pending = pendingBody {
                pendingBody = nil
                swapBody(pending)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "rnotes", url.host == "tag" {
                    let path = String(url.path.dropFirst())   // "/work/clients" → "work/clients"
                    if !path.isEmpty { let open = onTagClick; DispatchQueue.main.async { open(path) } }
                } else if let url = navigationAction.request.url, url.scheme == "rnotes", url.host == "note" {
                    let prefix = "rnotes://note/"
                    let raw = String(url.absoluteString.dropFirst(prefix.count))
                    if let title = raw.removingPercentEncoding, !title.isEmpty {
                        let open = onOpenLink; DispatchQueue.main.async { open(title) }
                    }
                } else if let url = navigationAction.request.url,
                   MarkdownRenderer.safeURL(url.absoluteString) != nil {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // Only our own loadHTMLString (about:blank) is allowed to load.
            let scheme = navigationAction.request.url?.scheme ?? "about"
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }
    }
}

/// Serves decrypted attachment images to the preview from memory — nothing is written to disk.
final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "rnotes-attachment"
    var loader: (String) -> (data: Data, mime: String)? = { _ in nil }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let id = url.host?.lowercased(),
              let payload = loader(id) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let response = URLResponse(url: url, mimeType: payload.mime,
                                   expectedContentLength: payload.data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(payload.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

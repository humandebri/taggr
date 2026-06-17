import CryptoKit
import SwiftUI
import WebKit

struct IdentityWebView: UIViewRepresentable {
    let onComplete: (Result<TaggrAuthSession, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "taggrIdentity")
        controller.addUserScript(WKUserScript(
            source: context.coordinator.bridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        if TaggrRuntimeConfig.current.automateLocalIdentity {
            configuration.websiteDataStore = .nonPersistent()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: TaggrIdentityBridge.authorizeURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let onComplete: (Result<TaggrAuthSession, Error>) -> Void
        private let privateKey = Curve25519.Signing.PrivateKey()

        init(onComplete: @escaping (Result<TaggrAuthSession, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? String else {
                onComplete(.failure(TaggrIdentityError.invalidPayload))
                return
            }
            do {
                onComplete(.success(try TaggrIdentityBridge.makeSession(from: payload, privateKey: privateKey)))
            } catch {
                onComplete(.failure(error))
            }
        }

        func bridgeScript(config: TaggrRuntimeConfig = .current) -> String {
            let sessionPublicKey = TaggrIdentityBridge.derPublicKey(from: privateKey.publicKey.rawRepresentation)
            let request = TaggrIdentityBridge.authorizeClientRequest(publicKey: sessionPublicKey)
            let escapedRequest = request
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
            let escapedAuthOrigin = config.authOrigin
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let shouldAutomateLocalIdentity = config.automateLocalIdentity ? "true" : "false"
            return """
            (() => {
              const TAGGR_REQUEST = JSON.parse(`\(escapedRequest)`);
              const TAGGR_AUTOMATE_LOCAL_II = \(shouldAutomateLocalIdentity);
              TAGGR_REQUEST.sessionPublicKey = new Uint8Array(TAGGR_REQUEST.sessionPublicKey);
              TAGGR_REQUEST.maxTimeToLive = BigInt(TAGGR_REQUEST.maxTimeToLive);
              const listeners = [];
              const normalize = (value) => {
                if (typeof value === "bigint") return value.toString(10);
                if (value instanceof Uint8Array) return Array.from(value);
                if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
                if (Array.isArray(value)) return value.map(normalize);
                if (value && typeof value === "object") {
                  if (typeof value.toUint8Array === "function") return Array.from(value.toUint8Array());
                  const out = {};
                  for (const [key, nested] of Object.entries(value)) out[key] = normalize(nested);
                  return out;
                }
                return value;
              };
              const queryAllDeep = (selector) => {
                const matches = [];
                const visit = (root) => {
                  for (const element of Array.from(root.querySelectorAll(selector))) matches.push(element);
                  for (const element of Array.from(root.querySelectorAll("*"))) {
                    if (element.shadowRoot) visit(element.shadowRoot);
                  }
                };
                visit(document);
                return matches;
              };
              const visibleText = (root) => {
                let text = "";
                const visit = (node) => {
                  if (!node) return;
                  if (node.nodeType === Node.TEXT_NODE) {
                    text += " " + node.textContent;
                    return;
                  }
                  if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
                  if (node.shadowRoot) visit(node.shadowRoot);
                  for (const child of Array.from(node.childNodes || [])) visit(child);
                };
                visit(root);
                return text.replace(/\\s+/g, " ").trim().toLowerCase();
              };
              const clickButton = (matcher) => {
                const selector = "button, a, [role='button'], input[type='button'], input[type='submit']";
                for (const element of queryAllDeep(selector)) {
                  const style = window.getComputedStyle(element);
                  const rect = element.getBoundingClientRect();
                  if (style.display === "none" || style.visibility === "hidden" || rect.width === 0 || rect.height === 0) continue;
                  const text = visibleText(element);
                  if (matcher(text)) {
                    activateElement(element);
                    return true;
                  }
                }
                return false;
              };
              const activateElement = (element) => {
                if (!element) return false;
                const interactive = element.closest && element.closest("button, a, [role='button'], input[type='button'], input[type='submit']");
                if (interactive) element = interactive;
                if (typeof element.focus === "function") element.focus();
                if (typeof PointerEvent === "function") {
                  for (const type of ["pointerdown", "pointerup"]) {
                    element.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, view: window, pointerType: "mouse", isPrimary: true }));
                  }
                }
                for (const type of ["mousedown", "mouseup", "click"]) {
                  element.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
                }
                if (typeof element.click === "function") element.click();
                return true;
              };
              const clickViewport = (xRatio, yRatio) => {
                const element = document.elementFromPoint(window.innerWidth * xRatio, window.innerHeight * yRatio);
                return activateElement(element);
              };
              const fillIdentityName = () => {
                const input = queryAllDeep("input").find((element) => {
                  if (!(element instanceof HTMLInputElement)) return false;
                  const style = window.getComputedStyle(element);
                  const rect = element.getBoundingClientRect();
                  return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
                });
                if (!(input instanceof HTMLInputElement)) return false;
                const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
                if (setter) setter.call(input, "Local TAGGR");
                else input.value = "Local TAGGR";
                input.dispatchEvent(new InputEvent("input", { bubbles: true, data: "Local TAGGR", inputType: "insertText" }));
                input.dispatchEvent(new Event("change", { bubbles: true }));
                return true;
              };
              const automateLocalII = () => {
                if (!TAGGR_AUTOMATE_LOCAL_II) return;
                let ticks = 0;
                let didClickSignUp = false;
                let didClickSignUpWithPasskey = false;
                let didClickCreateIdentity = false;
                let createdIdentityAt = 0;
                const timer = window.setInterval(() => {
                  ticks += 1;
                  const bodyText = visibleText(document);
                  let acted = false;
                  if (bodyText.includes("this app has moved")) {
                    acted = clickButton((text) => text === "×" || text === "x") || clickViewport(0.88, 0.18);
                  }
                  if (bodyText.includes("continue to") || bodyText.includes("allow access")) {
                    const registrationSettled = !didClickCreateIdentity || Date.now() - createdIdentityAt > 5000;
                    if (registrationSettled) {
                      acted = clickButton((text) => text === "continue" || text.includes("allow access")) || clickViewport(0.5, 0.69);
                    }
                  }
                  if (!acted && bodyText.includes("name your identity")) {
                    if (fillIdentityName()) {
                      didClickCreateIdentity = clickButton((text) => text.includes("create identity"));
                      if (didClickCreateIdentity) createdIdentityAt = Date.now();
                    }
                  } else if (!acted && bodyText.includes("want a new identity?")) {
                    didClickSignUp = clickButton((text) => text.includes("sign up")) || clickViewport(0.83, 0.82) || didClickSignUp;
                  } else if (!acted && (bodyText.includes("set up your private") || bodyText.includes("create an identity"))) {
                    didClickSignUpWithPasskey = clickButton((text) => text.includes("sign up with passkey")) || clickViewport(0.5, 0.66) || didClickSignUpWithPasskey;
                  } else if (!acted && bodyText.includes("sign in with passkey")) {
                    clickButton((text) => text.includes("sign in with passkey"));
                  } else if (!acted && (bodyText.includes("authorize") || bodyText.includes("allow"))) {
                    clickButton((text) => text.includes("authorize") || text.includes("allow") || text.includes("continue"));
                  }
                  if (ticks > 120) window.clearInterval(timer);
                }, 500);
              };
              window.__taggrAutomateLocalII = automateLocalII;
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", automateLocalII, { once: true });
              } else {
                automateLocalII();
              }
              const isTerminalAuthorizeMessage = (message) => {
                return message && (message.kind === "authorize-client-success" || message.kind === "authorize-client-failure");
              };
              const nativePost = (payload) => {
                window.webkit.messageHandlers.taggrIdentity.postMessage(JSON.stringify(normalize(payload)));
              };
              const openerWindow = {
                closed: false,
                close: () => {},
                postMessage: (message) => {
                  if (message && message.kind === "authorize-ready") scheduleDeliver();
                  if (isTerminalAuthorizeMessage(message)) nativePost(message);
                }
              };
              const deliver = () => {
                const event = { origin: "\(escapedAuthOrigin)", source: openerWindow, data: TAGGR_REQUEST };
                for (const listener of listeners.slice()) {
                  if (typeof listener === "function") listener.call(window, event);
                  else if (listener && typeof listener.handleEvent === "function") listener.handleEvent(event);
                }
                if (typeof window.onmessage === "function") window.onmessage.call(window, event);
              };
              const scheduleDeliver = () => {
                for (const delay of [0, 50, 250, 1000]) window.setTimeout(deliver, delay);
              };
              const originalAdd = window.addEventListener.bind(window);
              window.addEventListener = (type, listener, options) => {
                if (type === "message" && listener) listeners.push(listener);
                return originalAdd(type, listener, options);
              };
              originalAdd("message", (event) => {
                if (isTerminalAuthorizeMessage(event.data)) nativePost(event.data);
              });
              const originalPostMessage = window.postMessage.bind(window);
              window.postMessage = (message, targetOrigin, transfer) => {
                if (isTerminalAuthorizeMessage(message)) nativePost(message);
                return originalPostMessage(message, targetOrigin, transfer);
              };
              const originalDispatchEvent = window.dispatchEvent.bind(window);
              window.dispatchEvent = (event) => {
                if (event && event.type === "message" && isTerminalAuthorizeMessage(event.data)) nativePost(event.data);
                return originalDispatchEvent(event);
              };
              Object.defineProperty(window, "opener", {
                configurable: true,
                value: openerWindow
              });
            })();
            """
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            guard TaggrRuntimeConfig.current.automateLocalIdentity else { return }
            webView.evaluateJavaScript("window.__taggrAutomateLocalII && window.__taggrAutomateLocalII();")
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            completionHandler(defaultText ?? "0")
        }
    }
}

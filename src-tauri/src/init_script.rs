use url::Url;

pub(crate) fn init_script(target_url: &Url) -> String {
    let target_literal =
        serde_json::to_string(target_url.as_str()).expect("URL string literal should serialize");
    TEMPLATE.replace("__TAGGR_BOOTSTRAP_TARGET__", &target_literal)
}

const TEMPLATE: &str = r#"
(() => {
  const TAGGR_APP_URL = __TAGGR_BOOTSTRAP_TARGET__;
  const IDENTITY_HOSTS = new Set([
    "id.ai",
    "identity.internetcomputer.org",
    "identity.ic0.app"
  ]);
  const APP_HOST = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
  const FIRST_LOAD_TIMEOUT_MS = 15000;
  let firstLoadFinished = false;
  let appNavigationStarted = false;

  const isErrorDocument = () => location.href === "about:blank#taggr-ios-error";
  const isBootstrapDocument = () => location.href === "about:blank" || isErrorDocument();
  const isAppDocument = () => location.host === APP_HOST;
  if (!isBootstrapDocument() && !isAppDocument()) return;

  Object.defineProperty(window, "__TAGGR_IOS_APP__", {
    value: true,
    configurable: false,
    writable: false
  });

  const makeOverlay = (id, titleText, bodyText, buttonText, action) => {
    if (document.getElementById(id)) return;

    const root = document.createElement("div");
    root.id = id;
    root.style.cssText = [
      "position:fixed",
      "inset:0",
      "z-index:2147483647",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "padding:24px",
      "background:#111",
      "color:#f6f6f6",
      "font-family:-apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif"
    ].join(";");

    const panel = document.createElement("div");
    panel.style.cssText = "max-width:320px;text-align:center";

    const title = document.createElement("div");
    title.textContent = titleText;
    title.style.cssText = "font-size:20px;font-weight:700;margin-bottom:8px";

    const body = document.createElement("div");
    body.textContent = bodyText;
    body.style.cssText = "font-size:15px;line-height:1.4;margin-bottom:18px";

    panel.append(title, body);

    if (buttonText) {
      const button = document.createElement("button");
      button.textContent = buttonText;
      button.style.cssText = [
        "border:0",
        "border-radius:8px",
        "padding:12px 18px",
        "background:#f6f6f6",
        "color:#111",
        "font-size:16px",
        "font-weight:700"
      ].join(";");
      button.addEventListener("click", action);
      panel.append(button);
    }

    root.append(panel);
    document.documentElement.append(root);
  };

  const showLoading = () => makeOverlay(
    "taggr-ios-loading",
    "Loading TAGGR",
    "Connecting to the production TAGGR service.",
    "",
    () => {}
  );
  const hideLoading = () => {
    document.getElementById("taggr-ios-loading")?.remove();
  };
  const markFirstLoadFinished = () => {
    if (isBootstrapDocument()) return;
    firstLoadFinished = true;
    hideLoading();
  };
  const showConnectionError = () => {
    hideLoading();
    makeOverlay(
      "taggr-ios-error",
      "Connection error",
      "TAGGR could not load. Check the connection and reload.",
      "Reload",
      () => {
        if (isBootstrapDocument()) {
          location.href = TAGGR_APP_URL;
        } else {
          location.reload();
        }
      }
    );
  };
  const onDocumentReady = (action) => {
    if (document.readyState === "loading") {
      window.addEventListener("DOMContentLoaded", action, { once: true });
    } else {
      action();
    }
  };
  const hideConnectionError = () => {
    document.getElementById("taggr-ios-error")?.remove();
  };
  const isIdentityUrl = (url) => IDENTITY_HOSTS.has(new URL(url, location.href).host);
  const navigateToApp = () => {
    if (!isBootstrapDocument() || appNavigationStarted) return;
    appNavigationStarted = true;
    location.href = TAGGR_APP_URL;
  };

  window.addEventListener("offline", showConnectionError);
  window.addEventListener("online", hideConnectionError);
  window.addEventListener("load", markFirstLoadFinished, { once: true });
  window.__TAGGR_IOS_HIDE_LOADING__ = markFirstLoadFinished;
  window.__TAGGR_IOS_SHOW_ERROR__ = showConnectionError;
  onDocumentReady(showLoading);
  window.setTimeout(() => {
    if (!firstLoadFinished) showConnectionError();
  }, FIRST_LOAD_TIMEOUT_MS);
  if (!navigator.onLine) {
    onDocumentReady(showConnectionError);
  }
  if (isErrorDocument()) {
    onDocumentReady(showConnectionError);
  } else if (isBootstrapDocument() && navigator.onLine) {
    onDocumentReady(() => window.setTimeout(navigateToApp, 0));
  }

  const originalWindowOpen = window.open.bind(window);
  window.open = (url, target, features) => {
    if (typeof url === "string" && url.length > 0) {
      try {
        if (isIdentityUrl(url)) {
          return originalWindowOpen(url, target, features);
        }
      } catch (_) {
        return originalWindowOpen(url, target, features);
      }
      location.href = url;
    }
    return null;
  };

  document.addEventListener("click", (event) => {
    const link = event.target?.closest?.("a[href]");
    if (!link || link.target !== "_blank") return;
    try {
      if (isIdentityUrl(link.href)) return;
    } catch (_) {
      return;
    }
    event.preventDefault();
    location.href = link.href;
  }, true);
})();
"#;
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injects_bootstrap_target_url() {
        let target = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/1").unwrap();
        let script = init_script(&target);
        assert!(script.contains(&format!("const TAGGR_APP_URL = \"{}\";", target.as_str())));
        assert!(!script.contains("__TAGGR_BOOTSTRAP_TARGET__"));
    }

    #[test]
    fn injects_bootstrap_target_as_json_string_literal() {
        let target =
            Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/%22quoted%22").unwrap();
        let script = init_script(&target);
        assert!(script.contains(r##"const TAGGR_APP_URL = "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/%22quoted%22";"##));
    }

    #[test]
    fn preserves_identity_window_open_behavior() {
        let target = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/").unwrap();
        let script = init_script(&target);
        assert!(script.contains("originalWindowOpen"));
        assert!(script.contains("isIdentityUrl"));
        assert!(script.contains("identity.internetcomputer.org"));
    }

    #[test]
    fn preserves_identity_target_blank_behavior() {
        let target = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/").unwrap();
        let script = init_script(&target);
        assert!(script.contains("if (isIdentityUrl(link.href)) return"));
        assert!(script.contains("event.preventDefault()"));
    }

    #[test]
    fn skips_non_app_documents() {
        let target = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/").unwrap();
        let script = init_script(&target);
        assert!(script.contains("const APP_HOST = \"6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io\""));
        assert!(script.contains("if (!isBootstrapDocument() && !isAppDocument()) return"));
    }

    #[test]
    fn exposes_error_overlay_for_native_webkit_failures() {
        let target = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/").unwrap();
        let script = init_script(&target);
        assert!(script.contains("window.__TAGGR_IOS_SHOW_ERROR__ = showConnectionError"));
        assert!(script.contains("about:blank#taggr-ios-error"));
        assert!(script.contains("if (isErrorDocument())"));
    }
}

use tauri_plugin_opener::OpenerExt;
use url::Url;

use crate::config::{
    APP_HOST, APP_URL, CANISTER_HOST, ERROR_PAGE_URL, ERROR_START_URL, RAW_CANISTER_HOST,
};

pub(crate) fn initial_webview_url() -> Result<Url, url::ParseError> {
    Url::parse(ERROR_START_URL)
}

pub(crate) fn error_page_url() -> Result<Url, url::ParseError> {
    Url::parse(ERROR_PAGE_URL)
}

pub(crate) fn bootstrap_target_url(urls: Option<&[Url]>) -> Result<Url, url::ParseError> {
    if let Some(urls) = urls {
        if let Some(target) = urls.iter().find_map(map_deep_link) {
            return Ok(target);
        }
    }

    Url::parse(APP_URL)
}

pub(crate) fn contains_supported_deep_link(urls: &[Url]) -> bool {
    urls.iter().any(|url| map_deep_link(url).is_some())
}

pub(crate) fn external_initial_links(urls: &[Url]) -> Vec<Url> {
    urls.iter()
        .filter(|url| map_deep_link(url).is_none() && matches!(url.scheme(), "http" | "https"))
        .cloned()
        .collect()
}

pub(crate) fn handle_navigation(app: &tauri::AppHandle, url: &Url) -> bool {
    if is_local_error_url(url) || stays_in_app(url) {
        return true;
    }

    if should_open_externally(url) {
        let _ = app.opener().open_url(url.as_str(), None::<&str>);
    }

    false
}

fn should_open_externally(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https") && !is_local_error_url(url) && !stays_in_app(url)
}

#[cfg(target_os = "ios")]
pub(crate) fn enable_ios_back_forward_gestures(webview: &tauri::WebviewWindow) {
    let _ = webview.with_webview(|platform_webview| unsafe {
        let wk_webview = &*(platform_webview.inner().cast::<objc2_web_kit::WKWebView>());
        wk_webview.setAllowsBackForwardNavigationGestures(true);
    });
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn enable_ios_back_forward_gestures(_webview: &tauri::WebviewWindow) {}

pub(crate) fn open_deep_links(
    app: &tauri::AppHandle,
    webview: &tauri::WebviewWindow,
    urls: Vec<Url>,
) {
    for url in urls {
        if let Some(target) = map_deep_link(&url) {
            let _ = webview.navigate(target);
        } else if matches!(url.scheme(), "http" | "https") {
            let _ = app.opener().open_url(url.as_str(), None::<&str>);
        }
    }
}

pub(crate) fn open_external_links(app: &tauri::AppHandle, urls: Vec<Url>) {
    for url in urls {
        if should_open_externally(&url) {
            let _ = app.opener().open_url(url.as_str(), None::<&str>);
        }
    }
}

fn map_deep_link(url: &Url) -> Option<Url> {
    match url.scheme() {
        "https" if url.host_str() == Some(APP_HOST) => canonical_https_to_url(url),
        "taggr" => taggr_scheme_to_url(url),
        _ => None,
    }
}

fn canonical_https_to_url(url: &Url) -> Option<Url> {
    if let Some(fragment) = url.fragment() {
        let route = fragment.trim_start_matches('/');
        return route_to_app_url(route);
    }

    let mut route_parts = Vec::new();
    if let Some(segments) = url.path_segments() {
        route_parts.extend(segments.filter(|part| !part.is_empty()));
    }

    let route = route_parts.join("/");
    if route.is_empty() {
        return Some(url.clone());
    }

    route_to_app_url(&route)
}

fn taggr_scheme_to_url(url: &Url) -> Option<Url> {
    let mut route_parts = Vec::new();
    if let Some(host) = url.host_str() {
        route_parts.push(host.trim_matches('/'));
    }
    if let Some(segments) = url.path_segments() {
        route_parts.extend(segments.filter(|part| !part.is_empty()));
    }

    route_to_app_url(&route_parts.join("/"))
}

fn route_to_app_url(route: &str) -> Option<Url> {
    if !is_supported_public_route(route) {
        return None;
    }

    let fragment = if route.is_empty() {
        "#/".to_string()
    } else {
        format!("#/{route}")
    };

    Url::parse(&format!("{APP_URL}/{fragment}")).ok()
}

pub(crate) fn is_supported_public_route(route: &str) -> bool {
    let first_segment = route.split('/').find(|part| !part.is_empty());
    matches!(
        first_segment,
        None | Some("post")
            | Some("user")
            | Some("realm")
            | Some("transaction")
            | Some("transactions")
            | Some("tokens")
    )
}

fn stays_in_app(url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }

    matches!(
        url.host_str(),
        Some(APP_HOST)
            | Some(CANISTER_HOST)
            | Some(RAW_CANISTER_HOST)
            | Some("id.ai")
            | Some("identity.internetcomputer.org")
            | Some("identity.ic0.app")
    )
}

fn is_local_error_url(url: &Url) -> bool {
    matches!(url.as_str(), ERROR_START_URL | ERROR_PAGE_URL)
}

#[cfg(test)]
mod tests;

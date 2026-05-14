mod config;
mod init_script;
mod navigation;
mod share;

use init_script::init_script;
use navigation::{
    bootstrap_target_url, contains_supported_deep_link, enable_ios_back_forward_gestures,
    external_initial_links, handle_navigation, open_deep_links, open_external_links,
};
use share::share_url;
use tauri::{webview::PageLoadEvent, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_deep_link::DeepLinkExt;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_deep_link::init());

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let builder = builder.on_web_content_process_terminate(|webview| {
        if let Ok(url) = navigation::error_page_url() {
            let _ = webview.navigate(url);
        }
    });

    builder
        .invoke_handler(tauri::generate_handler![share_url])
        .setup(|app| {
            let opener = app.handle().clone();
            let initial_deep_links = app.deep_link().get_current()?;
            let start_url = navigation::initial_webview_url()?;
            let bootstrap_target = bootstrap_target_url(initial_deep_links.as_deref())?;
            let webview = WebviewWindowBuilder::new(app, "main", WebviewUrl::External(start_url))
                .title("TAGGR")
                .initialization_script(init_script(&bootstrap_target))
                .on_page_load(|webview, payload| {
                    if matches!(payload.event(), PageLoadEvent::Finished) {
                        let _ = webview.eval("window.__TAGGR_IOS_HIDE_LOADING__?.()");
                    }
                })
                .on_navigation(move |url| handle_navigation(&opener, url))
                .build()?;

            enable_ios_back_forward_gestures(&webview);

            if let Some(urls) = initial_deep_links {
                if contains_supported_deep_link(&urls) {
                    open_external_links(app.handle(), external_initial_links(&urls));
                } else {
                    open_deep_links(app.handle(), &webview, urls);
                }
            }

            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                if let Some(webview) = handle.get_webview_window("main") {
                    open_deep_links(&handle, &webview, event.urls());
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run TAGGR iOS app");
}

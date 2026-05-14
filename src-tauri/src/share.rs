use std::sync::mpsc;

use url::Url;

use crate::config::APP_HOST;

#[tauri::command]
pub(crate) fn share_url(app: tauri::AppHandle, url: String) -> Result<(), String> {
    let target = validate_share_url(&url)?;
    let (sender, receiver) = mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = sender.send(present_share_sheet(target.as_str()));
    })
    .map_err(|error| error.to_string())?;

    receiver.recv().map_err(|error| error.to_string())?
}

fn validate_share_url(raw_url: &str) -> Result<Url, String> {
    let url = Url::parse(raw_url).map_err(|error| error.to_string())?;
    if url.scheme() == "https"
        && url.host_str() == Some(APP_HOST)
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
    {
        Ok(url)
    } else {
        Err("share_url only accepts TAGGR canonical HTTPS URLs".into())
    }
}

#[cfg(target_os = "ios")]
fn present_share_sheet(raw_url: &str) -> Result<(), String> {
    use objc2::MainThreadMarker;
    use objc2_foundation::{NSArray, NSString, NSURL};
    use objc2_ui_kit::{UIActivityViewController, UIApplication};

    let main_thread =
        MainThreadMarker::new().ok_or("iOS share sheet must run on the main thread")?;
    let ns_url_string = NSString::from_str(raw_url);
    let ns_url = unsafe { NSURL::URLWithString(&ns_url_string) }
        .ok_or("failed to convert TAGGR URL for iOS sharing")?;
    let activity_items = NSArray::from_slice(&[&*ns_url]);
    let activity_controller = unsafe {
        UIActivityViewController::initWithActivityItems_applicationActivities(
            UIActivityViewController::alloc(),
            &activity_items,
            None,
        )
    };
    let application = UIApplication::sharedApplication(main_thread);
    let window = application
        .keyWindow()
        .ok_or("failed to find the active iOS window")?;
    let root_controller = window
        .rootViewController()
        .ok_or("failed to find the root iOS view controller")?;
    if let Some(popover) = activity_controller.popoverPresentationController() {
        let source_view = root_controller
            .view()
            .ok_or("failed to find the root iOS view for sharing")?;
        popover.setSourceView(Some(&source_view));
    }

    root_controller.presentViewController_animated_completion(&activity_controller, true, None);
    Ok(())
}

#[cfg(not(target_os = "ios"))]
fn present_share_sheet(_raw_url: &str) -> Result<(), String> {
    Err("native share sheet is only available on iOS".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_canonical_share_url() {
        assert!(validate_share_url("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/1").is_ok());
        assert!(validate_share_url("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/1").is_ok());
        assert!(
            validate_share_url("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy").is_ok()
        );
        assert!(
            validate_share_url("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/settings#/post/1")
                .is_ok()
        );
    }

    #[test]
    fn rejects_non_canonical_share_url() {
        assert!(validate_share_url("https://example.com/#/post/1").is_err());
        assert!(validate_share_url("http://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/1").is_err());
        assert!(
            validate_share_url("https://user@6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/1")
                .is_err()
        );
        assert!(validate_share_url(
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/?token=secret#/post/1"
        )
        .is_err());
    }
}

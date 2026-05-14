use super::*;

#[test]
fn app_url_host_matches_app_host_and_tauri_remote_config() {
    assert_eq!(Url::parse(APP_URL).unwrap().host_str(), Some(APP_HOST));

    let config: serde_json::Value =
        serde_json::from_str(include_str!("../../tauri.conf.json")).unwrap();
    assert_eq!(config["build"]["devUrl"], APP_URL);
    assert_eq!(config["build"]["frontendDist"], APP_URL);
}

#[test]
fn maps_taggr_scheme_to_hash_route() {
    let url = Url::parse("taggr://post/123").unwrap();
    assert_eq!(
        map_deep_link(&url).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/123"
    );
}

#[test]
fn maps_canonical_path_to_hash_route() {
    let url = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice").unwrap();
    assert_eq!(
        map_deep_link(&url).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/alice"
    );
}

#[test]
fn maps_required_public_routes_to_hash_routes() {
    for (source, expected) in [
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/123",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/123",
        ),
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/alice",
        ),
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/realm/HELP",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/realm/HELP",
        ),
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transaction/123",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/transaction/123",
        ),
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transactions",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/transactions",
        ),
        (
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/tokens",
            "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/tokens",
        ),
    ] {
        let url = Url::parse(source).unwrap();
        assert_eq!(map_deep_link(&url).unwrap().as_str(), expected);
    }
}

#[test]
fn config_and_aasa_routes_match_deep_link_router() {
    let config: serde_json::Value =
        serde_json::from_str(include_str!("../../tauri.conf.json")).unwrap();
    let mobile = config["plugins"]["deep-link"]["mobile"]
        .as_array()
        .expect("deep-link mobile config should be an array");
    let universal = mobile
        .iter()
        .find(|entry| entry["appLink"] == true)
        .expect("universal link config should exist");
    let prefixes = universal["pathPrefix"]
        .as_array()
        .expect("universal link pathPrefix should be an array")
        .iter()
        .map(|value| value.as_str().expect("pathPrefix should be a string"))
        .collect::<Vec<_>>();
    let expected_prefixes = [
        "/post",
        "/user",
        "/realm",
        "/transaction",
        "/transactions",
        "/tokens",
    ];
    assert_eq!(prefixes, expected_prefixes);
    for prefix in prefixes {
        assert!(is_supported_public_route(prefix.trim_start_matches('/')));
    }

    let aasa: serde_json::Value = serde_json::from_str(include_str!(
        "../../../src/frontend/assets/.well-known/apple-app-site-association"
    ))
    .unwrap();
    let components = aasa["applinks"]["details"][0]["components"]
        .as_array()
        .expect("AASA components should be an array")
        .iter()
        .map(|component| {
            component["/"]
                .as_str()
                .expect("AASA path should be a string")
        })
        .collect::<Vec<_>>();
    for component in components {
        let route = component
            .trim_start_matches('/')
            .trim_end_matches("/*")
            .trim_end_matches('*');
        assert!(is_supported_public_route(route));
    }
}

#[test]
fn preserves_existing_hash_route() {
    let url = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/tokens").unwrap();
    assert_eq!(map_deep_link(&url).unwrap(), url);
}

#[test]
fn normalizes_hash_route_with_unexpected_path() {
    let url = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/settings#/post/1").unwrap();
    assert_eq!(
        map_deep_link(&url).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/1"
    );
}

#[test]
fn rejects_external_deep_link() {
    let url = Url::parse("https://example.com/post/123").unwrap();
    assert!(map_deep_link(&url).is_none());
}

#[test]
fn rejects_unsupported_deep_link_routes() {
    for raw_url in [
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/settings",
        "taggr://settings",
    ] {
        let url = Url::parse(raw_url).unwrap();
        assert!(
            map_deep_link(&url).is_none(),
            "{raw_url} should be rejected"
        );
    }
}

#[test]
fn rejects_unsupported_hash_deep_link_routes() {
    let url = Url::parse("https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/settings").unwrap();
    assert!(map_deep_link(&url).is_none());
}

#[test]
fn keeps_required_hosts_in_app() {
    for raw_url in [
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/",
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.ic0.app/#/",
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.raw.ic0.app/#/",
        "https://id.ai/",
        "https://identity.internetcomputer.org/",
        "https://identity.ic0.app/",
    ] {
        let url = Url::parse(raw_url).unwrap();
        assert!(stays_in_app(&url), "{raw_url} should stay in app");
    }
}

#[test]
fn separates_unknown_hosts_from_app() {
    for raw_url in [
        "https://example.com/",
        "http://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/",
    ] {
        let url = Url::parse(raw_url).unwrap();
        assert!(!stays_in_app(&url), "{raw_url} should open externally");
    }
}

#[test]
fn opens_external_http_navigation_outside_app() {
    for raw_url in [
        "https://example.com/",
        "http://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/",
    ] {
        let url = Url::parse(raw_url).unwrap();
        assert!(should_open_externally(&url));
    }
}

#[test]
fn does_not_open_internal_or_local_navigation_externally() {
    for raw_url in [
        ERROR_START_URL,
        ERROR_PAGE_URL,
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/",
        "https://identity.internetcomputer.org/",
        "taggr://post/1",
    ] {
        let url = Url::parse(raw_url).unwrap();
        assert!(!should_open_externally(&url));
    }
}

#[test]
fn error_start_url_is_local_blank_page() {
    assert_eq!(Url::parse(ERROR_START_URL).unwrap().as_str(), "about:blank");
}

#[test]
fn keeps_error_start_url_in_app() {
    let url = Url::parse(ERROR_START_URL).unwrap();
    assert!(is_local_error_url(&url));
}

#[test]
fn keeps_content_process_error_url_in_app() {
    let url = error_page_url().unwrap();
    assert_eq!(url.as_str(), ERROR_PAGE_URL);
    assert!(is_local_error_url(&url));
}

#[test]
fn starts_from_controlled_bootstrap_document() {
    assert_eq!(initial_webview_url().unwrap().as_str(), ERROR_START_URL);
}

#[test]
fn bootstraps_to_app_root_without_initial_deep_link() {
    assert_eq!(
        bootstrap_target_url(None).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/"
    );
}

#[test]
fn bootstraps_to_initial_deep_link_route() {
    let urls = [Url::parse("taggr://post/123").unwrap()];
    assert_eq!(
        bootstrap_target_url(Some(&urls)).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/post/123"
    );
    assert!(contains_supported_deep_link(&urls));
}

#[test]
fn unsupported_initial_links_bootstrap_to_app_root() {
    let urls = [
        Url::parse("taggr://settings").unwrap(),
        Url::parse("https://example.com/post/123").unwrap(),
    ];
    assert_eq!(
        bootstrap_target_url(Some(&urls)).unwrap().as_str(),
        "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/"
    );
    assert!(!contains_supported_deep_link(&urls));
}

#[test]
fn mixed_initial_links_keep_external_links_for_safari() {
    let urls = [
        Url::parse("taggr://post/123").unwrap(),
        Url::parse("https://example.com/post/123").unwrap(),
        Url::parse("taggr://settings").unwrap(),
    ];
    assert!(contains_supported_deep_link(&urls));
    assert_eq!(
        external_initial_links(&urls),
        vec![Url::parse("https://example.com/post/123").unwrap()]
    );
}

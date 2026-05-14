use super::*;

#[test]
fn should_serve_aasa_without_upgrade() {
    use crate::env::domains::DomainConfig;
    use std::collections::HashMap;

    let _guard = assets::ASSET_TEST_LOCK
        .lock()
        .expect("asset test lock poisoned");
    let domains = HashMap::from([("taggr.test".to_string(), DomainConfig::default())]);
    assets::load(&domains);

    for url in [
        "/.well-known/apple-app-site-association",
        "/apple-app-site-association",
    ] {
        let http_resp = http_request(HttpRequest {
            url: url.to_string(),
            headers: vec![],
        });

        assert_eq!(http_resp.status_code, 200);
        assert_eq!(http_resp.upgrade, None);
        assert!(http_resp
            .headers
            .iter()
            .any(|(name, value)| name == "Content-Type" && value == "application/json"));
        let aasa: serde_json::Value =
            serde_json::from_slice(&http_resp.body).expect("AASA should be valid JSON");
        assert_eq!(
            aasa["applinks"]["details"][0]["appIDs"][0],
            "AKN976G7AK.network.taggr.ios"
        );
    }
}

#[test]
fn should_return_proposals() {
    use crate::proposals::{Proposal, Status};
    use crate::State;

    let mut http_request_arg = HttpRequest {
        url: "/api/v1/proposals".to_string(),
        headers: vec![],
    };
    let mut state = State::default();

    for id in 0..10_u32 {
        state.proposals.push(Proposal {
            id,
            proposer: 0,
            bulletins: vec![(0, true, 1)],
            status: Status::Open,
            ..Default::default()
        });
    }
    crate::mutate(|s| *s = state);

    fn check_proposals(http_request_arg: HttpRequest, len: usize, start: u32, end: u32) {
        let http_resp = http_request(http_request_arg.clone());
        match serde_json::from_slice::<Vec<Proposal>>(&http_resp.body) {
            Ok(proposals) => {
                assert_eq!(proposals.len(), len);
                assert_eq!(proposals[0].id, start);
                assert_eq!(proposals.last().unwrap().id, end);
            }
            Err(_) => panic!("failed to deserialize json"),
        }
    }

    check_proposals(http_request_arg.clone(), 10_usize, 0_u32, 9_u32);

    http_request_arg.url = "/api/v1/proposals?limit=5".to_string();
    check_proposals(http_request_arg.clone(), 5_usize, 0_u32, 4_u32);

    http_request_arg.url = "/api/v1/proposals?limit=3&offset=6".to_string();
    check_proposals(http_request_arg.clone(), 3_usize, 6_u32, 8_u32);

    http_request_arg.url = "/api/v1/proposals?offset=6&limit=3".to_string();
    check_proposals(http_request_arg.clone(), 3_usize, 6_u32, 8_u32);
}

#[test]
fn should_return_metadata() {
    use crate::proposals::{Proposal, Status};
    use crate::State;

    let mut state = State::default();

    for id in 0..10_u32 {
        state.proposals.push(Proposal {
            id,
            proposer: 0,
            bulletins: vec![(0, true, 1)],
            status: Status::Open,
            ..Default::default()
        });
    }
    crate::mutate(|s| *s = state);

    let http_resp = http_request(HttpRequest {
        url: "/api/v1/metadata".to_string(),
        headers: vec![],
    });
    match serde_json::from_slice::<Metadata>(&http_resp.body) {
        Ok(metadata) => {
            assert_eq!(metadata, Metadata {
                decimals: 2,
                symbol: "TAGGR",
                token_name: "Taggr",
                fee: 10,
                logo: "data:image/png;base64,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",
                maximum_supply: 100000000,
                total_supply: 0,
                latest_proposal_id: Some(
                    9,
                ),
                proposal_count: 10,
            });
        }
        Err(_) => panic!("failed to deserialize json"),
    }
}

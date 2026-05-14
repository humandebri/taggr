use super::assets;
use crate::assets::{index_html_headers, INDEX_HTML};
use crate::post::Post;
use crate::read;
use crate::{config::CONFIG, metadata::set_metadata};
use candid::CandidType;
use serde::{Deserialize, Serialize};
use serde_bytes::ByteBuf;

pub type Headers = Vec<(String, String)>;

#[derive(Clone, CandidType, Deserialize)]
pub struct HttpRequest {
    url: String,
    headers: Headers,
}

impl HttpRequest {
    pub fn path(&self) -> &str {
        match self.url.find('?') {
            None => &self.url[..],
            Some(index) => &self.url[..index],
        }
    }

    /// Searches for the first appearance of a parameter in the request URL.
    /// Returns `None` if the given parameter does not appear in the query.
    pub fn raw_query_param(&self, param: &str) -> Option<&str> {
        const QUERY_SEPARATOR: &str = "?";
        let query_string = self.url.split(QUERY_SEPARATOR).nth(1)?;
        if query_string.is_empty() {
            return None;
        }
        const PARAMETER_SEPARATOR: &str = "&";
        for chunk in query_string.split(PARAMETER_SEPARATOR) {
            const KEY_VALUE_SEPARATOR: &str = "=";
            let mut split = chunk.splitn(2, KEY_VALUE_SEPARATOR);
            let name = split.next()?;
            if name == param {
                return Some(split.next().unwrap_or_default());
            }
        }
        None
    }
}

#[derive(Debug, Default, CandidType, Serialize)]
pub struct HttpResponse {
    status_code: u16,
    headers: Headers,
    body: ByteBuf,
    upgrade: Option<bool>,
}

#[ic_cdk_macros::update]
fn http_request_update(req: HttpRequest) -> HttpResponse {
    let url = &req.url;
    route(url)
        .map(|(headers, body)| HttpResponse {
            status_code: 200,
            headers,
            body,
            upgrade: None,
        })
        .unwrap_or_else(|| HttpResponse {
            status_code: 400,
            ..Default::default()
        })
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
struct Metadata<'a> {
    decimals: u8,
    symbol: &'a str,
    token_name: &'a str,
    fee: u64,
    logo: &'a str,
    maximum_supply: u64,
    total_supply: u64,
    latest_proposal_id: Option<u32>,
    proposal_count: u64,
}

#[ic_cdk_macros::query]
fn http_request(req: HttpRequest) -> HttpResponse {
    let path = &req.url;

    use serde_json;
    use std::str::FromStr;

    let mut parts = req.path().split('/').filter(|part| !part.is_empty());

    match (parts.next(), parts.next(), parts.next()) {
        (Some("api"), Some("v1"), Some("proposals")) => read(|state| {
            let offset = usize::from_str(req.raw_query_param("offset").unwrap_or_default())
                .unwrap_or_default()
                .min(state.proposals.len());
            let limit = usize::from_str(req.raw_query_param("limit").unwrap_or_default())
                .unwrap_or(1_000_usize);
            let end = (offset + limit).min(state.proposals.len());

            let proposal_slice = state.proposals.get(offset..end).unwrap_or_default();
            HttpResponse {
                status_code: 200,
                headers: vec![(
                    "Content-Type".to_string(),
                    "application/json; charset=UTF-8".to_string(),
                )],
                body: ByteBuf::from(serde_json::to_vec(&proposal_slice).unwrap_or_default()),
                upgrade: None,
            }
        }),
        (Some("api"), Some("v1"), Some("metadata")) => {
            use base64::{engine::general_purpose, Engine as _};
            read(|s| HttpResponse {
                status_code: 200,
                headers: vec![(
                    "Content-Type".to_string(),
                    "application/json; charset=UTF-8".to_string(),
                )],
                body: ByteBuf::from(
                    serde_json::to_vec(&Metadata {
                        decimals: CONFIG.token_decimals,
                        symbol: CONFIG.token_symbol,
                        token_name: CONFIG.name,
                        fee: CONFIG.transaction_fee,
                        logo: &format!(
                            "data:image/png;base64,{}",
                            general_purpose::STANDARD
                                .encode(include_bytes!("../frontend/assets/apple-touch-icon.png"))
                        ),
                        maximum_supply: CONFIG.maximum_supply,
                        total_supply: s.balances.values().copied().sum::<u64>(),
                        latest_proposal_id: s.proposals.last().map(|p| p.id),
                        proposal_count: s.proposals.len() as u64,
                    })
                    .unwrap_or_default(),
                ),
                upgrade: None,
            })
        }
        _ => {
            // If the asset is certified, return it, otherwise, upgrade to http_request_update.
            if let Some((headers, body)) = assets::asset_certified(path) {
                HttpResponse {
                    status_code: 200,
                    headers,
                    body,
                    upgrade: None,
                }
            } else {
                HttpResponse {
                    status_code: 200,
                    upgrade: Some(true),
                    ..Default::default()
                }
            }
        }
    }
}

fn route(url: &str) -> Option<(Headers, ByteBuf)> {
    read(|state| {
        let filter = |val: &str| {
            val.chars()
                .filter(|c| c.is_alphanumeric() || " .,?!-:/@\n#".chars().any(|v| &v == c))
                .collect::<String>()
        };
        let mut parts = url.split('/');
        let domain = parts.next()?;
        match (parts.next(), parts.next()) {
            (Some("post"), Some(id)) | (Some("thread"), Some(id)) => {
                if let Some(post) = Post::get(state, &id.parse::<u64>().ok()?) {
                    return index(
                        domain,
                        &format!(
                            "{}/{}",
                            match post.parent {
                                None => "post",
                                _ => "thread",
                            },
                            post.id
                        ),
                        &format!(
                            "{} #{} by @{}",
                            match post.parent {
                                None => "Post",
                                _ => "Reply",
                            },
                            post.id,
                            state.users.get(&post.user)?.name
                        ),
                        &filter(&post.body),
                        "article",
                    );
                }
                None
            }
            (Some("journal"), Some(handle)) => {
                let user = state.user(handle)?;
                index(
                    domain,
                    &format!("journal/{}", user.name),
                    &format!("@{}'s journal", user.name),
                    &filter(&user.about),
                    "website",
                )
            }
            (Some("user"), Some(handle)) => {
                let user = state.user(handle)?;
                index(
                    domain,
                    &format!("user/{}", user.name),
                    &format!("User @{}", user.name),
                    &filter(&user.about),
                    "profile",
                )
            }
            (Some("realm"), Some(arg)) => {
                let id = arg.to_uppercase();
                let realm = state.realms.get(&id)?;
                index(
                    domain,
                    &format!("realm/{}", id),
                    &format!("Realm {}", id),
                    &filter(&realm.description),
                    "website",
                )
            }
            (Some("feed"), Some(filter)) => index(
                domain,
                &format!("feed/{}", filter),
                filter,
                &format!("Latest posts on {}", filter),
                "website",
            ),
            _ => assets::asset("/"),
        }
    })
}

fn index(
    host: &str,
    path: &str,
    title: &str,
    desc: &str,
    page_type: &str,
) -> Option<(Headers, ByteBuf)> {
    Some((
        index_html_headers(),
        ByteBuf::from(set_metadata(INDEX_HTML, host, path, title, desc, page_type)),
    ))
}

#[cfg(test)]
mod test;

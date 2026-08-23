use candid::Principal;
use env::{config::CONFIG, user::User, State, *};
use ic_cdk::{api::msg_reply, export_candid};
use std::{cell::RefCell, collections::HashMap};

mod assets;
#[cfg(feature = "dev")]
mod dev_helpers;
mod env;
mod http;
mod metadata;
mod queries;
mod updates;

const BACKUP_PAGE_SIZE: u32 = 1024 * 1024;

thread_local! {
    static STATE: RefCell<State> = Default::default();
    #[cfg(test)]
    pub static TEST_TIME: RefCell<Time> = Default::default();
}

pub fn read<F, R>(f: F) -> R
where
    F: FnOnce(&State) -> R,
{
    STATE.with(|cell| f(&cell.borrow()))
}

pub fn mutate<F, R>(f: F) -> R
where
    F: FnOnce(&mut State) -> R,
{
    STATE.with(|cell| f(&mut cell.borrow_mut()))
}

fn parse<'a, T: serde::Deserialize<'a>>(bytes: &'a [u8]) -> T {
    serde_json::from_slice(bytes).expect("couldn't parse the input")
}

fn reply<T: serde::Serialize>(data: T) {
    msg_reply(serde_json::json!(data).to_string().as_bytes());
}

fn stable_to_heap_core() {
    STATE.with(|cell| cell.replace(env::memory::stable_to_heap()));
    mutate(|state| state.init());
}

fn optional(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

pub fn performance_counter(_n: u32) -> u64 {
    #[cfg(test)]
    return 0;
    #[cfg(not(test))]
    ic_cdk::api::performance_counter(_n)
}
pub fn id() -> Principal {
    #[cfg(test)]
    // Mocked Id for tests.
    return Principal::from_text("6qfxa-ryaaa-aaaai-qbhsq-cai").expect("parsing failed");
    #[cfg(not(test))]
    ic_cdk::api::canister_self()
}

pub fn time() -> u64 {
    #[cfg(test)]
    return TEST_TIME.with(|cell| *cell.borrow());
    #[cfg(not(test))]
    ic_cdk::api::time()
}

fn require_push_relay() -> Result<(), String> {
    authorize_push_relay(
        ic_cdk::api::msg_caller(),
        option_env!("TAGGR_PUSH_RELAY_PRINCIPAL"),
    )
}

fn authorize_push_relay(caller: Principal, configured: Option<&str>) -> Result<(), String> {
    let configured = configured
        .ok_or("push relay is not configured")
        .and_then(|value| {
            Principal::from_text(value).map_err(|_| "invalid push relay principal")
        })?;
    if caller != configured {
        return Err("push relay authentication required".into());
    }
    Ok(())
}

#[allow(unused_imports)]
use crate::env::{
    post::{FileRef, PostId},
    user::UserId,
};
use crate::http::{HttpRequest, HttpResponse};
#[allow(unused_imports)]
use crate::realms::RealmId;
use crate::token::{Account, Standard, TransferArgs, TransferError, Value};
use icrc_ledger_types::icrc3::transactions::{GetTransactionsRequest, GetTransactionsResponse};
use icrc_ledger_types::icrc3::{
    archive::{GetArchivesArgs, GetArchivesResult},
    blocks::{GetBlocksRequest, GetBlocksResult, ICRC3DataCertificate, SupportedBlockType},
};
#[allow(unused_imports)]
use serde_bytes::ByteBuf;
export_candid!();

#[cfg(test)]
mod push_relay_auth_tests {
    use super::*;

    #[test]
    fn only_the_configured_relay_principal_is_authorized() {
        let relay = Principal::from_slice(&[1]);
        let other = Principal::from_slice(&[2]);
        let configured = relay.to_text();
        assert!(authorize_push_relay(relay, Some(&configured)).is_ok());
        assert!(authorize_push_relay(other, Some(&configured)).is_err());
        assert!(authorize_push_relay(relay, None).is_err());
    }
}

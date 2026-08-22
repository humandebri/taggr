use super::*;

pub const PUSH_KIND_REPLY: u8 = 1;
pub const PUSH_KIND_MENTION: u8 = 2;
pub const PUSH_KIND_REPOST: u8 = 4;
pub const PUSH_KIND_WATCHED: u8 = 8;
pub const PUSH_KIND_ALL: u8 =
    PUSH_KIND_REPLY | PUSH_KIND_MENTION | PUSH_KIND_REPOST | PUSH_KIND_WATCHED;

const MAX_INSTALLATIONS_PER_USER: usize = 5;
const MAX_PUSH_EVENTS: usize = 10_000;
const PUSH_EVENT_RETENTION: u64 = 7 * DAY;
const MAX_PUSH_BATCH_SIZE: u16 = 100;

#[derive(Clone, Debug, CandidType, Deserialize, Serialize, PartialEq)]
pub struct PushInstallation {
    pub user_id: UserId,
    pub secret_hash: String,
    pub token_hash: String,
    pub enabled_kinds: u8,
    pub updated_at: Time,
}

#[derive(Clone, Debug, CandidType, Deserialize, Serialize, PartialEq)]
pub struct PushInstallationResolution {
    pub user_id: UserId,
    pub enabled_kinds: u8,
}

#[derive(Clone, Debug, CandidType, Deserialize, Serialize, PartialEq)]
pub struct PushInvalidation {
    pub installation_id: String,
    pub token_hash: String,
}

#[derive(Clone, Debug, CandidType, Deserialize, Serialize, PartialEq)]
pub struct PushEvent {
    pub id: u64,
    pub recipient: UserId,
    pub notification_id: u64,
    pub kind: u8,
    pub author_name: String,
    pub preview: String,
    pub post_id: PostId,
    pub watched_post_id: Option<PostId>,
    pub unread_count: u64,
    pub created_at: Time,
    pub installation_ids: Vec<String>,
}

#[derive(Clone, Debug, CandidType, Deserialize, Serialize, PartialEq)]
pub struct PushBatch {
    pub oldest_available_id: u64,
    pub latest_id: u64,
    pub events: Vec<PushEvent>,
}

fn validate_hex(value: &str, bytes: usize, label: &str) -> Result<(), String> {
    if value.len() != bytes * 2 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!(
            "{label} must be {} hexadecimal characters",
            bytes * 2
        ));
    }
    Ok(())
}

fn validate_installation_id(installation_id: &str) -> Result<(), String> {
    if installation_id.len() != 36
        || installation_id
            .chars()
            .enumerate()
            .any(|(index, ch)| match index {
                8 | 13 | 18 | 23 => ch != '-',
                _ => !ch.is_ascii_hexdigit(),
            })
    {
        return Err("installation_id must be a UUID".into());
    }
    Ok(())
}

pub fn secret_hash(binding_secret: &str) -> Result<String, String> {
    validate_hex(binding_secret, 32, "binding_secret")?;
    Ok(hex::encode(Sha256::digest(binding_secret.as_bytes())))
}

impl State {
    pub fn register_push_installation(
        &mut self,
        principal: Principal,
        installation_id: String,
        binding_secret: String,
        token_hash: String,
        enabled_kinds: u8,
    ) -> Result<(), String> {
        validate_installation_id(&installation_id)?;
        validate_hex(&token_hash, 32, "token_hash")?;
        if enabled_kinds == 0 || enabled_kinds & !PUSH_KIND_ALL != 0 {
            return Err("enabled_kinds must contain at least one known push kind".into());
        }
        let secret_hash = secret_hash(&binding_secret)?;
        let user = self.principal_to_user(principal).ok_or("user not found")?;
        if user.deactivated {
            return Err("deactivated users cannot register push notifications".into());
        }
        let user_id = user.id;

        if let Some(existing) = self.push_installations.get(&installation_id) {
            if existing.secret_hash != secret_hash {
                return Err("installation proof rejected".into());
            }
        } else if self
            .push_installations
            .values()
            .filter(|installation| installation.user_id == user_id)
            .count()
            >= MAX_INSTALLATIONS_PER_USER
        {
            return Err(format!(
                "cannot register more than {MAX_INSTALLATIONS_PER_USER} installations"
            ));
        }

        self.push_installations.insert(
            installation_id,
            PushInstallation {
                user_id,
                secret_hash,
                token_hash: token_hash.to_ascii_lowercase(),
                enabled_kinds,
                updated_at: time(),
            },
        );
        Ok(())
    }

    pub fn update_push_preferences(
        &mut self,
        principal: Principal,
        installation_id: String,
        binding_secret: String,
        enabled_kinds: u8,
    ) -> Result<(), String> {
        validate_installation_id(&installation_id)?;
        if enabled_kinds == 0 || enabled_kinds & !PUSH_KIND_ALL != 0 {
            return Err("enabled_kinds must contain at least one known push kind".into());
        }
        let user_id = self
            .principal_to_user(principal)
            .ok_or("user not found")?
            .id;
        let hash = secret_hash(&binding_secret)?;
        let installation = self
            .push_installations
            .get_mut(&installation_id)
            .ok_or("installation not found")?;
        if installation.user_id != user_id || installation.secret_hash != hash {
            return Err("installation proof rejected".into());
        }
        installation.enabled_kinds = enabled_kinds;
        installation.updated_at = time();
        Ok(())
    }

    pub fn remove_push_installation(
        &mut self,
        principal: Principal,
        installation_id: String,
        binding_secret: String,
    ) -> Result<(), String> {
        validate_installation_id(&installation_id)?;
        let user_id = self
            .principal_to_user(principal)
            .ok_or("user not found")?
            .id;
        let hash = secret_hash(&binding_secret)?;
        match self.push_installations.get(&installation_id) {
            Some(installation)
                if installation.user_id == user_id && installation.secret_hash == hash => {}
            Some(_) => return Err("installation proof rejected".into()),
            None => return Ok(()),
        }
        self.push_installations.remove(&installation_id);
        Ok(())
    }

    pub fn resolve_push_installation(
        &self,
        installation_id: String,
        secret_hash: String,
        token_hash: String,
    ) -> Result<PushInstallationResolution, String> {
        validate_installation_id(&installation_id)?;
        validate_hex(&secret_hash, 32, "secret_hash")?;
        validate_hex(&token_hash, 32, "token_hash")?;
        let installation = self
            .push_installations
            .get(&installation_id)
            .ok_or("installation not found")?;
        if installation.secret_hash != secret_hash.to_ascii_lowercase()
            || installation.token_hash != token_hash.to_ascii_lowercase()
        {
            return Err("installation proof rejected".into());
        }
        Ok(PushInstallationResolution {
            user_id: installation.user_id,
            enabled_kinds: installation.enabled_kinds,
        })
    }

    pub fn invalidate_push_installations(&mut self, invalidations: Vec<PushInvalidation>) {
        for invalidation in invalidations.into_iter().take(100) {
            let remove = self
                .push_installations
                .get(&invalidation.installation_id)
                .map(|installation| {
                    installation.token_hash == invalidation.token_hash.to_ascii_lowercase()
                })
                .unwrap_or(false);
            if remove {
                self.push_installations
                    .remove(&invalidation.installation_id);
            }
        }
    }

    pub fn push_events(&self, after_id: u64, limit: u16) -> PushBatch {
        let limit = limit.min(MAX_PUSH_BATCH_SIZE) as usize;
        let cutoff = time().saturating_sub(PUSH_EVENT_RETENTION);
        let oldest_available_id = self
            .push_events
            .iter()
            .find(|event| event.created_at >= cutoff)
            .map(|event| event.id)
            .unwrap_or(self.next_push_event_id);
        PushBatch {
            oldest_available_id,
            latest_id: self.next_push_event_id.saturating_sub(1),
            events: self
                .push_events
                .iter()
                .filter(|event| event.created_at >= cutoff && event.id > after_id)
                .take(limit)
                .cloned()
                .collect(),
        }
    }

    pub fn prune_push_events(&mut self, now: u64) {
        let cutoff = now.saturating_sub(PUSH_EVENT_RETENTION);
        while self
            .push_events
            .front()
            .map(|event| event.created_at < cutoff)
            .unwrap_or(false)
        {
            self.push_events.pop_front();
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn enqueue_push_event(
        &mut self,
        recipient: UserId,
        notification_id: u64,
        kind: u8,
        author_name: String,
        preview: String,
        post_id: PostId,
        watched_post_id: Option<PostId>,
    ) {
        let installation_ids = self
            .push_installations
            .iter()
            .filter(|(_, installation)| {
                installation.user_id == recipient && installation.enabled_kinds & kind != 0
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        if installation_ids.is_empty() {
            return;
        }
        let unread_count = self
            .users
            .get(&recipient)
            .map(|user| {
                user.notifications
                    .values()
                    .filter(|(_, read)| !read)
                    .count() as u64
            })
            .unwrap_or_default();
        let created_at = time();
        // Cursor zero means "nothing processed" in the relay, so event IDs start at one.
        let id = self.next_push_event_id.max(1);
        self.next_push_event_id = id.saturating_add(1);
        self.push_events.push_back(PushEvent {
            id,
            recipient,
            notification_id,
            kind,
            author_name,
            preview,
            post_id,
            watched_post_id,
            unread_count,
            created_at,
            installation_ids,
        });
        self.prune_push_events(created_at);
        while self.push_events.len() > MAX_PUSH_EVENTS {
            self.push_events.pop_front();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::tests::{create_user, pr};

    const INSTALLATION_ID: &str = "01234567-89ab-cdef-0123-456789abcdef";
    const SECRET: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const TOKEN_HASH: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";

    #[test]
    fn installation_proof_and_limit_are_enforced() {
        let mut state = State::default();
        create_user(&mut state, pr(1));
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_ALL,
            )
            .unwrap();
        assert_eq!(state.push_installations.len(), 1);
        let updated_token = "12".repeat(32);
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                updated_token.clone(),
                PUSH_KIND_MENTION,
            )
            .unwrap();
        let resolution = state
            .resolve_push_installation(
                INSTALLATION_ID.into(),
                secret_hash(SECRET).unwrap(),
                updated_token,
            )
            .unwrap();
        assert_eq!(resolution.enabled_kinds, PUSH_KIND_MENTION);

        for index in 1..MAX_INSTALLATIONS_PER_USER {
            state
                .register_push_installation(
                    pr(1),
                    format!("01234567-89ab-cdef-0123-{index:012x}"),
                    SECRET.into(),
                    TOKEN_HASH.into(),
                    PUSH_KIND_ALL,
                )
                .unwrap();
        }
        assert!(state
            .register_push_installation(
                pr(1),
                "01234567-89ab-cdef-0123-999999999999".into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_ALL,
            )
            .is_err());
        assert!(state
            .remove_push_installation(pr(1), INSTALLATION_ID.into(), "00".repeat(32))
            .is_err());
        assert_eq!(state.push_installations.len(), MAX_INSTALLATIONS_PER_USER);
    }

    #[test]
    fn event_targets_only_enabled_installations() {
        let mut state = State::default();
        let user_id = create_user(&mut state, pr(1));
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_REPLY,
            )
            .unwrap();
        state.enqueue_push_event(
            user_id,
            1,
            PUSH_KIND_MENTION,
            "a".into(),
            "b".into(),
            2,
            None,
        );
        assert!(state.push_events.is_empty());
        state.enqueue_push_event(user_id, 1, PUSH_KIND_REPLY, "a".into(), "b".into(), 2, None);
        assert_eq!(state.push_events.len(), 1);
    }

    #[test]
    fn event_queue_is_bounded_and_reports_recovery_cursor() {
        let mut state = State::default();
        let user_id = create_user(&mut state, pr(1));
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_REPLY,
            )
            .unwrap();
        for notification_id in 0..=MAX_PUSH_EVENTS {
            state.enqueue_push_event(
                user_id,
                notification_id as u64,
                PUSH_KIND_REPLY,
                "author".into(),
                "preview".into(),
                notification_id as u64,
                None,
            );
        }
        assert_eq!(state.push_events.len(), MAX_PUSH_EVENTS);
        let batch = state.push_events(0, 1);
        assert_eq!(batch.oldest_available_id, 2);
        assert_eq!(batch.latest_id, MAX_PUSH_EVENTS as u64 + 1);
        assert_eq!(batch.events[0].id, 2);
    }

    #[test]
    fn events_older_than_seven_days_are_pruned() {
        crate::TEST_TIME.with(|time| *time.borrow_mut() = 1);
        let mut state = State::default();
        let user_id = create_user(&mut state, pr(1));
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_REPLY,
            )
            .unwrap();
        state.enqueue_push_event(user_id, 1, PUSH_KIND_REPLY, "a".into(), "b".into(), 1, None);
        crate::TEST_TIME.with(|time| *time.borrow_mut() = PUSH_EVENT_RETENTION + 2);
        state.enqueue_push_event(user_id, 2, PUSH_KIND_REPLY, "a".into(), "b".into(), 2, None);
        assert_eq!(state.push_events.len(), 1);
        assert_eq!(state.push_events[0].notification_id, 2);
        crate::TEST_TIME.with(|time| *time.borrow_mut() = 0);
    }

    #[test]
    fn expired_events_are_hidden_and_pruned_without_a_new_event() {
        crate::TEST_TIME.with(|time| *time.borrow_mut() = 1);
        let mut state = State::default();
        let user_id = create_user(&mut state, pr(1));
        state
            .register_push_installation(
                pr(1),
                INSTALLATION_ID.into(),
                SECRET.into(),
                TOKEN_HASH.into(),
                PUSH_KIND_REPLY,
            )
            .unwrap();
        state.enqueue_push_event(user_id, 1, PUSH_KIND_REPLY, "a".into(), "b".into(), 1, None);

        let now = PUSH_EVENT_RETENTION + 2;
        crate::TEST_TIME.with(|time| *time.borrow_mut() = now);
        let batch = state.push_events(0, 10);
        assert!(batch.events.is_empty());
        assert_eq!(batch.oldest_available_id, 2);
        assert_eq!(batch.latest_id, 1);
        assert_eq!(state.push_events.len(), 1);

        state.prune_push_events(now);
        assert!(state.push_events.is_empty());
        crate::TEST_TIME.with(|time| *time.borrow_mut() = 0);
    }
}

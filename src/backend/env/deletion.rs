use super::*;

#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum AccountState {
    #[default]
    Active,
    Deleting,
    Deleted,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Deletion {
    pub state: AccountState,
    pub cursor: usize,
    pub media_closed: bool,
}
impl Deletion {
    pub fn is_active(&self) -> bool {
        self.state == AccountState::Active
    }
}

#[derive(Serialize)]
pub struct Progress {
    pub state: AccountState,
    pub processed: usize,
    pub total: usize,
    pub bucket: Option<Principal>,
    pub media_closed: bool,
    pub balance: Token,
    pub treasury_e8s: u64,
    pub principal: Principal,
}

impl State {
    pub fn deletion_progress(&self, principal: Principal) -> Result<Progress, String> {
        let u = self.principal_to_user(principal).ok_or("user not found")?;
        Ok(Progress {
            state: u.deletion.state.clone(),
            processed: u.deletion.cursor,
            total: u.posts.len(),
            bucket: u.bucket,
            media_closed: u.deletion.media_closed,
            balance: u.balance,
            treasury_e8s: u.treasury_e8s,
            principal: u.principal,
        })
    }

    pub fn begin_deletion(&mut self, principal: Principal) -> Result<Progress, String> {
        self.principal_to_user(principal).ok_or("user not found")?;
        self.principal_change_requests
            .retain(|_, source| *source != principal);
        let u = self.principal_to_user_mut(principal).unwrap();
        if !u.deletion.is_active() {
            return self.deletion_progress(principal);
        }
        let id = u.id;
        let cold_wallet = u.cold_wallet;
        let names = std::iter::once(u.name.clone())
            .chain(u.previous_names.clone())
            .filter(|n| !n.is_empty())
            .collect::<Vec<_>>();
        let posts = u.posts.iter().copied().collect::<BTreeSet<_>>();
        u.deletion.state = AccountState::Deleting;
        u.deletion.media_closed = u.bucket.is_none();
        u.name.clear();
        u.previous_names.clear();
        u.about.clear();
        u.settings.clear();
        u.controllers.clear();
        u.notifications.clear();
        u.accounting.clear();
        u.bookmarks.clear();
        u.pinned_posts.clear();
        u.feeds.clear();
        u.followees.clear();
        u.followers.clear();
        u.blacklist.clear();
        u.filters = Default::default();
        u.report = None;
        u.post_reports.clear();
        u.governance = false;
        u.stalwart = false;
        u.active_weeks = 0;
        u.controlled_realms.clear();
        u.realms.clear();
        u.invited_by = None;
        self.emergency_votes.remove(&principal);
        if let Some(cold) = cold_wallet {
            self.emergency_votes.remove(&cold);
        }
        for realm in self.realms.values_mut() {
            realm.controllers.remove(&id);
        }
        for other in self.users.values_mut() {
            other.followers.remove(&id);
            other.followees.remove(&id);
            other
                .notifications
                .retain(|_, (notification, _)| match notification {
                    Notification::NewPost(text, post) => {
                        !posts.contains(post) && !names.iter().any(|n| text.contains(n))
                    }
                    Notification::Conditional(_, Predicate::UserReportOpen(reported))
                        if *reported == id =>
                    {
                        false
                    }
                    Notification::Conditional(_, Predicate::Proposal(post))
                        if posts.contains(post) =>
                    {
                        false
                    }
                    Notification::Generic(text) | Notification::Conditional(text, _) => {
                        !names.iter().any(|n| text.contains(n))
                    }
                    Notification::WatchedPostEntries(post, entries) => {
                        !posts.contains(post) && !entries.iter().any(|p| posts.contains(p))
                    }
                });
        }
        for events in self.logger.events.values_mut() {
            events.retain(|event| !names.iter().any(|n| event.message.contains(n)));
        }
        self.backup_exists = false;
        self.deletion_progress(principal)
    }

    pub fn continue_deletion(&mut self, principal: Principal) -> Result<Progress, String> {
        let u = self.principal_to_user(principal).ok_or("user not found")?;
        if u.deletion.is_active() {
            return Err("deletion not started".into());
        }
        let cursor = u.deletion.cursor;
        let ids = u
            .posts
            .iter()
            .skip(cursor)
            .take(20)
            .copied()
            .collect::<Vec<_>>();
        for id in &ids {
            let tags = Post::get(self, id).ok_or("post not found")?.tags.clone();
            for tag in tags {
                if let Some(index) = self.tag_indexes.get_mut(&tag) {
                    index.posts.remove(id);
                }
                if self
                    .tag_indexes
                    .get(&tag)
                    .is_some_and(|index| index.posts.is_empty() && index.subscribers == 0)
                {
                    self.tag_indexes.remove(&tag);
                }
            }
            Post::mutate(self, id, |post| {
                post.erase_account_content();
                Ok(())
            })?;
            self.principal_to_user_mut(principal)
                .unwrap()
                .deletion
                .cursor += 1;
        }
        let u = self.principal_to_user_mut(principal).unwrap();
        if u.deletion.cursor == u.posts.len() && u.deletion.media_closed {
            u.deletion.state = AccountState::Deleted;
        }
        self.backup_exists = false;
        self.deletion_progress(principal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::tests::{create_user_with_credits, pr};

    #[test]
    fn deletion_cancels_migrations_and_rejects_stale_confirmations() {
        let mut state = State::default();
        let id = create_user_with_credits(&mut state, pr(1), 0);
        create_user_with_credits(&mut state, pr(2), 0);
        state
            .request_principal_change(pr(1), pr(3).to_text())
            .unwrap();
        state
            .request_principal_change(pr(2), pr(4).to_text())
            .unwrap();
        state.begin_deletion(pr(1)).unwrap();
        assert!(!state.principal_change_requests.contains_key(&pr(3)));
        assert_eq!(state.principal_change_requests.get(&pr(4)), Some(&pr(2)));
        assert!(state.change_principal(pr(3)).is_err());
        for deletion in [AccountState::Deleting, AccountState::Deleted] {
            state.users.get_mut(&id).unwrap().deletion.state = deletion;
            state.principal_change_requests.insert(pr(3), pr(1));
            assert!(state.change_principal(pr(3)).is_err());
            assert_eq!(state.principals.get(&pr(1)), Some(&id));
            assert!(!state.principals.contains_key(&pr(3)));
            assert!(state
                .new_user(pr(1), 0, "replacement".into(), Some(0))
                .is_err());
            state.begin_deletion(pr(1)).unwrap();
            assert!(!state.principal_change_requests.contains_key(&pr(3)));
        }
        state.change_principal(pr(4)).unwrap();
        assert!(state.principal_to_user(pr(4)).is_some());
    }

    #[test]
    fn deletion_is_free_resumable_and_preserves_replies_and_assets() {
        let mut state = State::default();
        let id = create_user_with_credits(&mut state, pr(1), 0);
        let other = create_user_with_credits(&mut state, pr(2), 0);
        {
            let u = state.users.get_mut(&id).unwrap();
            u.about = "private biography".into();
            u.previous_names.push("old-name".into());
            u.balance = 123;
            u.rewards = 100;
            u.treasury_e8s = 456;
            u.posts = (0..41).collect();
        }
        for n in 0..41 {
            let mut post = Post::default();
            post.id = n;
            post.user = id;
            post.body = "private body".into();
            post.patches.push((1, "private history".into()));
            if n == 0 {
                post.children.push(99);
            }
            state.posts.insert(n, post);
        }
        let mut reply = Post::default();
        reply.id = 99;
        reply.user = other;
        reply.parent = Some(0);
        reply.body = "other user's reply".into();
        state.posts.insert(99, reply);
        state.domains.insert("test".into(), Default::default());
        state.next_post_id = 100;
        archive_cold_posts(&mut state, 0).unwrap();
        assert!(state.begin_deletion(pr(9)).is_err());
        assert_eq!(
            state.begin_deletion(pr(1)).unwrap().state,
            AccountState::Deleting
        );
        assert!(!Post::get(&state, &0).unwrap().publicly_available(&state));
        let public = Post::get(&state, &0).unwrap().public_content(&state);
        assert!(public.body.is_empty() && public.patches.is_empty() && public.is_deleted());
        assert!(state.user(&id.to_string()).is_none());
        assert!(super::super::search::search("test".into(), &state, "private".into()).is_empty());
        assert_eq!(state.last_posts("test".into(), None, 0, 0, true).count(), 1);
        assert_eq!(state.continue_deletion(pr(1)).unwrap().processed, 20);
        assert_eq!(state.begin_deletion(pr(1)).unwrap().processed, 20);
        let saved = serde_cbor::to_vec(&state.users[&id]).unwrap();
        let restored: User = serde_cbor::from_slice(&saved).unwrap();
        state.users.insert(id, restored);
        assert_eq!(state.continue_deletion(pr(1)).unwrap().processed, 40);
        assert_eq!(
            state.continue_deletion(pr(1)).unwrap().state,
            AccountState::Deleted
        );
        assert_eq!(
            state.continue_deletion(pr(1)).unwrap().state,
            AccountState::Deleted
        );
        state
            .users
            .get_mut(&id)
            .unwrap()
            .change_rewards(50, "new reward");
        let u = &state.users[&id];
        assert_eq!(u.mode, Mode::Mining);
        assert_eq!(u.rewards(), 100);
        assert!(u.name.is_empty() && u.about.is_empty() && u.previous_names.is_empty());
        assert_eq!((u.balance, u.treasury_e8s, u.credits()), (123, 456, 0));
        for n in 0..41 {
            let p = Post::get(&state, &n).unwrap();
            assert!(p.is_deleted() && p.body.is_empty() && p.patches.is_empty());
        }
        assert_eq!(state.posts[&0].children, vec![99]);
        assert_eq!(state.posts[&99].body, "other user's reply");
        assert!(state
            .new_user(pr(1), 0, "new-name".into(), Some(0))
            .is_err());
    }

    #[test]
    fn media_confirmation_is_required_even_without_posts() {
        let mut state = State::default();
        let id = create_user_with_credits(&mut state, pr(1), 0);
        state.users.get_mut(&id).unwrap().bucket = Some(pr(8));
        state.begin_deletion(pr(1)).unwrap();
        assert_eq!(
            state.continue_deletion(pr(1)).unwrap().state,
            AccountState::Deleting
        );
        state.users.get_mut(&id).unwrap().deletion.media_closed = true;
        assert_eq!(
            state.continue_deletion(pr(1)).unwrap().state,
            AccountState::Deleted
        );
    }

    #[test]
    fn older_user_records_default_to_active() {
        let mut state = State::default();
        let id = create_user_with_credits(&mut state, pr(1), 0);
        let mut value = serde_json::to_value(&state.users[&id]).unwrap();
        value.as_object_mut().unwrap().remove("deletion");
        let user: User = serde_json::from_value(value).unwrap();
        assert!(user.deletion.is_active());
    }
}

CREATE TABLE reports (
    id TEXT PRIMARY KEY,
    canister_id TEXT NOT NULL,
    user_id INTEGER NOT NULL CHECK(user_id >= 0),
    post_id INTEGER CHECK(post_id >= 0),
    reason TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    closed_at INTEGER
);
CREATE INDEX reports_open ON reports(closed_at, received_at);
-- Append-only decisions preserve the reason and time of each restriction and restoration.
CREATE TABLE restrictions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    canister_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('post','user')),
    target_id INTEGER NOT NULL CHECK(target_id >= 0),
    active INTEGER NOT NULL CHECK(active IN (0,1)),
    reason TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX restrictions_target ON restrictions(canister_id, kind, target_id, id);

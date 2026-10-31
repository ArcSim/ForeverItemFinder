-- The website's shared finds. finds: one row per item; sources: where players got it; seen: which installs shared it
-- (an anonymous id, never a name), so an item shared by two players counts as confirmed; shares: how often one address
-- shared lately (a salted hash of it, kept two hours).
CREATE TABLE IF NOT EXISTS finds (
  id INTEGER PRIMARY KEY,
  k TEXT NOT NULL,
  q INTEGER, il INTEGER, rq INTEGER, cl INTEGER, sc INTEGER, iv INTEGER,
  by TEXT,
  found_at INTEGER,
  added_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS finds_found ON finds (found_at DESC);
CREATE TABLE IF NOT EXISTS sources (
  id INTEGER NOT NULL,
  t TEXT NOT NULL,
  n TEXT NOT NULL DEFAULT '',
  npc INTEGER, lv INTEGER,
  z TEXT NOT NULL DEFAULT '',
  sz TEXT, x INTEGER, y INTEGER, m INTEGER,
  PRIMARY KEY (id, t, n, z)
);
CREATE TABLE IF NOT EXISTS seen (
  id INTEGER NOT NULL,
  sharer TEXT NOT NULL,
  PRIMARY KEY (id, sharer)
);
CREATE TABLE IF NOT EXISTS shares (
  key TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS shares_key ON shares (key, at);

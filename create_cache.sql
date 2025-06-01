CREATE UNLOGGED TABLE cache (
    id SERIAL PRIMARY KEY,
    key TEXT UNIQUE NOT NULL,
    value JSONB,
    created_at_utc TIMESTAMP DEFAULT CURRENT_TIMESTAMP);

CREATE INDEX idx_cache_key ON cache (key);

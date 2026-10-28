CREATE TABLE IF NOT EXISTS profiles (
    user_id         TEXT PRIMARY KEY,
    display_name    TEXT,
    default_city_id INTEGER NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

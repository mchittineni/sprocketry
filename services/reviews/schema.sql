CREATE TABLE IF NOT EXISTS reviews (
    id         BIGSERIAL PRIMARY KEY,
    sku        TEXT NOT NULL,
    user_id    TEXT NOT NULL,
    author     TEXT NOT NULL,
    rating     SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- One review per shopper per product.
    UNIQUE (sku, user_id)
);

CREATE INDEX IF NOT EXISTS reviews_sku_created ON reviews (sku, created_at DESC);

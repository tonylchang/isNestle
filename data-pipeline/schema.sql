-- isNestle on-device dataset schema (Milestone 0 spike).
-- Two tables: brand -> parent map, and barcode -> matched brand.
-- Lookup at scan time:
--   SELECT b.brand_name, b.parent, b.is_target
--   FROM barcodes bc JOIN brands b ON bc.brand_slug = b.brand_slug
--   WHERE bc.barcode = ?;

CREATE TABLE IF NOT EXISTS brands (
    brand_slug TEXT PRIMARY KEY,   -- OFF-style normalized slug (see common.off_slug)
    brand_name TEXT NOT NULL,      -- human-readable display name
    parent     TEXT NOT NULL,      -- owning parent company, e.g. 'Nestlé'
    is_target  INTEGER NOT NULL DEFAULT 1  -- 1 if parent is an active boycott target
);

CREATE TABLE IF NOT EXISTS barcodes (
    barcode    TEXT PRIMARY KEY,   -- UPC/EAN
    brand_slug TEXT NOT NULL,      -- the brand slug that linked this barcode to a parent
    source     TEXT,               -- provenance, e.g. 'off-search-a-licious'
    maker_override TEXT,           -- actual maker for cited reattribution rules
    override_note  TEXT,           -- human-readable note for maker_override
    match_basis    TEXT,           -- exact / inferred metadata for new app builds
    evidence_count INTEGER,        -- supporting product count when applicable
    FOREIGN KEY (brand_slug) REFERENCES brands(brand_slug)
);

CREATE INDEX IF NOT EXISTS idx_barcodes_brand ON barcodes(brand_slug);

CREATE TABLE IF NOT EXISTS exceptions (
    brand_slug   TEXT NOT NULL,
    scope_type   TEXT NOT NULL,
    scope_value  TEXT NOT NULL,
    actual_maker TEXT,
    action       TEXT NOT NULL,
    note         TEXT NOT NULL,
    source_url   TEXT NOT NULL,
    FOREIGN KEY (brand_slug) REFERENCES brands(brand_slug)
);

CREATE INDEX IF NOT EXISTS idx_exceptions_brand ON exceptions(brand_slug);

CREATE TABLE IF NOT EXISTS prefixes (
    prefix         TEXT PRIMARY KEY,
    parent         TEXT NOT NULL,
    is_target      INTEGER NOT NULL DEFAULT 1,
    evidence_count INTEGER NOT NULL,
    source         TEXT NOT NULL
);

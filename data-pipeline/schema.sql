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
    FOREIGN KEY (brand_slug) REFERENCES brands(brand_slug)
);

CREATE INDEX IF NOT EXISTS idx_barcodes_brand ON barcodes(brand_slug);

-- ========================================================================
-- DEPRECATED: File ini sudah digantikan oleh 007_consolidated_master_dedup.sql
-- Jangan jalankan file ini lagi. Gunakan 007 untuk setup idempotent lengkap.
-- ========================================================================

-- Migration 005: Add name_normalized generated column and partial unique index for dedup by name (case-insensitive)
-- Purpose: Support dedup of master_products without barcode based on normalized (lowercased, trimmed) name

-- Step 0: Drop NOT NULL constraint from barcode to allow products without barcode
ALTER TABLE master_products
ALTER COLUMN barcode DROP NOT NULL;

-- Step 1: Add generated column name_normalized (automatically maintains lower(trim(name)))
ALTER TABLE master_products
ADD COLUMN name_normalized TEXT GENERATED ALWAYS AS (LOWER(TRIM(name))) STORED;

-- Step 2: Add partial unique index on name_normalized
-- Index only applies to rows where barcode IS NULL (rows without barcode)
-- This ensures no duplicate names (case-insensitive) for barcode-less products
-- Rows WITH barcode keep their existing barcode-based dedup (unchanged)
CREATE UNIQUE INDEX idx_master_products_name_normalized_partial
ON master_products(name_normalized)
WHERE barcode IS NULL;

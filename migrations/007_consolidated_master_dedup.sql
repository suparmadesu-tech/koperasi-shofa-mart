-- ========================================================================
-- Migration 007: Consolidated Master Products Deduplication Setup
-- Purpose: Idempotent setup untuk master_products dengan dedup by barcode
--          (dengan barcode) dan dedup by name (tanpa barcode).
-- ========================================================================
-- Catatan: File ini mengkonsolidasi 005 & 006 dengan pengecekan idempotent.
-- Aman dijalankan berulang kali tanpa error, bahkan jika sebagian objeknya
-- sudah ada di database. Setiap langkah dilindungi dengan conditional logic.
-- ========================================================================

BEGIN;

-- ========================================================================
-- STEP 1: Buat tabel master_products jika belum ada (IF NOT EXISTS)
-- ========================================================================
-- Alasan idempotent: IF NOT EXISTS mencegah error jika tabel sudah ada.
-- Skema harus match dengan structure asli: UUID PK, barcode UNIQUE,
-- timestamps, dan name sebagai required field.
-- Kolom name_normalized (generated) dan barcode nullable akan ditambah/modify
-- di langkah berikutnya.

CREATE TABLE IF NOT EXISTS public.master_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  barcode TEXT UNIQUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::TEXT, NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::TEXT, NOW())
);

-- ========================================================================
-- STEP 2: Drop NOT NULL constraint dari kolom barcode
-- ========================================================================
-- Alasan: Produk tanpa barcode harus diizinkan di master_products.
-- Idempotent: ALTER COLUMN ... DROP NOT NULL adalah no-op jika constraint
--             sudah hilang, tidak error. Tidak perlu exception handler.
--             Exception handler berbahaya karena menelan semua error lain.

ALTER TABLE master_products ALTER COLUMN barcode DROP NOT NULL;

-- ========================================================================
-- STEP 3: Tambah kolom name_normalized sebagai generated column
-- ========================================================================
-- Alasan: Kolom ini menyimpan lowercase + trim dari name, digunakan sebagai
--         arbiter di partial unique index untuk dedup case-insensitive.
-- Idempotent: DO $$ BEGIN ... EXCEPTION WHEN duplicate_column THEN NULL; END $$;
--             Menangkap error HANYA jika kolom sudah ada (duplicate_column).
--             Tidak mengubah existing values (generated column otomatis).

DO $$
BEGIN
  ALTER TABLE master_products
  ADD COLUMN name_normalized TEXT GENERATED ALWAYS AS (LOWER(TRIM(name))) STORED;
EXCEPTION WHEN duplicate_column THEN
  NULL;  -- Kolom sudah ada, skip
END $$;

-- ========================================================================
-- STEP 4: Buat partial unique index pada name_normalized
-- ========================================================================
-- Alasan: Memastikan tidak ada duplicate case-insensitive names untuk rows
--         TANPA barcode. Rows DENGAN barcode tetap pakai barcode-based dedup.
--         Partial predicate (WHERE barcode IS NULL) memungkinkan multiple rows
--         dengan barcode yang sama tapi NULL pada barcode-less rows.
-- Idempotent: IF NOT EXISTS mencegah error jika index sudah ada.
--             PostgreSQL tidak akan recreate atau error.

CREATE UNIQUE INDEX IF NOT EXISTS idx_master_products_name_normalized_partial
ON public.master_products (name_normalized)
WHERE barcode IS NULL;

-- ========================================================================
-- STEP 5: Buat RPC function untuk upsert no-barcode rows
-- ========================================================================
-- Alasan: PostgREST client tidak bisa emit ON CONFLICT ... WHERE predicate
--         (partial index arbiter) lewat .upsert() API. Function ini adalah
--         workaround: menghandle dedup tanpa-barcode via direct SQL.
-- Idempotent: CREATE OR REPLACE FUNCTION otomatis menimpa function lama.
--             Tanda tangan dan logic bisa berubah tanpa error.

CREATE OR REPLACE FUNCTION public.upsert_master_products_no_barcode(rows jsonb)
RETURNS TABLE(inserted_count int, skipped_count int) 
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_inserted int;
  v_total int;
BEGIN
  -- Hitung total baris input (untuk skipped count = total - inserted)
  v_total := jsonb_array_length(rows);
  
  -- Insert dengan ON CONFLICT (name_normalized) WHERE barcode IS NULL DO NOTHING
  -- Menggunakan partial index arbiter untuk dedup case-insensitive names saja.
  WITH input_rows AS (
    SELECT (r->>'name')::text AS name
    FROM jsonb_array_elements(rows) AS r
  ),
  ins AS (
    INSERT INTO public.master_products (name, barcode)
    SELECT name, NULL 
    FROM input_rows
    WHERE name IS NOT NULL AND TRIM(name) <> ''
    ON CONFLICT (name_normalized) WHERE barcode IS NULL DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM ins;
  
  -- Return inserted_count dan skipped_count
  RETURN QUERY SELECT v_inserted, (v_total - v_inserted);
END;
$$;

-- Dokumentasi function
COMMENT ON FUNCTION public.upsert_master_products_no_barcode(jsonb) IS 
'Upsert master_products rows tanpa barcode. Dedup by name_normalized (case-insensitive). Returns (inserted_count, skipped_count). Requires partial unique index WHERE barcode IS NULL.';

COMMIT;

-- ========================================================================
-- VERIFICATION QUERIES (non-destructive, run setelah migration selesai)
-- ========================================================================
-- Jalankan setiap query di bawah untuk memastikan semua setup benar-benar aktif.

-- Verifikasi 1: Barcode nullable?
-- Expected result: barcode | YES
-- Artinya: kolom barcode allow NULL, tidak ada NOT NULL constraint
SELECT column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'master_products' AND column_name = 'barcode';

-- Verifikasi 2: name_normalized ada dan generated?
-- Expected result: name_normalized | YES | lower(btrim(name))
-- Artinya: kolom ada, is_generated=YES, expression show LOWER(TRIM(...))
SELECT column_name, is_generated, generation_expression
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'master_products' AND column_name = 'name_normalized';

-- Verifikasi 3: Index partial ada dan benar?
-- Expected result: idx_master_products_name_normalized_partial | ...WHERE (barcode IS NULL)
-- Artinya: index ada, definisi include predicate WHERE barcode IS NULL
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'master_products' AND indexname = 'idx_master_products_name_normalized_partial';

-- Verifikasi 4: Function upsert_master_products_no_barcode ada?
-- Expected result: upsert_master_products_no_barcode | public
-- Artinya: function ada di schema public, siap dipanggil via RPC
SELECT routine_name, routine_schema
FROM information_schema.routines
WHERE routine_name = 'upsert_master_products_no_barcode' AND routine_schema = 'public';

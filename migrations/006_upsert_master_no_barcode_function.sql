-- Migration 006: Postgres function untuk upsert master_products tanpa barcode dengan partial unique index predicate
-- Purpose: Workaround PostgREST limitation (tidak bisa generate ON CONFLICT ... WHERE predicate via .upsert())

CREATE OR REPLACE FUNCTION public.upsert_master_products_no_barcode(rows jsonb)
RETURNS TABLE(inserted_count int, skipped_count int) 
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_inserted int;
  v_total int;
BEGIN
  -- Hitung total baris input
  v_total := jsonb_array_length(rows);
  
  -- Insert dengan ON CONFLICT yang include WHERE predicate (partial unique index)
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
  
  -- Return inserted count dan skipped count
  RETURN QUERY SELECT v_inserted, (v_total - v_inserted);
END;
$$;

COMMENT ON FUNCTION public.upsert_master_products_no_barcode(jsonb) IS 
'Upsert master_products rows tanpa barcode. Dedup by name_normalized (case-insensitive). Requires partial unique index WHERE barcode IS NULL.';

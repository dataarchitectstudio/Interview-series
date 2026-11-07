-- =============================================================================
--  PostgreSQL Index Case Studies — Consolidated BEFORE / AFTER SQL
-- =============================================================================
--  One file, four case studies, every runnable statement pulled verbatim from
--  the matching .md write-up in this folder — collected here so you can flip
--  between BEFORE and AFTER for all of them without hunting through four docs.
--
--  Source docs (full explanation, mermaid diagrams, decision flowcharts, cheat
--  sheets, caveats — this file has only the SQL):
--    1. Postgres-Composite-Index-Column-Order-Simulation.md
--    2. Postgres-Covering-Index-INCLUDE-Columns-Simulation.md
--    3. Postgres-Fragmented-Index-Bloat-With-INCLUDE-Simulation.md
--    4. Postgres-Partial-Index-With-INCLUDE-Simulation.md
--
--  HOW TO RUN
--  ----------
--  * Target: PostgreSQL 12+ (case study 3 uses REINDEX ... CONCURRENTLY, PG 12+;
--    everything else works on PG 11+). Use a throwaway database:
--        createdb idx_lab   &&   psql idx_lab -f Postgres-Index-Case-Studies-Before-After.sql
--  * Each case study is SELF-CONTAINED: it starts with `DROP TABLE IF EXISTS
--    orders` and loads its own ~5,000,000-row dataset (~30-60s each). Running
--    the whole file top-to-bottom works — case study 2 drops and rebuilds the
--    table case study 1 left behind, and so on.
--  * To compare just ONE case study, copy that section (between its
--    "CASE STUDY N" banner and the next one) into its own script.
--  * `REINDEX INDEX CONCURRENTLY` (case study 3) cannot run inside a
--    transaction block — if your client wraps the whole file in one
--    transaction, run that section separately.
--  * In psql, run `\timing on` first to see each statement's wall-clock time
--    next to the numbers quoted in the comments below.
--  * All EXPLAIN numbers in the comments are the ILLUSTRATIVE figures from the
--    source docs — run it on your own box and read your own EXPLAIN output;
--    exact numbers depend on hardware, cache state, and PostgreSQL version.
-- =============================================================================


-- #############################################################################
-- # CASE STUDY 1 of 4 — COMPOSITE INDEX COLUMN ORDER
-- # Rule: CREATE INDEX column order matters. WHERE clause column order does not.
-- # Source: Postgres-Composite-Index-Column-Order-Simulation.md
-- #############################################################################

-- ---------------------------------------------------------------------------
-- 1.1 Setup — table + data (run once)
-- ---------------------------------------------------------------------------
-- from a shell:  createdb idx_lab   &&   psql idx_lab
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   integer        NOT NULL,
    order_status  text           NOT NULL,   -- low cardinality: 5 values
    order_date    date           NOT NULL,
    amount        numeric(10,2)  NOT NULL,
    ship_country  text           NOT NULL
);

INSERT INTO orders (customer_id, order_status, order_date, amount, ship_country)
SELECT
    (random() * 99999 + 1)::int,                                   -- 100k customers, ~50 rows each
    (ARRAY['NEW','PAID','SHIPPED','DELIVERED','CANCELLED'])[floor(random()*5 + 1)],
    DATE '2023-01-01' + (random() * 730)::int,
    (random() * 500 + 10)::numeric(10,2),
    (ARRAY['US','GB','DE','IN','AU','CA'])[floor(random()*6 + 1)]
FROM generate_series(1, 5000000);

VACUUM ANALYZE orders;   -- CRITICAL: fresh stats, or EXPLAIN lies

-- ---------------------------------------------------------------------------
-- 1.2 The query under test — SAME query for BEFORE and AFTER
-- ---------------------------------------------------------------------------
-- SELECT * FROM orders WHERE customer_id = 4242;

-- ---------------------------------------------------------------------------
-- 1.3 BEFORE — index column order does NOT match the query: (order_status, customer_id)
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_wrong ON orders (order_status, customer_id);
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE customer_id = 4242;

-- Illustrative output (your numbers vary):
--   Seq Scan on orders  (cost=0.00..106370.00 rows=51 width=57)
--                       (actual time=0.42..358.90 rows=48 loops=1)
--     Filter: (customer_id = 4242)
--     Rows Removed by Filter: 4999952        <-- read 5M rows to return 48
--     Buffers: shared hit=1090 read=54280    <-- ~55k pages (~430 MB) touched
--   Execution Time: 359.1 ms
--
-- Why: customer_id is column 2 of idx_orders_wrong; the query never filters on
-- order_status (column 1), so there is no leftmost prefix to seek on. The
-- planner ignores the index and falls back to a full Seq Scan.

-- ---------------------------------------------------------------------------
-- 1.4 AFTER — index column order matches the query: (customer_id, order_status)
-- ---------------------------------------------------------------------------
DROP INDEX idx_orders_wrong;
CREATE INDEX idx_orders_right ON orders (customer_id, order_status);
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE customer_id = 4242;   -- SAME query

-- Illustrative output:
--   Index Scan using idx_orders_right on orders
--           (cost=0.43..8.55 rows=48 width=57)
--           (actual time=0.031..0.074 rows=48 loops=1)
--     Index Cond: (customer_id = 4242)
--     Buffers: shared hit=51                 <-- 51 pages, not 55,000
--   Execution Time: 0.09 ms
--
-- customer_id is now the LEADING column, so Postgres does one root-to-leaf
-- descent and a short contiguous read.

-- ---------------------------------------------------------------------------
-- 1.5 Result — Case Study 1
-- ---------------------------------------------------------------------------
--   Metric               | BEFORE (order_status, customer_id) | AFTER (customer_id, order_status) | Improvement
--   ----------------------|-------------------------------------|------------------------------------|------------
--   Node type             | Seq Scan                            | Index Scan                         | --
--   Rows examined         | ~5,000,000                          | ~48                                 | ~100,000x
--   Buffers (8 KB pages)  | ~55,000                              | ~51                                 | ~1,000x
--   Execution time        | ~360 ms                              | ~0.09 ms                            | ~4,000x
--
-- The only change that mattered: putting the actually-filtered column first
-- in CREATE INDEX. The query text was identical.

-- ---------------------------------------------------------------------------
-- 1.6 Bonus — which index actually got used?
-- ---------------------------------------------------------------------------
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan AS times_used
FROM   pg_stat_user_indexes
WHERE  relname = 'orders'
ORDER  BY idx_scan DESC;

-- ---------------------------------------------------------------------------
-- 1.7 Cleanup (optional — skip if you're moving straight to Case Study 2,
-- which drops and rebuilds `orders` anyway)
-- ---------------------------------------------------------------------------
-- DROP TABLE IF EXISTS orders;      -- drops its indexes too
-- or from a shell:  dropdb idx_lab


-- #############################################################################
-- # CASE STUDY 2 of 4 — COVERING INDEXES & INCLUDE COLUMNS
-- # Rule: every column the query touches is in the index -> Index Only Scan,
-- # zero heap reads. Key columns seek/sort; INCLUDE columns are leaf-only payload.
-- # Source: Postgres-Covering-Index-INCLUDE-Columns-Simulation.md
-- #############################################################################

-- ---------------------------------------------------------------------------
-- 2.1 Setup — table + data (run once)
-- ---------------------------------------------------------------------------
-- from a shell:  createdb idx_lab   &&   psql idx_lab
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   integer        NOT NULL,
    order_status  text           NOT NULL,
    order_date    date           NOT NULL,
    amount        numeric(10,2)  NOT NULL,
    ship_country  text           NOT NULL
);

INSERT INTO orders (customer_id, order_status, order_date, amount, ship_country)
SELECT
    (random() * 99999 + 1)::int,                                   -- 100k customers, ~50 rows each
    (ARRAY['NEW','PAID','SHIPPED','DELIVERED','CANCELLED'])[floor(random()*5 + 1)],
    DATE '2023-01-01' + (random() * 730)::int,
    (random() * 500 + 10)::numeric(10,2),
    (ARRAY['US','GB','DE','IN','AU','CA'])[floor(random()*6 + 1)]
FROM generate_series(1, 5000000);

VACUUM ANALYZE orders;   -- also builds the visibility map (needed for Index Only Scan)

-- ---------------------------------------------------------------------------
-- 2.2 The query under test — SAME query for BEFORE and AFTER
-- ---------------------------------------------------------------------------
-- SELECT customer_id, order_date, amount
-- FROM   orders
-- WHERE  customer_id BETWEEN 5000 AND 5010
-- ORDER  BY customer_id;

-- ---------------------------------------------------------------------------
-- 2.3 BEFORE — plain index, heap fetch for the returned columns
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_cust ON orders (customer_id);
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, order_date, amount
FROM   orders
WHERE  customer_id BETWEEN 5000 AND 5010
ORDER  BY customer_id;

-- Illustrative output (your numbers vary; gap is far larger with a cold cache):
--   Index Scan using idx_orders_cust on orders
--           (actual time=0.045..6.30 rows=548 loops=1)
--     Index Cond: (customer_id >= 5000 AND customer_id <= 5010)
--     Buffers: shared hit=12 read=520          <-- ~520 heap pages, one random read per row
--   Planning Time: 0.11 ms
--   Execution Time: 6.53 ms
--
-- order_date and amount are NOT in the index, so every one of the 548 matched
-- rows triggers a heap lookup.

-- ---------------------------------------------------------------------------
-- 2.4 AFTER — covering index with INCLUDE
-- ---------------------------------------------------------------------------
DROP INDEX idx_orders_cust;
CREATE INDEX idx_orders_cust_cov
    ON orders (customer_id) INCLUDE (order_date, amount);
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, order_date, amount
FROM   orders
WHERE  customer_id BETWEEN 5000 AND 5010
ORDER  BY customer_id;                     -- SAME query

-- Illustrative output:
--   Index Only Scan using idx_orders_cust_cov on orders
--           (actual time=0.030..0.22 rows=548 loops=1)
--     Index Cond: (customer_id >= 5000 AND customer_id <= 5010)
--     Heap Fetches: 0                          <-- the whole point: zero heap access
--     Buffers: shared hit=8
--   Planning Time: 0.12 ms
--   Execution Time: 0.28 ms
--
-- Node changed to Index Only Scan, Heap Fetches: 0, buffers collapsed from
-- ~532 to ~8.

-- ---------------------------------------------------------------------------
-- 2.5 Result — Case Study 2
-- ---------------------------------------------------------------------------
--   Metric                      | BEFORE plain (customer_id) | AFTER (customer_id) INCLUDE (order_date, amount) | Improvement
--   -----------------------------|------------------------------|-----------------------------------------------------|------------
--   Node type                    | Index Scan + heap            | Index Only Scan                                      | --
--   Heap page reads              | ~520                          | 0                                                     | infinite
--   Buffers touched              | ~532                          | ~8                                                    | ~65x
--   Execution time (warm)        | ~6.5 ms                       | ~0.3 ms                                               | ~20x
--   Execution time (cold cache)  | ~180 ms                       | ~3 ms                                                 | ~60x
--
-- The query text never changed. Adding the two returned columns as INCLUDE
-- payload removed all heap I/O.

-- ---------------------------------------------------------------------------
-- 2.6 Bonus — INCLUDE vs putting the columns in the key
-- ---------------------------------------------------------------------------
-- Both make the query index-only. Prefer INCLUDE when the columns are only returned:
--
-- Option A: key columns          -> bigger internal pages, forces a sort order you don't need
-- CREATE INDEX ... ON orders (customer_id, order_date, amount);
--
-- Option B: INCLUDE payload      -> same index-only benefit, shallower tree, leaf-only storage
-- CREATE INDEX ... ON orders (customer_id) INCLUDE (order_date, amount);

-- INCLUDE also lets you keep a UNIQUE index unique on just the key while carrying payload:
CREATE UNIQUE INDEX uq_orders_id_cov
    ON orders (order_id) INCLUDE (customer_id, amount);   -- still unique on order_id only

-- ---------------------------------------------------------------------------
-- 2.7 Bonus — check the index size you're paying for
-- ---------------------------------------------------------------------------
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan AS times_used
FROM   pg_stat_user_indexes
WHERE  relname = 'orders'
ORDER  BY pg_relation_size(indexrelid) DESC;

-- ---------------------------------------------------------------------------
-- 2.8 Cleanup (optional — skip if you're moving straight to Case Study 3)
-- ---------------------------------------------------------------------------
-- DROP TABLE IF EXISTS orders;      -- drops its indexes too
-- or from a shell:  dropdb idx_lab


-- #############################################################################
-- # CASE STUDY 3 of 4 — FRAGMENTED / BLOATED INDEXES (with INCLUDE columns)
-- # Rule: UPDATE/DELETE churn + page splits leave leaf pages sparse and
-- # out of order. VACUUM does not fix it; only REINDEX rebuilds it dense.
-- # INCLUDE columns bloat FASTER: updating one breaks HOT for every index.
-- # Source: Postgres-Fragmented-Index-Bloat-With-INCLUDE-Simulation.md
-- #############################################################################

-- ---------------------------------------------------------------------------
-- 3.1 Setup + covering index
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    order_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  integer       NOT NULL,
    order_status text          NOT NULL,
    amount       numeric(10,2) NOT NULL
);
INSERT INTO orders (customer_id, order_status, amount)
SELECT (random()*99999+1)::int,
       (ARRAY['NEW','PAID','SHIPPED','DELIVERED','CANCELLED'])[floor(random()*5+1)],
       (random()*500+10)::numeric(10,2)
FROM generate_series(1, 5000000);

CREATE INDEX idx_orders_cov
    ON orders (customer_id) INCLUDE (order_status, amount);
VACUUM ANALYZE orders;

CREATE EXTENSION IF NOT EXISTS pgstattuple;   -- to measure fragmentation

-- ---------------------------------------------------------------------------
-- 3.2 The query under test — SAME query for BEFORE and AFTER
-- ---------------------------------------------------------------------------
-- SELECT customer_id, order_status, amount
-- FROM   orders
-- WHERE  customer_id BETWEEN 5000 AND 5100;

-- ---------------------------------------------------------------------------
-- 3.3 Create churn — updates the INCLUDE column, which bloats the index
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  FOR i IN 1..10 LOOP
    UPDATE orders SET amount = amount + 0.01 WHERE customer_id % 5 = 0;  -- 1M rows/pass
  END LOOP;
END $$;
-- deliberately NOT vacuuming aggressively, to mimic autovacuum falling behind

-- ---------------------------------------------------------------------------
-- 3.4 BEFORE — fragmented index
-- ---------------------------------------------------------------------------
SELECT pg_size_pretty(pg_relation_size('idx_orders_cov'))            AS index_size,
       (pgstatindex('idx_orders_cov')).avg_leaf_density              AS leaf_density_pct,
       (pgstatindex('idx_orders_cov')).leaf_fragmentation            AS leaf_frag_pct;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, order_status, amount
FROM   orders WHERE customer_id BETWEEN 5000 AND 5100;

-- Illustrative output:
--    index_size | leaf_density_pct | leaf_frag_pct
--   ------------+------------------+---------------
--    430 MB     |            44.9  |         34.7        <-- was ~150 MB / ~90% / ~0%
--
--   Index Only Scan using idx_orders_cov on orders
--           (actual time=0.05..4.60 rows=5120 loops=1)
--     Index Cond: (customer_id >= 5000 AND customer_id <= 5100)
--     Heap Fetches: 970                     <-- churned pages not yet all-visible
--     Buffers: shared hit=40 read=182       <-- ~220 pages for 5k rows
--   Execution Time: 4.72 ms

-- ---------------------------------------------------------------------------
-- 3.5 AFTER — rebuild it dense (online, no long lock)
-- ---------------------------------------------------------------------------
REINDEX INDEX CONCURRENTLY idx_orders_cov;   -- needs ~2x index size free disk;
                                              -- cannot run inside a transaction block
VACUUM ANALYZE orders;

SELECT pg_size_pretty(pg_relation_size('idx_orders_cov'))            AS index_size,
       (pgstatindex('idx_orders_cov')).avg_leaf_density              AS leaf_density_pct,
       (pgstatindex('idx_orders_cov')).leaf_fragmentation            AS leaf_frag_pct;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, order_status, amount
FROM   orders WHERE customer_id BETWEEN 5000 AND 5100;   -- SAME query

-- Illustrative output:
--    index_size | leaf_density_pct | leaf_frag_pct
--   ------------+------------------+---------------
--    152 MB     |            90.2  |          0.4
--
--   Index Only Scan using idx_orders_cov on orders
--           (actual time=0.03..0.82 rows=5120 loops=1)
--     Heap Fetches: 0
--     Buffers: shared hit=12
--   Execution Time: 0.90 ms

-- ---------------------------------------------------------------------------
-- 3.6 Result — Case Study 3
-- ---------------------------------------------------------------------------
--   Metric              | BEFORE (fragmented) | AFTER (REINDEX) | Improvement
--   ----------------------|----------------------|-------------------|------------
--   Index size            | ~430 MB               | ~152 MB           | ~2.8x smaller
--   Leaf density           | ~45%                  | ~90%              | 2x
--   Leaf fragmentation     | ~35%                  | ~0%               | --
--   Buffers per scan       | ~220                  | ~12               | ~18x
--   Heap Fetches           | ~970                  | 0                 | infinite
--   Execution time         | ~4.7 ms               | ~0.9 ms           | ~5x

-- ---------------------------------------------------------------------------
-- 3.7 Cleanup (optional — skip if you're moving straight to Case Study 4)
-- ---------------------------------------------------------------------------
-- DROP TABLE IF EXISTS orders;
-- or from a shell:  dropdb idx_lab


-- #############################################################################
-- # CASE STUDY 4 of 4 — PARTIAL INDEXES (with INCLUDE columns)
-- # Rule: CREATE INDEX ... WHERE <predicate> indexes only the rows you
-- # actually query. Stack INCLUDE on top and that tiny index is also covering.
-- # Source: Postgres-Partial-Index-With-INCLUDE-Simulation.md
-- #############################################################################

-- ---------------------------------------------------------------------------
-- 4.1 Setup — table + SKEWED data (run once)
-- ---------------------------------------------------------------------------
-- from a shell:  createdb idx_lab   &&   psql idx_lab
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   integer        NOT NULL,
    order_status  text           NOT NULL,
    order_date    date           NOT NULL,
    amount        numeric(10,2)  NOT NULL,
    ship_country  text           NOT NULL
);

-- status is deliberately skewed:  PENDING ~0.2%, FAILED ~2%, CANCELLED ~1.8%, DONE ~96%
INSERT INTO orders (customer_id, order_status, order_date, amount, ship_country)
SELECT
    (random() * 99999 + 1)::int,
    CASE
        WHEN r < 0.002 THEN 'PENDING'
        WHEN r < 0.022 THEN 'FAILED'
        WHEN r < 0.040 THEN 'CANCELLED'
        ELSE 'DONE'
    END,
    DATE '2023-01-01' + (random() * 730)::int,
    (random() * 500 + 10)::numeric(10,2),
    (ARRAY['US','GB','DE','IN','AU','CA'])[floor(random()*6 + 1)]
FROM (SELECT random() AS r FROM generate_series(1, 5000000)) s;

VACUUM ANALYZE orders;

SELECT order_status, count(*) FROM orders GROUP BY order_status ORDER BY 2 DESC;

-- ---------------------------------------------------------------------------
-- 4.2 The query under test — SAME query for BEFORE and AFTER
-- ---------------------------------------------------------------------------
-- SELECT order_id, customer_id, amount
-- FROM   orders
-- WHERE  order_status = 'PENDING'
-- ORDER  BY order_id;

-- ---------------------------------------------------------------------------
-- 4.3 BEFORE — a naive FULL index on the status column
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_status ON orders (order_status);
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, amount
FROM   orders
WHERE  order_status = 'PENDING'
ORDER  BY order_id;

-- Illustrative output (your numbers vary; the gap is far larger with a cold cache):
--   Sort  (actual time=68.0..69.1 rows=10000 loops=1)
--     Sort Key: order_id
--     Sort Method: quicksort  Memory: ~1400kB
--     ->  Bitmap Heap Scan on orders  (actual time=2.1..63.8 rows=10000 loops=1)
--           Recheck Cond: (order_status = 'PENDING')
--           Heap Blocks: exact=9900
--           Buffers: shared hit=210 read=9900          <-- ~9,900 random heap page reads
--           ->  Bitmap Index Scan on idx_orders_status (actual time=1.0..1.0 rows=10000 loops=1)
--                 Index Cond: (order_status = 'PENDING')
--   Execution Time: 70.3 ms
--
-- The index finds the 10,000 rows fast, but customer_id / amount force a heap
-- fetch per row, and order_id forces a Sort.
-- Index size: SELECT pg_size_pretty(pg_relation_size('idx_orders_status'));
--   -> ~110 MB (it indexes all 5M rows, 99.8% of which are never queried).

-- ---------------------------------------------------------------------------
-- 4.4 AFTER — a PARTIAL + COVERING index
-- ---------------------------------------------------------------------------
DROP INDEX idx_orders_status;

CREATE INDEX idx_orders_pending
    ON orders (order_id) INCLUDE (customer_id, amount)
    WHERE order_status = 'PENDING';                    -- <-- partial predicate

VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, amount
FROM   orders
WHERE  order_status = 'PENDING'
ORDER  BY order_id;                                    -- SAME query

-- Illustrative output:
--   Index Only Scan using idx_orders_pending on orders
--           (actual time=0.020..2.55 rows=10000 loops=1)
--     Heap Fetches: 0                                      <-- no heap access
--     Buffers: shared hit=95
--   Planning Time: 0.14 ms
--   Execution Time: 3.02 ms
--
-- No Recheck, no Bitmap Heap Scan, no Sort (the index is already ordered by
-- order_id), zero heap fetches.
-- Index size: SELECT pg_size_pretty(pg_relation_size('idx_orders_pending'));
--   -> ~0.4 MB

-- ---------------------------------------------------------------------------
-- 4.5 Result — Case Study 4
-- ---------------------------------------------------------------------------
--   Metric                       | BEFORE full (order_status)   | AFTER partial covering WHERE order_status='PENDING' | Improvement
--   -------------------------------|---------------------------------|---------------------------------------------------------|------------
--   Plan                           | Bitmap Heap Scan -> Sort         | Index Only Scan                                          | --
--   Heap page reads                | ~9,900                           | 0                                                         | infinite
--   Extra Sort step                | yes                               | no                                                        | --
--   Buffers touched                | ~10,100                          | ~95                                                       | ~105x
--   Execution time (warm)          | ~70 ms                            | ~3 ms                                                     | ~23x
--   Execution time (cold cache)    | ~400 ms                           | ~5 ms                                                     | ~80x
--   Index size on disk             | ~110 MB                          | ~0.4 MB                                                   | ~275x

-- ---------------------------------------------------------------------------
-- 4.6 Bonus — the write-cost difference
-- ---------------------------------------------------------------------------
-- simulate a day of traffic: 100k new orders, essentially all DONE
INSERT INTO orders (customer_id, order_status, order_date, amount, ship_country)
SELECT (random()*99999+1)::int, 'DONE', CURRENT_DATE, (random()*500+10)::numeric(10,2), 'US'
FROM generate_series(1, 100000);

-- The FULL (order_status) index would gain 100,000 new tuples (+WAL, +bloat).
-- The PARTIAL idx_orders_pending gains 0 — none of the new rows match
-- order_status = 'PENDING'. When a PENDING order is later marked DONE, its
-- entry is automatically removed from the partial index. It stays
-- permanently small and hot — a self-cleaning queue index.

-- ---------------------------------------------------------------------------
-- 4.7 Bonus — compare what you're storing
-- ---------------------------------------------------------------------------
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan AS times_used
FROM   pg_stat_user_indexes
WHERE  relname = 'orders'
ORDER  BY pg_relation_size(indexrelid) DESC;

-- ---------------------------------------------------------------------------
-- 4.8 Cleanup
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS orders;      -- drops its indexes too
-- or from a shell:  dropdb idx_lab


-- #############################################################################
-- # ALL FOUR CASE STUDIES AT A GLANCE
-- #############################################################################
--
--   # | Case study                | BEFORE plan          | AFTER plan            | Headline win
--   --|----------------------------|-----------------------|-------------------------|------------------------
--   1 | Composite column order     | Seq Scan              | Index Scan              | ~4,000x faster
--   2 | Covering index / INCLUDE   | Index Scan + heap     | Index Only Scan         | ~20-60x faster
--   3 | Fragmented / bloated index | Index Only (bloated)  | Index Only (REINDEXed)  | ~5x faster, ~2.8x smaller
--   4 | Partial + covering index   | Bitmap Heap -> Sort   | Index Only Scan         | ~23-80x faster, ~275x smaller
--
-- One thread runs through all four: EVERY improvement came from changing the
-- INDEX DEFINITION, never the query text. Read EXPLAIN (ANALYZE, BUFFERS) —
-- don't guess — and watch for Seq Scan, heap fetches > 0, a surprise Sort, or
-- an index far bigger than the rows you actually query.
-- =============================================================================

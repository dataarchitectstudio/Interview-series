# SQL Database Production Performance Scenarios

## Table of Contents
1. [Scenario 1: Fix Wrong Data Types](#scenario-1-fix-wrong-data-types)
2. [Scenario 2: Rebuild Fragmented Indexes](#scenario-2-rebuild-fragmented-indexes)
3. [Scenario 3: Composite Index for WHERE + JOIN](#scenario-3-composite-index-for-where--join)
4. [Scenario 4: Replace Big IN-List With Join](#scenario-4-replace-big-in-list-with-join)
5. [Scenario 5: Subqueries → CTE + JOIN](#scenario-5-subqueries--cte--join)
6. [Scenario 6: Sorting with Composite/Covering Index](#scenario-6-sorting-with-compositecovering-index)
7. [Scenario 7: Partial Index for Hot Queries](#scenario-7-partial-index-for-hot-queries)
8. [Scenario 8: Temp Tables Vs Deep Subqueries](#scenario-8-temp-tables-vs-deep-subqueries)
9. [Scenario 9: Recursive CTE at Scale](#scenario-9-recursive-cte-at-scale)
10. [Scenario 10: Avoid OR in JOIN Conditions](#scenario-10-avoid-or-in-join-conditions)
12. [Trade-offs & Common Challenges](#trade-offs--common-challenges)
13. [Final Checklist](#final-checklist)

---

## Scenario 1: Fix Wrong Data Types

**Database System**: MySQL 5.7 (On-Premises), Production E-Commerce Platform

**Industry**: E-Commerce / Retail  
**Data Volume**: 100M+ orders, 50M+ log entries  
**Query Frequency**: 50,000+ queries/second during peak hours

### Background
An e-commerce platform was experiencing steady growth, with order volume increasing from 1 million to 10 million daily transactions over two years. During peak shopping hours (Black Friday), database CPU usage spiked to 85%, and simple queries started timing out. The infrastructure team was considering adding more hardware, but a DBA audit discovered the root cause was poor data type choices made during initial development.

**Timeline**:

✅
**Month 0**: Database created with generic INT for status fields (wrong assumption about scalability)

✅
**Month 6**: Order volume: 10M rows, performance still acceptable

✅
**Month 18**: Order volume: 100M rows, system begins showing strain

✅
**Month 24**: Order volume: 100M rows, peak-hour response times degrade to 2-3 seconds

✅
**Peak Crisis**: Black Friday sales event, database unable to handle 50K qps, timeouts begin

### The Problem
**Scenario A: Order Status Field**

The `orders` table used an `INT` data type (4 bytes) to store `order_status` values, even though the application only used values 1-5:
- 1 = PENDING
- 2 = CONFIRMED  
- 3 = SHIPPED
- 4 = DELIVERED
- 5 = CANCELLED

**Metrics Before Optimization**:
| Metric | Value | Impact |
|--------|-------|--------|
| Orders Table Size | 15.2 GB | Storage cost, slower queries |
| order_status Column | INT (4B) × 100M rows = 400 MB | 75% wasted on this column alone |
| Wasted Storage | 300 MB | Could reduce buffer pool usage |
| Query Time: COUNT(*) | 1,800 ms | User-facing slowness |
| Buffer Pool Hit Rate | 78% | Missing 22% of working set |

**Scenario B: Timestamp Precision**

A logging table used `DATETIME(6)` (microsecond precision - 8 bytes) across 50 million rows, but the application logic only required second-level precision (`DATETIME` - 5 bytes).

**Metrics**:
| Metric | Value |
|--------|-------|
| Log Entries | 50M rows |
| log_timestamp Column Size | DATETIME(6) = 8 bytes × 50M = 400 MB |
| Could Save | With DATETIME = 5B → 150 MB savings |
| Row Size Impact | 8 bytes per 50M rows that could fit elsewhere |
| Query Performance | 15% slower due to larger rows in cache |

### Root Cause Analysis
1. **Row Size Bloat**: Each row 4 bytes larger than necessary, repeated across 100M rows
2. **Buffer Pool Waste**: With 16GB buffer pool, fewer rows fit in memory (losing cache advantages)
3. **I/O Amplification**: Must read more disk pages to get same number of logical rows
4. **Memory Bandwidth**: Slower memory access patterns with larger row sizes

**Why It Happened**:
- Junior developers used INT as "default" for all numeric fields
- No code review for data type choices
- Performance testing done with < 1M rows (problem invisible at small scale)
- Assumption: "INT is standard, optimize later if needed" (but never did)

### The Solution

```sql
-- Fix Scenario A: Change order_status to TINYINT
ALTER TABLE orders
MODIFY COLUMN order_status TINYINT;

-- Verify data integrity first
SELECT COUNT(*) FROM orders WHERE order_status > 5;

-- Fix Scenario B: Reduce timestamp precision
ALTER TABLE logs
MODIFY COLUMN log_timestamp DATETIME;

-- Reclaim space (MySQL)
OPTIMIZE TABLE orders;
OPTIMIZE TABLE logs;

-- PostgreSQL equivalent
CLUSTER orders;
```

### Implementation Considerations

```sql
-- Step 1: Back up data
CREATE TABLE orders_backup AS SELECT * FROM orders;

-- Step 2: Test the change on sample data
CREATE TABLE orders_test AS SELECT * FROM orders LIMIT 100000;
ALTER TABLE orders_test MODIFY COLUMN order_status TINYINT;

-- Step 3: Verify no data loss or conversion issues
SELECT COUNT(*) FROM orders_test;
SELECT DISTINCT order_status FROM orders_test;

-- Step 4: Apply to production with downtime window or online schema change
-- MySQL 5.6+ supports online DDL
ALTER TABLE orders
MODIFY COLUMN order_status TINYINT,
ALGORITHM=INPLACE, LOCK=NONE;

-- Step 5: Monitor performance
```

### Performance Impact

**Before Optimization (MySQL Production Metrics)**:

```
┌─────────────────────────────────────────┐
│ Query: SELECT COUNT(*) FROM orders      │
│        WHERE order_status = 3           │
├─────────────────────────────────────────┤
│ Execution Time: 2,500 ms                │
│ Pages Read: 156,250 pages               │
│ Buffer Pool Miss Rate: 15%              │
│ CPU Usage: 45%                          │
│ Concurrent Queries Supported: 20/sec    │
│ Query Cost: 2.45 I/O units              │
└─────────────────────────────────────────┘

Full table size: orders table = 15.2 GB (with INT for status)
Disk I/O bottleneck: ~4.3ms per page read average
Network overhead: 125KB result set transmitted
```

**After Optimization (MySQL Production Metrics)**:

```
┌─────────────────────────────────────────┐
│ Query: SELECT COUNT(*) FROM orders      │
│        WHERE order_status = 3           │
├─────────────────────────────────────────┤
│ Execution Time: 1,750 ms (30% faster)   │
│ Pages Read: 125,000 pages               │
│ Buffer Pool Miss Rate: 8%               │
│ CPU Usage: 18%                          │
│ Concurrent Queries Supported: 75/sec    │
│ Query Cost: 1.02 I/O units              │
└─────────────────────────────────────────┘

Full table size: orders table = 14.9 GB (with TINYINT for status)
Disk I/O reduction: 20% fewer pages needed
Memory efficiency: 3.8x more rows per GB of buffer pool
```

**Business Impact**:
- **Storage Savings**: 300 MB recovered (immediate)
- **Hardware Cost Avoided**: No need for additional storage (saved $15K+ per year)
- **Query Performance**: Consistent improvement across all queries touching these columns
- **Peak Hour Capacity**: Can now handle 75 queries/sec vs 20 (3.75x improvement)
- **User Experience**: No more timeouts during Black Friday sales
- **Operational Cost**: Reduced CPU load from 85% to 28% during peak hours

### Key Lessons

1. **Right-Size Your Data Types**: Use the smallest type that accommodates your actual data range
2. **Understand Hardware Constraints**: Disk I/O and memory bandwidth are expensive
3. **Scale Matters**: Optimization impact increases exponentially with data size
4. **Validate Before & After**: Always verify data integrity post-conversion

### Related Data Types Reference

| Type | Size | Range | Use Case |
|------|------|-------|----------|
| TINYINT | 1B | -128 to 127 | Status, flags (0-5 values) |
| SMALLINT | 2B | -32,768 to 32,767 | Category IDs, small counts |
| INT | 4B | -2B to 2B | Standard IDs, large counts |
| BIGINT | 8B | -9.2E18 to 9.2E18 | Timestamps (ms), large IDs |
| DECIMAL(10,2) | 5B | Exact decimals | Currency, financial data |
| FLOAT | 4B | Approximate decimals | Measurements, coordinates |
| VARCHAR(50) | 1-50B | Variable length | Names, descriptions |
| CHAR(50) | 50B | Fixed length | Codes, fixed-width data |

---

## Scenario 2: Rebuild Fragmented Indexes

**Database System**: SQL Server 2019 (On-Premises), Financial Services  
**Industry**: Banking / Financial Services  
**Data Volume**: 2.1B transactions, 850GB database  
**Query Frequency**: 100,000+ queries/second during trading hours

### Background
A financial services company processes 50 million transactions daily. Their transaction processing system had been running smoothly for 18 months, but recently they noticed a gradual, steady degradation in query performance that correlated with continuous transaction growth. The data volume increased 300%, but system capacity only grew 15%. Performance dropped from 150ms to 8,500ms for standard queries—not acceptable for financial markets where milliseconds matter. The infrastructure team suspected hardware issues, but a deep dive revealed index fragmentation was the culprit.

**Timeline**:

✅
**Month 0**: Fresh database, indexes rebuilt, performance optimal

✅
**Month 3**: 500M transactions, fragmentation < 5%, performance good

✅
**Month 9**: 1.2B transactions, fragmentation rises to 35%, noticing slowdown starts

✅
**Month 18**: 2.1B transactions, fragmentation reaches 85%, crisis point

✅
**Month 19**: Alert: 50 millisecond queries now taking 8.5 seconds, traders complaining

### The Problem

**Scenario: Financial Records Slowdown from Persistent Insert/Delete Patterns**

The primary index on the `transactions` table (`idx_acct_ts` on `account_id, timestamp`) measured at **85% fragmentation**. This happened because:
- 24/7 continuous inserts of new transactions
- Daily cleanup deletes of old transactions (reconciliation process)
- B-tree pages split and leave gaps
- Hundreds of thousands of transactions per minute fragmenting index

**Visual Impact**:
- Index pages were scattered across disk instead of being contiguous
- Database had to perform many more page reads (seeking all over disk)
- Read-ahead optimization wasn't effective (can't prefetch scattered pages)

```
Index Fragmentation Metric: 85%
Optimal Range: < 10% (fully contiguous)
Good Range: 10-30% (acceptable)
Poor Range: 30-60% (significantly degraded)
Critical Range: > 60% (unacceptable)

This index: 85% = CRITICAL
```

**Metrics Before Rebuild**:

| Metric | Value | Impact |
|--------|-------|--------|
| Index Size | 5.2 GB | 850GB database, 0.6% just for this index |
| Fragmentation Level | 85% | Pages randomly scattered |
| Page Count | 670K pages | Highly fragmented across disk |
| Random I/O Seeks | 670K required | One seek per page |
| Physical Disk Seeks | From cylinder 0-2000 (back and forth) | Disk arm thrashing |
| Avg Page Read Time | 4.2ms (vs 0.8ms for contiguous) | 5x slower! |
| Transactions Indexed | 2.1 billion rows | Massive scale |
| Insert Rate | 600 txns/second | Continuous fragmentation |
| Delete Rate | 450 txns/second | Creates gaps in index |

### Root Cause Analysis

**Why Did Fragmentation Occur?**

1. **Continuous Inserts**: 600 transactions/second × 86,400 seconds = 51.8M inserts daily
2. **Daily Deletes**: Reconciliation process deletes old transaction records (gap creation)
3. **B-Tree Splits**: New data comes in faster than it fits on existing pages
4. **Page Split Pattern**: When page fills to 100%, it splits 50-50, creating internal fragmentation
5. **No Maintenance Schedule**: Automatic index maintenance was disabled 12 months ago to "save CPU"

**How Fragmentation Impacts Performance**:  
```
Optimal (< 10% fragmentation):
├─ Index pages: [1][2][3][4][5] → Sequential on disk
├─ Physical location: Contiguous cluster
├─ Read-ahead effectiveness: 95% (prefetches next 8 pages successfully)
├─ I/O Operations Needed: 10-15
└─ Seek Time: 200ms (full index scan)

Fragmented (85% fragmentation):
├─ Index pages: [1][45][2][78][3][90][4] → Random jumps
├─ Physical location: All over the disk
├─ Read-ahead effectiveness: 5% (tries to prefetch but wrong location)
├─ I/O Operations Needed: 120-150 (10x worse)
└─ Seek Time: 8,500ms (10x slower!)
```

### The Solution

```sql
-- Step 1: Analyze fragmentation (SQL Server)
SELECT 
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.avg_fragmentation_in_percent AS FragmentationPercent,
    ips.page_count AS PageCount
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id 
    AND ips.index_id = i.index_id
WHERE ips.avg_fragmentation_in_percent > 10
    AND ips.page_count > 1000
ORDER BY ips.avg_fragmentation_in_percent DESC;

-- Step 2: Check fragmentation (PostgreSQL)
SELECT 
    schemaname,
    tablename,
    indexname
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- Step 3: Rebuild the fragmented index (SQL Server)
-- For fragmentation > 30%, do REBUILD
ALTER INDEX idx_acct_ts ON transactions REBUILD;

-- Step 4: Reorganize for moderate fragmentation (SQL Server)
-- For fragmentation 10-30%, do REORGANIZE
ALTER INDEX idx_acct_ts ON transactions REORGANIZE;

-- PostgreSQL equivalent
REINDEX INDEX idx_acct_ts;

-- MySQL equivalent
OPTIMIZE TABLE transactions;

-- Step 5: Update statistics after rebuild
-- SQL Server
UPDATE STATISTICS transactions WITH FULLSCAN;

-- PostgreSQL
ANALYZE transactions;
```

### Performance Before and After

```
BEFORE REBUILD:
Query: SELECT * FROM transactions 
       WHERE account_id = 12345 
       AND timestamp BETWEEN '2024-01-01' AND '2024-01-31';
Execution Time: 8,500 ms
Index Seek Time: 4,200 ms
Pages Read: 45,000
Statistics: Outdated (3 months old)

AFTER REBUILD:
Query: SELECT * FROM transactions 
       WHERE account_id = 12345 
       AND timestamp BETWEEN '2024-01-01' AND '2024-01-31';
Execution Time: 4,200 ms
Index Seek Time: 850 ms
Pages Read: 4,500
Statistics: Current
Improvement: 50% faster, 90% fewer pages read
```

### Maintenance Plan Implementation

```sql
-- Create scheduled maintenance job (SQL Server Agent)
-- Run weekly during low-traffic hours
DECLARE @TableName NVARCHAR(255) = 'transactions';

SELECT 
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.avg_fragmentation_in_percent
INTO #FragmentedIndexes
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id 
    AND ips.index_id = i.index_id
WHERE OBJECT_NAME(ips.object_id) = @TableName
    AND ips.avg_fragmentation_in_percent > 10
    AND ips.page_count > 1000;

-- Execute appropriate action
DECLARE @IndexName NVARCHAR(255);
DECLARE @Fragmentation FLOAT;
DECLARE cur CURSOR FOR SELECT IndexName, avg_fragmentation_in_percent 
    FROM #FragmentedIndexes;

OPEN cur;
FETCH NEXT FROM cur INTO @IndexName, @Fragmentation;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @Fragmentation > 30
        EXEC('ALTER INDEX ' + @IndexName + ' ON ' + @TableName + ' REBUILD');
    ELSE
        EXEC('ALTER INDEX ' + @IndexName + ' ON ' + @TableName + ' REORGANIZE');
    
    FETCH NEXT FROM cur INTO @IndexName, @Fragmentation;
END;

CLOSE cur;
DEALLOCATE cur;
```

### Key Lessons

1. **Monitor Index Health**: Check fragmentation monthly on heavily-used tables
2. **Maintenance Schedule**: Run REBUILD during maintenance windows (30+ fragmentation)
3. **REORGANIZE for Moderate Issues**: Use REORGANIZE for 10-30% fragmentation (faster, online)
4. **Update Statistics**: Always update stats after index maintenance
5. **Prioritize Hot Tables**: Focus on high-volume tables first

---

## Scenario 3: Composite Index for WHERE + JOIN

### Background
An online retail platform's "active orders" dashboard was experiencing severe slowdowns during peak shopping hours (Black Friday). The dashboard needed to show all active orders for each customer, with customer details. Traffic volume was 50,000 concurrent users, each viewing the dashboard every 10-30 seconds.

### The Problem

**Scenario: Active Orders Dashboard**

The query was written to join `orders` and `customers` tables filtering for active orders:

```sql
-- Original Query
SELECT 
    c.customer_id,
    c.customer_name,
    o.order_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.status = 'ACTIVE'
ORDER BY o.order_date DESC;
```

**Performance Issues:**

| Metric | Value | Impact |
|--------|-------|--------|
| Execution Time | 11 seconds | Users experience 11-second delay |
| Rows Examined | 50 million | Full scan of entire orders table |
| Rows Returned | 250,000 | Only 0.5% of rows actually needed |
| CPU Usage | 85% | Server struggles during peak hours |

**Execution Plan Analysis:**

```
1. Full Table Scan on orders (50M rows)
   ↓
2. For each row, evaluate WHERE clause (status = 'ACTIVE')
   ↓
3. Nested Loop Join with customers
   ↓
4. Apply Sort
   ↓
5. Return 250K rows to client
```

### Root Cause Analysis

The problem stemmed from a fundamental database design issue:

1. **No Index on Status Column**: Database must scan all 50 million rows to find active orders
2. **Poor Join Strategy**: After finding active orders, database performs 250K lookups on customers table
3. **Missing Sort Index**: Sorting 250K results in memory uses CPU and I/O

### The Solution: Composite Index

A **composite index** (also called concatenated or multicolumn index) includes multiple columns and can be highly effective when:
- Filtering on specific columns (WHERE clause)
- Joining on columns that are filtered
- Sorting results

```sql
-- Create composite index with optimal column order
-- Rule: Filter columns first, then JOIN columns, then SORT columns
CREATE INDEX idx_orders_status_custid
ON orders(status, customer_id, order_date DESC)
INCLUDE (order_id, total_amount);
```

**Index Structure Explained:**

```
Index: idx_orders_status_custid
┌─────────────────────────────────────────────────┐
│ Level 1 (Root)                                  │
│ status=ACTIVE, status=CANCELLED, etc.           │
├─────────────────────────────────────────────────┤
│ Level 2 (Branch - filtered for ACTIVE)          │
│ cust_id=100, cust_id=200, etc.                  │
├─────────────────────────────────────────────────┤
│ Level 3 (Leaf - sorted by order_date DESC)      │
│ order_id, total_amount (included data)          │
└─────────────────────────────────────────────────┘
```

### Complete Implementation

```sql
-- Step 1: Analyze current query performance (BEFORE)
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT 
    c.customer_id,
    c.customer_name,
    o.order_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.status = 'ACTIVE'
ORDER BY o.order_date DESC;

-- Results: CPU time: 11,234 ms, Reads: 89,456 logical reads

-- Step 2: Create composite index
-- Composite index order matters:
-- 1st: Equality predicates (status = 'ACTIVE')
-- 2nd: Inequality predicates and JOINs (customer_id)
-- 3rd: ORDER BY columns (order_date DESC)
-- INCLUDE: SELECT list columns not in index key

CREATE INDEX idx_orders_status_custid
ON orders(status, customer_id, order_date DESC)
INCLUDE (order_id, total_amount);

-- Step 3: Update statistics
UPDATE STATISTICS orders WITH FULLSCAN;

-- Step 4: Verify index is used (check execution plan)
SELECT 
    c.customer_id,
    c.customer_name,
    o.order_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.status = 'ACTIVE'
ORDER BY o.order_date DESC;

-- Results: CPU time: 234 ms, Reads: 1,234 logical reads
-- Improvement: 48x faster, 98% fewer reads!

-- Step 5: Monitor index usage
SELECT 
    OBJECT_NAME(s.object_id) AS TableName,
    i.name AS IndexName,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates
FROM sys.dm_db_index_usage_stats s
INNER JOIN sys.indexes i ON s.object_id = i.object_id 
    AND s.index_id = i.index_id
WHERE OBJECT_NAME(s.object_id) = 'orders'
ORDER BY s.user_seeks + s.user_scans + s.user_lookups DESC;
```

### Performance Comparison

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Execution Time | 11,000 ms | 250 ms | **44x faster** |
| Logical Reads | 89,456 | 1,234 | **98% fewer** |
| CPU Time | 11,234 ms | 234 ms | **48x faster** |
| Rows Examined | 50,000,000 | 250,000 | **99.5% reduction** |
| Concurrent Users Supported | 50 | 2,400+ | **48x increase** |

### Advanced: Covering Indexes

```sql
-- Covering index includes ALL columns needed (index-only scan)
-- No need to access main table at all
CREATE INDEX idx_orders_complete
ON orders(status, customer_id)
INCLUDE (order_id, order_date, total_amount);

-- Check for index-only scans
SELECT 
    s.object_id,
    i.name as IndexName,
    s.user_seeks,
    s.user_scans
FROM sys.dm_db_index_usage_stats s
INNER JOIN sys.indexes i ON s.object_id = i.object_id;
```

### Key Lessons

1. **Column Order Matters**: Equality → Inequality/JOIN → ORDER BY
2. **Use INCLUDE Clause**: Add SELECT columns to enable index-only scans
3. **Test Before Deploying**: Verify with realistic data volumes
4. **Monitor Index Usage**: Remove unused indexes (overhead on writes)
5. **Balance Trade-offs**: More indexes = faster reads but slower writes

---

## Scenario 4: Replace Big IN-List With Join

### Background
A data warehouse team was running nightly reports to analyze user behavior across 12 geographic regions. Their reporting system downloaded a list of 50,000 active user IDs and needed to fetch corresponding order details. The process started at 2 AM and needed to complete by 5 AM for the morning meeting.

### The Problem

**Scenario: High-Volume Filtering with IN Lists**

```sql
-- Original approach: Large IN list
SELECT 
    o.order_id,
    o.customer_id,
    o.order_date,
    o.total_amount
FROM orders o
WHERE o.customer_id IN (
    100001, 100002, 100003, ..., 150000  -- 50,000 IDs
)
ORDER BY o.order_date DESC;
```

**Performance Issues:**

```
Execution Time: 12,000 ms
Table Scans: Full table scan (100M rows examined)
Filter Selectivity: 0.05% (50K out of 100M)
Memory Usage: IN list stored entirely in query plan
Optimization: Query optimizer gives up, uses full scan
```

### How IN Lists Cause Problems

1. **Non-SARGable Predicate**: Query optimizer can't efficiently use indexes with large IN lists
2. **Memory Overhead**: Entire IN list stored in query execution plan
3. **Optimization Limitations**: Plan complexity limits optimization strategies
4. **Filter Late in Plan**: Table scanned fully, then filtered (wrong order)

### The Solution: Join with Temporary Table

```sql
-- Step 1: Create temp table with customer IDs
CREATE TEMP TABLE temp_target_customers (
    customer_id INT PRIMARY KEY
);

-- Step 2: Populate with IDs (from application or import)
INSERT INTO temp_target_customers (customer_id)
VALUES (100001), (100002), (100003), ... (150000);

-- Create index for faster join
CREATE INDEX idx_temp_cust_id 
ON temp_target_customers(customer_id);

-- Step 3: Use JOIN instead of IN
SELECT 
    o.order_id,
    o.customer_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN temp_target_customers t ON o.customer_id = t.customer_id
ORDER BY o.order_date DESC;

-- Step 4: Clean up
DROP TABLE temp_target_customers;
```

### Alternative: Table Variable (SQL Server)

```sql
-- Process using table variable for smaller result sets
DECLARE @TargetCustomers TABLE (
    customer_id INT PRIMARY KEY
);

INSERT INTO @TargetCustomers (customer_id)
SELECT customer_id FROM external_system_export;

SELECT 
    o.order_id,
    o.customer_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN @TargetCustomers t ON o.customer_id = t.customer_id
WHERE o.status = 'COMPLETED'
ORDER BY o.order_date DESC;
```

### Performance Comparison

```
BEFORE (IN list with 50,000 IDs):
├─ Execution Time: 12,000 ms
├─ Table Scans: 1 full scan (100M rows)
├─ CPU: 87%
├─ Disk I/O: 234,567 reads
└─ Result: Process takes 2 hours+ (misses deadline)

AFTER (JOIN with temp table):
├─ Execution Time: 2,000 ms
├─ Table Scans: 1 index scan (50K matched rows)
├─ CPU: 12%
├─ Disk I/O: 8,900 reads
└─ Result: Process takes 20 minutes (meets deadline)

IMPROVEMENT: 6x faster, 97% fewer I/O operations
```

### Advanced: Bulk Load Optimization

```sql
-- For very large datasets, use BULK INSERT for speed
CREATE TABLE staging_customer_ids (
    customer_id INT PRIMARY KEY
);

-- Bulk load from file (fastest method)
BULK INSERT staging_customer_ids
FROM 'C:\data\customer_ids.txt'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n'
);

-- Query with join
SELECT 
    o.order_id,
    o.customer_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN staging_customer_ids s ON o.customer_id = s.customer_id;

-- Clean up
DROP TABLE staging_customer_ids;
```

### PostgreSQL Equivalent with COPY

```sql
-- Create staging table
CREATE TEMP TABLE staging_customers (
    customer_id INT
);

-- Copy data efficiently
COPY staging_customers(customer_id) 
FROM STDIN;
-- Provide data via stdin, press Ctrl+D when done

-- Create index
CREATE INDEX idx_staging_cust ON staging_customers(customer_id);

-- Query
SELECT 
    o.order_id,
    o.customer_id,
    o.order_date,
    o.total_amount
FROM orders o
INNER JOIN staging_customers s ON o.customer_id = s.customer_id
ORDER BY o.order_date DESC;
```

### Key Lessons

1. **Avoid Large IN Lists**: Split into JOINs with temp tables
2. **Index Temp Table**: Create index on join column in temp table
3. **Bulk Load When Possible**: BULK INSERT is much faster than individual INSERTs
4. **Clean Up Properly**: Drop temp tables to avoid blocking issues
5. **Consider Persistence**: For repeated reports, use permanent tables with snapshots

---

## Scenario 5: Subqueries → CTE + JOIN

### Background
A B2B SaaS platform needed to enhance their customer dashboard with order analytics. The dashboard showed each customer's last order date, total orders, and average order value. The initial implementation used correlated subqueries but performance degraded significantly after user base grew from 10,000 to 100,000 customers.

### The Problem

**Scenario: Windowed Aggregates with Correlated Subqueries**

```sql
-- Original approach: Correlated subqueries
-- This subquery executes ONCE PER ROW in outer query
SELECT 
    u.customer_id,
    u.customer_name,
    u.email,
    (SELECT MAX(order_date) 
     FROM orders 
     WHERE customer_id = u.customer_id) AS last_order_date,
    (SELECT COUNT(*) 
     FROM orders 
     WHERE customer_id = u.customer_id) AS total_orders,
    (SELECT AVG(total_amount) 
     FROM orders 
     WHERE customer_id = u.customer_id) AS avg_order_value
FROM users u
WHERE u.status = 'ACTIVE';
```

**Performance Analysis: The N+1 Query Problem**

```
Execution Process:
1. Scan 100,000 active customers ✓
2. For EACH customer (100,000 times):
   - Execute MAX(order_date) subquery
   - Execute COUNT(*) subquery
   - Execute AVG(total_amount) subquery
   - Total: 3 subqueries × 100,000 = 300,000 subqueries!

Result:
├─ Main Query Time: 50 ms
├─ Subquery 1 (MAX) Total: 8,500 ms
├─ Subquery 2 (COUNT) Total: 8,200 ms
├─ Subquery 3 (AVG) Total: 7,800 ms
└─ Total: 24,550 ms (over 24 seconds!)
```

### Root Cause Analysis

1. **Repeated Calculation**: Same aggregation computed multiple times (redundant work)
2. **No Query Optimization**: Subquery executed independently for each row
3. **Index Misuse**: Indexes on orders table not fully leveraged
4. **CPU Bound**: All calculations happening in query engine

| Query Type | Execution | Issue |
|-----------|-----------|-------|
| Correlated Subquery | Row-by-row | 1 outer × N inner = N executions |
| Scalar Subquery | Once | Better but still evaluated per row |
| JOIN | Set-based | Optimized, both sides scanned once |
| CTE + JOIN | Set-based | Can be optimized, aggregates computed once |

### The Solution: CTE with JOIN

```sql
-- Step 1: Use CTE to compute aggregates ONCE
WITH last_orders AS (
    SELECT 
        customer_id,
        MAX(order_date) AS last_order_date,
        COUNT(*) AS total_orders,
        AVG(total_amount) AS avg_order_value
    FROM orders
    GROUP BY customer_id
)
-- Step 2: Join once to get results
SELECT 
    u.customer_id,
    u.customer_name,
    u.email,
    lo.last_order_date,
    lo.total_orders,
    lo.avg_order_value
FROM users u
LEFT JOIN last_orders lo ON u.customer_id = lo.customer_id
WHERE u.status = 'ACTIVE'
ORDER BY lo.last_order_date DESC NULLS LAST;
```

**Why This Works Better:**

```
Optimized Execution:
1. Aggregate orders - GROUP BY customer_id (compute once)
   ├─ Scan all orders (efficient with B-tree index on customer_id)
   ├─ Group: 100,000 groups
   ├─ Calculate: MAX, COUNT, AVG per group
   └─ Result: 100,000 rows
2. Join users to aggregates
   ├─ 100,000 user rows
   ├─ LEFT JOIN 100,000 aggregate rows
   └─ Result: 100,000 final rows
3. Filter and sort
   └─ Applied to final 100,000 rows

Total Cost: 2 table scans + 1 join + 1 sort (far better than 300,000!)
```

### Complete Implementation with Variations

```sql
-- Variation 1: Multiple aggregates in single CTE
WITH order_stats AS (
    SELECT 
        customer_id,
        COUNT(*) AS total_orders,
        SUM(total_amount) AS lifetime_value,
        AVG(total_amount) AS avg_order_value,
        MIN(order_date) AS first_order_date,
        MAX(order_date) AS last_order_date,
        COUNT(CASE WHEN status = 'RETURNED' THEN 1 END) AS returned_orders
    FROM orders
    WHERE order_date >= DATEADD(YEAR, -2, GETDATE())  -- Last 2 years
    GROUP BY customer_id
)
SELECT 
    u.customer_id,
    u.customer_name,
    os.total_orders,
    os.lifetime_value,
    os.avg_order_value,
    os.first_order_date,
    os.last_order_date,
    CASE 
        WHEN os.returned_orders > 5 THEN 'HIGH_RISK'
        WHEN os.returned_orders > 2 THEN 'MEDIUM_RISK'
        ELSE 'LOW_RISK'
    END AS risk_level
FROM users u
LEFT JOIN order_stats os ON u.customer_id = os.customer_id
WHERE u.status = 'ACTIVE'
ORDER BY os.lifetime_value DESC;

-- Variation 2: Nested CTEs for complex logic
WITH recent_orders AS (
    SELECT 
        customer_id,
        order_id,
        order_date,
        total_amount,
        ROW_NUMBER() OVER (PARTITION BY customer_id 
                         ORDER BY order_date DESC) AS order_rank
    FROM orders
    WHERE order_date >= DATEADD(MONTH, -6, GETDATE())
),
customer_recent_stats AS (
    SELECT 
        customer_id,
        COUNT(*) AS recent_orders,
        AVG(total_amount) AS recent_avg_value,
        MAX(total_amount) AS recent_max_value
    FROM recent_orders
    GROUP BY customer_id
)
SELECT 
    u.customer_id,
    u.customer_name,
    crs.recent_orders,
    crs.recent_avg_value,
    crs.recent_max_value
FROM users u
LEFT JOIN customer_recent_stats crs 
    ON u.customer_id = crs.customer_id;

-- Variation 3: Using Window Functions in CTE
WITH customer_order_rank AS (
    SELECT 
        customer_id,
        order_id,
        order_date,
        total_amount,
        ROW_NUMBER() OVER (PARTITION BY customer_id 
                         ORDER BY order_date DESC) AS order_rank,
        RANK() OVER (PARTITION BY customer_id 
                    ORDER BY total_amount DESC) AS amount_rank
    FROM orders
)
SELECT 
    customer_id,
    order_id,
    order_date,
    total_amount
FROM customer_order_rank
WHERE order_rank = 1  -- Most recent order per customer
  AND amount_rank <= 3;  -- Top 3 by amount
```

### Performance Comparison

```
BEFORE (Correlated Subqueries):
├─ Execution Time: 24,550 ms
├─ CPU Time: 23,400 ms
├─ Reads: 450,000 logical reads
├─ Subquery Executions: 300,000
└─ Performance: POOR

AFTER (CTE with JOIN):
├─ Execution Time: 850 ms
├─ CPU Time: 180 ms
├─ Reads: 12,500 logical reads
├─ Subquery Executions: 1
└─ Performance: EXCELLENT

IMPROVEMENT: 29x faster, 96% fewer reads
```

### Key Lessons

1. **Avoid Correlated Subqueries**: They execute per row (N+1 problem)
2. **Use CTEs for Complex Aggregates**: Computed once, joined once
3. **CTEs are Readable**: Self-documenting code, easier to maintain
4. **Window Functions in CTEs**: Powerful for ranking and analytics
5. **Verify Execution Plan**: Check that CTE is computed once, not repeated

---

## Scenario 6: Sorting with Composite/Covering Index

### Background
A content management system (CMS) was experiencing performance issues with their article search and browsing feature. Users could filter by category and see articles sorted by creation date. The feature served 10,000 daily active users, each making 15-20 requests per day. Response times started at 200ms but gradually increased to 5-10 seconds as the article database grew to 50 million pages.

### The Problem

**Scenario: High-Traffic Pagination Without Proper Index**

```sql
-- Original query: Display articles by category, newest first
SELECT 
    page_id,
    page_title,
    page_content,
    category_id,
    created_at,
    author_id
FROM pages
WHERE category_id = 42  -- Technology category
ORDER BY created_at DESC
LIMIT 20 OFFSET 0;
```

**Performance Issue:**

```
Execution Plan:
1. Full Table Scan (50M rows)
   └─ Examine ALL 50 million pages
2. Filter WHERE category_id = 42
   └─ Found 500K pages (1% of total)
3. Sort by created_at DESC
   └─ Sort 500K rows in memory/disk
4. Apply LIMIT/OFFSET
   └─ Return 20 rows
Total Wasted Work: 50M - 20 = 49,999,980 rows examined but not used

Execution Time: 170 seconds (!)
```

**Why This Is Slow:**

| Operation | Pages Involved | Time Taken |
|-----------|----------------|-----------|
| Scan table | 50M pages | 120s |
| Filter rows | 500K pages | 30s |
| Sort rows | 500K rows | 15s |
| Return results | 20 rows | 5ms |
| **Total** | - | **~170s** |

### Solution: Composite (Multi-Column) Index

```sql
-- Create composite index with optimal column order
-- Order: Filter columns first, then SORT columns
CREATE INDEX idx_pages_category_date
ON pages(category_id, created_at DESC);

-- Optional: Include columns to create "covering index"
-- Covering index means index contains all columns needed
CREATE INDEX idx_pages_covering
ON pages(category_id, created_at DESC)
INCLUDE (page_id, page_title, page_content, author_id);
```

**How This Index Works:**

```
Index Structure (Sorted B-Tree):
Level 1 (Root):
├─ category_id ≤ 10
├─ category_id ≤ 50
└─ category_id > 50

Level 2 (Branches - Filter by category):
├─ [50-60] created_at DESC
│  ├─ 2024-12-15 → page_id=1
│  ├─ 2024-12-14 → page_id=3
│  ├─ 2024-12-13 → page_id=5
│  └─ ...
├─ [42 range] created_at DESC
│  ├─ 2024-12-20 → page_id=42
│  ├─ 2024-12-19 → page_id=51
│  ├─ 2024-12-18 → page_id=61
│  ├─ 2024-12-17 → page_id=72
│  └─ ...
└─ [20-40] created_at DESC

Query Execution with Index:
1. Seek to category_id = 42
   └─ Find exact position in index (microseconds)
2. Scan forward (or backward for DESC)
   └─ Already sorted by created_at DESC
   └─ Stop after 20 rows
3. Retrieve data (from INCLUDE columns)
   └─ No need to access main table
Total: Scan only 20 index rows!
```

### Complete Implementation

```sql
-- Step 1: Check current index situation
-- SQL Server
SELECT 
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    c.name AS ColumnName,
    ic.key_ordinal AS ColumnOrder
FROM sys.indexes i
INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id 
    AND i.index_id = ic.index_id
INNER JOIN sys.columns c ON ic.object_id = c.object_id 
    AND ic.column_id = c.column_id
WHERE OBJECT_NAME(i.object_id) = 'pages'
ORDER BY i.name, ic.key_ordinal;

-- Step 2: Analyze query performance BEFORE
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT 
    page_id,
    page_title,
    page_content,
    category_id,
    created_at,
    author_id
FROM pages
WHERE category_id = 42
ORDER BY created_at DESC
LIMIT 20;

-- Statistical Results BEFORE:
-- SQL Server parse and compile time: 10 ms
-- SQL Server CPU time: 15,234 ms
-- SQL Server elapsed time: 170,456 ms
-- Logical reads: 312,455

-- Step 3: Create composite index with covering columns
-- Key columns: Filter then Sort
-- Included columns: SELECT list data
CREATE INDEX idx_pages_cat_date_cover
ON pages(category_id, created_at DESC)
INCLUDE (page_id, page_title, page_content, author_id);

-- Step 4: Update statistics
UPDATE STATISTICS pages WITH FULLSCAN;

-- Step 5: Verify performance improvement
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT 
    page_id,
    page_title,
    page_content,
    category_id,
    created_at,
    author_id
FROM pages
WHERE category_id = 42
ORDER BY created_at DESC
LIMIT 20;

-- Statistical Results AFTER:
-- SQL Server parse and compile time: 8 ms
-- SQL Server CPU time: 12 ms
-- SQL Server elapsed time: 14 ms
-- Logical reads: 25

-- Improvement: 12,000x faster, 12,500x fewer reads!

-- Step 6: Verify index usage statistics
SELECT 
    i.name AS IndexName,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    s.last_user_seek
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s 
    ON i.object_id = s.object_id 
    AND i.index_id = s.index_id
WHERE OBJECT_NAME(i.object_id) = 'pages'
ORDER BY s.user_seeks DESC;
```

### Advanced: Covering Index Strategy

```sql
-- Covering Index: ALL Needed Data in Index (No Table Access)
-- Benefit: Index-only scan (fastest possible)
-- Trade-off: Larger index, more memory needed

-- Identify columns needed in query
SELECT
    -- Key columns (in WHERE/ORDER BY)
    category_id,
    created_at,
    -- INCLUDE columns (in SELECT but not in WHERE/ORDER BY)
    page_id,
    page_title,
    page_content,
    author_id,
    -- Optional: Rarely used but sometimes selected
    updated_at,
    view_count
FROM pages;

-- Create covering index
CREATE INDEX idx_pages_covering_full
ON pages(category_id, created_at DESC)
INCLUDE (page_id, page_title, page_content, author_id, updated_at, view_count);

-- Verify index-only scan
SELECT 
    page_id,
    page_title,
    page_content,
    category_id,
    created_at,
    author_id
FROM pages
WHERE category_id = 42
ORDER BY created_at DESC;

-- Look for "Scan" not "Seek" in execution plan
-- And verify it's an Index Scan, not Table Scan
-- Look for "Index Scan (Covering), [idx_pages_covering_full]"
```

### Performance Comparison

```
BEFORE (No suitable index):
├─ Full table scan: 50M pages
├─ Execution time: 170,000 ms
├─ Logical reads: 312,455
├─ Response time to user: ~2.8 seconds
└─ Users per second supported: ~3

AFTER (Composite covering index):
├─ Index seek: 20 rows
├─ Execution time: 14 ms
├─ Logical reads: 25
├─ Response time to user: ~50 ms
└─ Users per second supported: ~200

IMPROVEMENT:
├─ 12,000x faster
├─ 12,500x fewer disk reads
├─ 67x more concurrent users
└─ Transform slow → blazing fast
```

### PostgreSQL Equivalent

```sql
-- PostgreSQL: Create composite covering index
-- INCLUDE clause may not be available in older versions
-- Alternative: Add columns to key (bloats index but covers queries)
CREATE INDEX idx_pages_cat_date_cover
ON pages(category_id, created_at DESC)
INCLUDE (page_id, page_title, page_content, author_id);

-- For older PostgreSQL, add all columns to key:
CREATE INDEX idx_pages_cat_date_full
ON pages(category_id, created_at DESC, page_id, page_title, 
         page_content, author_id);

-- PostgreSQL-specific: Use DESC properly
CREATE INDEX idx_pages_cat_date_v2
ON pages(category_id ASC, created_at DESC)
WHERE is_published = true;  -- Partial index

-- Verify index usage
EXPLAIN ANALYZE
SELECT 
    page_id,
    page_title,
    created_at
FROM pages
WHERE category_id = 42
ORDER BY created_at DESC
LIMIT 20;
```

### Key Lessons

1. **Column Order Matters**: Filter columns first, then sort columns
2. **Use INCLUDE/COVERING**: Add SELECT columns to prevent table access
3. **DESC Order in Index**: Index in same order as query (DESC in index for DESC queries)
4. **Partial Indexes**: Add WHERE to filter unused rows (e.g., unpublished articles)
5. **Test Real Queries**: Index performance varies with data distribution

---

## Scenario 7: Partial Index for Hot Queries

### Background
A mobile notification system was experiencing database bottleneck issues during peak hours. The system had to handle hundreds of thousands of push notifications, many of which had already been read. The system needed rapid queries for "unread notifications" to display real-time notification badges on users' screens.

### The Problem

**Scenario: Read-Only Alerts System**

```sql
-- Most common query: Find unread alerts for a user
SELECT 
    alert_id,
    message,
    alert_type,
    created_at
FROM alerts
WHERE user_id = 12345
  AND is_read = FALSE
ORDER BY created_at DESC
LIMIT 50;
```

**The Challenge:**

- The `alerts` table contains **500 million rows**
- Only **5% are unread** (25 million rows)
- Application queries for unread alerts thousands of times per second
- Table is growing rapidly

**Why Standard Index Isn't Ideal:**

```sql
-- Standard index on all rows
CREATE INDEX idx_alerts_user_read
ON alerts(user_id, is_read);

Problems:
├─ Index contains 500M rows
├─ Index is large (uses more RAM, more disk)
├─ Most index entries are is_read=TRUE (not needed)
├─ Buffer pool wastes space on unused (TRUE) entries
└─ Result: Slower than necessary
```

### Root Cause Analysis

1. **Index Bloat**: Standard index includes 95% unused rows (where is_read = TRUE)
2. **Memory Inefficiency**: Buffer pool holds index entries for read=TRUE alerts
3. **Wasted Disk I/O**: Must read through entries that won't match filter
4. **Scalability**: As read alerts accumulate, index grows forever

### The Solution: Partial Index

A **partial index** only includes rows matching a WHERE clause, dramatically reducing index size.

```sql
-- Create partial index: Only unread alerts
CREATE INDEX idx_alerts_unread
ON alerts(user_id)
WHERE is_read = FALSE;
```

**How Partial Index Works:**

```
Standard Index (ALL rows):
┌─────────────────────────────┐
│ user_id | is_read | pointer │
├─────────────────────────────┤
│ 100     | FALSE   | →row1   │ ← Include
│ 100     | TRUE    | →row2   │ ← Wasted
│ 101     | FALSE   | →row3   │ ← Include
│ 101     | TRUE    | →row4   │ ← Wasted
│ ...     | ...     | ...     │
│ 50000   | TRUE    | →row5M  │ ← Wasted
└─────────────────────────────┘
500M entries total, 25M useful

Partial Index (Filtered rows):
┌──────────────────────────────┐
│ user_id | is_read | pointer  │
├──────────────────────────────┤
│ 100     | FALSE   | →row1    │ ← Include
│ 101     | FALSE   | →row3    │ ← Include
│ 102     | FALSE   | →row8    │ ← Include
│ ...     | ...     | ...      │
│ 45678   | FALSE   | →row2.5M │ ← Include
└──────────────────────────────┘
25M entries total, 25M useful (100% efficiency!)
```

### Complete Implementation

```sql
-- Step 1: Test query performance BEFORE
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT 
    alert_id,
    message,
    alert_type,
    created_at
FROM alerts
WHERE user_id = 12345
  AND is_read = FALSE
ORDER BY created_at DESC
LIMIT 50;

-- Statistics BEFORE:
-- Reads: 89,234
-- CPU Time: 5,230 ms
-- Elapsed: 14,230 ms

-- Step 2: Check existing indexes
-- Find which index is being used
SELECT 
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    s.user_seeks,
    s.user_scans
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s 
    ON i.object_id = s.object_id 
    AND i.index_id = s.index_id
WHERE OBJECT_NAME(i.object_id) = 'alerts'
ORDER BY s.user_seeks + s.user_scans DESC;

-- Step 3: Create partial index
-- Include only unread alerts where is_read = FALSE
CREATE INDEX idx_alerts_unread_hot
ON alerts(user_id, created_at DESC)
WHERE is_read = FALSE;

-- Optional: Include other needed columns
CREATE INDEX idx_alerts_unread_cover
ON alerts(user_id, created_at DESC)
WHERE is_read = FALSE
INCLUDE (alert_id, message, alert_type);

-- Step 4: Test performance AFTER
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT 
    alert_id,
    message,
    alert_type,
    created_at
FROM alerts
WHERE user_id = 12345
  AND is_read = FALSE
ORDER BY created_at DESC
LIMIT 50;

-- Statistics AFTER:
-- Reads: 120 (dramatic reduction!)
-- CPU Time: 8 ms
-- Elapsed: 12 ms

-- Step 5: Monitor index effectiveness
SELECT 
    i.name AS IndexName,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    DATEDIFF(HOUR, s.last_user_seek, GETDATE()) AS hours_since_last_use
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s 
    ON i.object_id = s.object_id 
    AND i.index_id = s.index_id
WHERE OBJECT_NAME(i.object_id) = 'alerts'
  AND i.name LIKE '%unread%'
ORDER BY s.user_seeks DESC;
```

### Advanced Partial Index Scenarios

```sql
-- Scenario 1: Multiple partial indexes for different hot queries
-- Unread notifications
CREATE INDEX idx_alerts_unread
ON alerts(user_id)
WHERE is_read = FALSE;

-- High priority alerts
CREATE INDEX idx_alerts_urgent
ON alerts(user_id, created_at DESC)
WHERE priority = 'CRITICAL'
  AND is_read = FALSE;

-- Scenario 2: Partial index for data lifecycle
-- Only active orders (not completed/cancelled)
CREATE INDEX idx_orders_active
ON orders(customer_id)
WHERE order_status NOT IN ('COMPLETED', 'CANCELLED', 'RETURNED');

-- Scenario 3: Partial index for time-series (recent data)
-- Only recent events (last 30 days)
CREATE INDEX idx_events_recent
ON events(user_id, event_date DESC)
WHERE event_date >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE));

-- Scenario 4: Partial index filtering multiple conditions
-- Unread emails, not spam, from important senders
CREATE INDEX idx_emails_important_unread
ON emails(user_id, received_date DESC)
WHERE is_read = FALSE
  AND is_spam = FALSE
  AND sender_id IN (SELECT important_sender_id 
                    FROM important_senders 
                    WHERE user_id = emails.user_id);
```

### Performance Comparison

```
BEFORE (Standard index on all rows):
├─ Index size: 15 GB
├─ Logical reads: 89,234
├─ Query time: 14,230 ms
├─ Memory used: 2.3 GB
└─ Users supported: 100/sec

AFTER (Partial index, unread only):
├─ Index size: 750 MB (95% smaller!)
├─ Logical reads: 120
├─ Query time: 12 ms
├─ Memory used: 120 MB
└─ Users supported: 8,000/sec (80x more!)

IMPROVEMENT:
├─ 20x smaller index
├─ 1,200x faster queries
├─ 19x less memory
└─ 80x more concurrent users
```

### PostgreSQL Partial Index

```sql
-- PostgreSQL syntax for partial index (similar to SQL Server)
CREATE INDEX idx_alerts_unread_pg
ON alerts(user_id)
WHERE is_read = false;

-- With sort order for pagination
CREATE INDEX idx_alerts_unread_sorted
ON alerts(user_id, created_at DESC)
WHERE is_read = false;

-- Verify index usage
EXPLAIN ANALYZE
SELECT 
    alert_id,
    message,
    alert_type,
    created_at
FROM alerts
WHERE user_id = 12345
  AND is_read = false
ORDER BY created_at DESC
LIMIT 50;

-- Check index effectiveness
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE tablename = 'alerts'
ORDER BY idx_scan DESC;
```

### Key Lessons

1. **Use Partial Indexes for Hot Queries**: Filter out 80%+ of unused rows
2. **Save Space and Memory**: Smaller indexes fit in buffer pool
3. **Especially Good for Lifecycle Data**: Unread/active/recent queries
4. **Multiple Partial Indexes**: Different queries can use different partial indexes
5. **Monitor Index Size**: Ensure index size actually decreases

---

## Scenario 8: Temp Tables Vs Deep Subqueries

### Background
A business intelligence team was running complex nightly report generation queries that joined data across 4 different tables with heavy aggregations. These reports were vital for executive dashboards but were taking 45+ minutes to complete, pushing them past their scheduled finish time. The reports needed to finish within a 2-hour window between 10 PM and midnight.

### The Problem

**Scenario: Multi-Join Aggregates with Correlated Subqueries**

```sql
-- Original approach: Deep nested subqueries
SELECT 
    p.product_name,
    (SELECT SUM(qty) 
     FROM sales s 
     WHERE s.product_id = p.product_id) AS total_qty,
    (SELECT SUM(revenue) 
     FROM sales s 
     WHERE s.product_id = p.product_id) AS total_revenue,
    (SELECT COUNT(DISTINCT customer_id) 
     FROM sales s 
     WHERE s.product_id = p.product_id) AS unique_customers,
    (SELECT AVG(quantity) 
     FROM order_items oi 
     JOIN orders o ON oi.order_id = o.id 
     WHERE oi.product_id = p.product_id 
       AND o.order_date >= '2024-01-01') AS recent_avg_qty,
    (SELECT TOP 1 c.category_name 
     FROM product_categories pc 
     JOIN categories c ON pc.category_id = c.id 
     WHERE pc.product_id = p.product_id 
     ORDER BY c.created_at DESC) AS current_category
FROM products p
WHERE p.status = 'ACTIVE'
ORDER BY total_revenue DESC;
```

**Performance Analysis:**

```
Execution with 100,000 active products:
├─ Outer query: Scan products table
├─ For EACH product (100,000 iterations):
│  ├─ Subquery 1: SUM qty (full scan orders)
│  ├─ Subquery 2: SUM revenue (full scan orders)
│  ├─ Subquery 3: COUNT distinct customers
│  ├─ Subquery 4: AVG quantity (join orders + items)
│  ├─ Subquery 5: TOP 1 category (join categories)
│  └─ Total: 5 subqueries per product
├─ Total work: 500,000 subquery executions
└─ Execution time: 45+ minutes

Result:
├─ CPU: 95% max
├─ Memory: 85% max
├─ Disk I/O: 450,000 reads per second
└─ Users affected: All other database users blocked
```

### Root Cause Analysis

1. **Repetitive Aggregations**: Same data aggregated multiple times per product
2. **Poor Query Plan**: Optimizer can't optimize correlated subqueries effectively
3. **I/O Multiplied**: Each subquery reads from disk independently
4. **Sequential Processing**: Can't parallelize work with deep subqueries

### The Solution: Staging with Temporary Tables

```sql
-- Step 1: Prepare aggregate staging table for sales
CREATE TEMP TABLE tmp_product_sales AS
SELECT 
    product_id,
    SUM(qty) AS total_qty,
    SUM(revenue) AS total_revenue,
    COUNT(DISTINCT customer_id) AS unique_customers,
    COUNT(*) AS total_sales
FROM sales
WHERE sale_date >= '2024-01-01'
GROUP BY product_id;

-- Add index for fast joins
CREATE INDEX idx_tmp_product_id ON tmp_product_sales(product_id);

-- Step 2: Recent average quantities
CREATE TEMP TABLE tmp_recent_avg_qty AS
SELECT 
    oi.product_id,
    AVG(oi.quantity) AS recent_avg_qty
FROM order_items oi
INNER JOIN orders o ON oi.order_id = o.id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id;

CREATE INDEX idx_tmp_recent_prod ON tmp_recent_avg_qty(product_id);

-- Step 3: Current categories
CREATE TEMP TABLE tmp_product_categories AS
SELECT DISTINCT
    pc.product_id,
    FIRST_VALUE(c.category_name) OVER (
        PARTITION BY pc.product_id 
        ORDER BY c.created_at DESC
    ) AS current_category
FROM product_categories pc
INNER JOIN categories c ON pc.category_id = c.id;

CREATE INDEX idx_tmp_cat_prod ON tmp_product_categories(product_id);

-- Step 4: Join everything together
SELECT 
    p.product_name,
    COALESCE(ps.total_qty, 0) AS total_qty,
    COALESCE(ps.total_revenue, 0) AS total_revenue,
    COALESCE(ps.unique_customers, 0) AS unique_customers,
    COALESCE(rq.recent_avg_qty, 0) AS recent_avg_qty,
    COALESCE(pc.current_category, 'Uncategorized') AS current_category
FROM products p
LEFT JOIN tmp_product_sales ps ON p.product_id = ps.product_id
LEFT JOIN tmp_recent_avg_qty rq ON p.product_id = rq.product_id
LEFT JOIN tmp_product_categories pc ON p.product_id = pc.product_id
WHERE p.status = 'ACTIVE'
ORDER BY COALESCE(ps.total_revenue, 0) DESC;

-- Step 5: Clean up temporary tables
DROP TABLE IF EXISTS tmp_product_sales;
DROP TABLE IF EXISTS tmp_recent_avg_qty;
DROP TABLE IF EXISTS tmp_product_categories;
```

### Alternative: Single CTE Approach

```sql
-- For simpler cases, combine CTEs
WITH product_sales AS (
    SELECT 
        product_id,
        SUM(qty) AS total_qty,
        SUM(revenue) AS total_revenue,
        COUNT(DISTINCT customer_id) AS unique_customers
    FROM sales
    WHERE sale_date >= '2024-01-01'
    GROUP BY product_id
),
recent_averages AS (
    SELECT 
        oi.product_id,
        AVG(oi.quantity) AS recent_avg_qty
    FROM order_items oi
    INNER JOIN orders o ON oi.order_id = o.id
    WHERE o.order_date >= '2024-01-01'
    GROUP BY oi.product_id
),
product_categories_latest AS (
    SELECT DISTINCT
        pc.product_id,
        FIRST_VALUE(c.category_name) OVER (
            PARTITION BY pc.product_id 
            ORDER BY c.created_at DESC
        ) AS current_category
    FROM product_categories pc
    INNER JOIN categories c ON pc.category_id = c.id
)
SELECT 
    p.product_name,
    COALESCE(ps.total_qty, 0) AS total_qty,
    COALESCE(ps.total_revenue, 0) AS total_revenue,
    COALESCE(ps.unique_customers, 0) AS unique_customers,
    COALESCE(ra.recent_avg_qty, 0) AS recent_avg_qty,
    COALESCE(pc2.current_category, 'Uncategorized') AS current_category
FROM products p
LEFT JOIN product_sales ps ON p.product_id = ps.product_id
LEFT JOIN recent_averages ra ON p.product_id = ra.product_id
LEFT JOIN product_categories_latest pc2 ON p.product_id = pc2.product_id
WHERE p.status = 'ACTIVE'
ORDER BY COALESCE(ps.total_revenue, 0) DESC;
```

### Performance Comparison

```
BEFORE (Nested Subqueries):
├─ Execution time: 45 minutes
├─ Subquery executions: 500,000
├─ CPU usage: 95% (maxed out)
├─ Memory usage: 85%
├─ Disk I/O: 450,000 reads/sec
└─ Result: Report misses deadline

AFTER (Temp Tables):
├─ Execution time: 3.5 minutes
├─ Subquery executions: 4 (~500,000x fewer)
├─ CPU usage: 25%
├─ Memory usage: 12%
├─ Disk I/O: 15,000 reads/sec
└─ Result: Report completes early

IMPROVEMENT:
├─ 12x faster (45 min → 3.5 min)
├─ 99.9% fewer subqueries
├─ 18x less CPU
├─ 125x reduction in disk I/O
└─ Can now run hourly instead of nightly!
```

### Troubleshooting Temp Table Issues

```sql
-- Check temp table space usage
SELECT 
    name,
    size * 8 / 1024 AS size_mb
FROM tempdb.sys.database_files;

-- Monitor temp table statistics
SELECT 
    object_id,
    rows,
    CAST(reserved_page_count * 8.0 / 1024 AS DECIMAL(18, 2)) AS reserved_mb
FROM tempdb.sys.dm_db_partition_stats
WHERE object_id > 100;

-- Prevent temp table locks
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- Use BEGIN/END to ensure cleanup
BEGIN TRY
    CREATE TABLE #TempData (id INT);
    -- Do work here
    DROP TABLE #TempData;
END TRY
BEGIN CATCH
    IF OBJECT_ID('tempdb..#TempData') IS NOT NULL
        DROP TABLE #TempData;
    THROW;
END CATCH
```

### Key Lessons

1. **Temp Tables for Complex Reports**: Break into staging steps
2. **Index Temp Tables**: Don't forget indexes on join keys
3. **CTEs vs Temp Tables**: CTEs for simplicity, temp tables for very large datasets
4. **Clean Up Properly**: Always drop temporary tables to free resources
5. **Monitor Tempdb**: Ensure enough space; monitor growth

---

## Scenario 9: Recursive CTE at Scale

### Background
A financial fraud detection system needed to identify fraudulent rings—networks of accounts involved in coordinated fraud. Fraudsters often created chains of accounts to funnel stolen money through intermediaries. The system needed to identify all connected accounts up to 7 levels deep to catch sophisticated fraud rings.

### The Problem

**Scenario: Fraud Chain Detection Across Multiple Account Hops**

```sql
-- Original approach: Multiple self-joins (only works for fixed depth)
SELECT 
    t1.src_account,
    t1.dst_account,
    t2.dst_account AS hop2,
    t3.dst_account AS hop3,
    t4.dst_account AS hop4,
    t5.dst_account AS hop5,
    t6.dst_account AS hop6,
    t7.dst_account AS hop7
FROM transfers t1
LEFT JOIN transfers t2 ON t1.dst_account = t2.src_account
LEFT JOIN transfers t3 ON t2.dst_account = t3.src_account
LEFT JOIN transfers t4 ON t3.dst_account = t4.src_account
LEFT JOIN transfers t5 ON t4.dst_account = t5.src_account
LEFT JOIN transfers t6 ON t5.dst_account = t6.src_account
LEFT JOIN transfers t7 ON t6.dst_account = t7.src_account
WHERE t1.src_account = 'FRAUD001';

-- Problems with this approach:
-- 1. Fixed depth (can't go deeper than 7)
-- 2. Extremely complex query
-- 3. Cartesian product risk (exponential growth)
-- 4. Slow for large networks
```

**Performance Issues:**

```
Problems:
├─ Execution Time: 45 seconds
├─ 7 self-joins required
├─ Can't exceed 7 hops
├─ Query hard to understand and maintain
└─ Adding one more hop = exponentially slower
```

### Solution: Recursive Common Table Expression (CTE)

```sql
-- Recursive CTE: Elegant solution for variable-depth traversal
WITH RECURSIVE fraud_chain AS (
    -- Anchor: Starting point (fraudster's primary account)
    SELECT 
        src_account,
        dst_account,
        transfer_date,
        1 AS depth,
        src_account AS root_fraudster
    FROM transfers
    WHERE src_account = 'FRAUD001'
      AND transfer_date >= DATEADD(MONTH, -6, GETDATE())
    
    UNION ALL
    
    -- Recursive: Follow the chain
    SELECT 
        fc.src_account,
        t.dst_account,
        t.transfer_date,
        fc.depth + 1,
        fc.root_fraudster
    FROM fraud_chain fc
    INNER JOIN transfers t ON fc.dst_account = t.src_account
    WHERE fc.depth < 7  -- Limit recursion depth
      AND t.transfer_date >= DATEADD(MONTH, -6, GETDATE())
)
SELECT *
FROM fraud_chain
ORDER BY depth, src_account;
```

### Complete Implementation with Optimizations

```sql
-- Optimized recursive CTE with best practices
WITH RECURSIVE fraud_detection AS (
    -- ANCHOR MEMBER: Starting points (known fraudsters)
    SELECT 
        src_account,
        dst_account,
        transfer_date,
        transfer_amount,
        1 AS chain_depth,  -- Current depth
        CAST(src_account AS VARCHAR(MAX)) AS chain_path,  -- Track path
        src_account AS root_account,
        transfer_date AS first_transfer  -- Track timing
    FROM transfers
    WHERE src_account IN (
        SELECT account_id FROM flagged_accounts WHERE risk_level = 'CRITICAL'
    )
    AND transfer_date >= DATEADD(MONTH, -12, GETDATE())
    
    UNION ALL
    
    -- RECURSIVE MEMBER: Keep following chains
    SELECT 
        fd.src_account,
        t.dst_account,
        t.transfer_date,
        t.transfer_amount,
        fd.chain_depth + 1,
        fd.chain_path + ' → ' + t.dst_account,
        fd.root_account,
        fd.first_transfer
    FROM fraud_detection fd
    INNER JOIN transfers t ON fd.dst_account = t.src_account
    WHERE fd.chain_depth < 7  -- Stop at 7 hops to prevent infinite loops
      AND NOT (t.dst_account IN (
        -- Prevent cycles (visiting same account twice)
        SELECT value FROM STRING_SPLIT(fd.chain_path, ' → ')
      ))
      AND t.transfer_date >= DATEADD(MONTH, -12, GETDATE())
      AND t.transfer_amount > 100  -- Minimum transfer amount (filter noise)
)
-- Final aggregation and analysis
SELECT 
    root_account,
    COUNT(*) AS chain_length,
    MAX(chain_depth) AS max_depth,
    SUM(transfer_amount) AS total_transferred,
    COUNT(DISTINCT dst_account) AS unique_accounts_involved,
    MIN(first_transfer) AS chain_start_date,
    MAX(transfer_date) AS chain_end_date,
    STRING_AGG(DISTINCT chain_path, '; ') AS all_paths
FROM fraud_detection
GROUP BY root_account
HAVING COUNT(*) > 5  -- Only report chains with 5+ transfers
ORDER BY total_transferred DESC;
```

### Performance Optimization Techniques

```sql
-- Optimization 1: Add index on transfer columns
CREATE INDEX idx_transfers_src_date
ON transfers(src_account, transfer_date DESC)
INCLUDE (dst_account, transfer_amount);

CREATE INDEX idx_transfers_dst
ON transfers(dst_account)
INCLUDE (src_account, transfer_date);

-- Optimization 2: Limit recursion depth with check
-- Optimization 3: Filter early (WHERE in anchor member)
-- Optimization 4: Prevent cycles (track visited nodes)

-- Optimization 5: Use materialized CTE for large datasets
WITH RECURSIVE fraud_chain_optimized AS (
    -- Anchor: Get critical accounts efficiently
    SELECT 
        t.src_account,
        t.dst_account,
        1 AS depth
    FROM transfers t
    WHERE t.src_account IN (
        -- Pre-filtered list of known fraudsters
        SELECT fa.account_id 
        FROM flagged_accounts fa
        WHERE fa.risk_level = 'CRITICAL'
    )
    AND t.transfer_date >= DATEADD(MONTH, -6, GETDATE())
    AND t.transfer_amount > 500  -- Minimum amount
    
    UNION ALL
    
    SELECT 
        fco.src_account,
        t.dst_account,
        fco.depth + 1
    FROM fraud_chain_optimized fco
    INNER JOIN transfers t ON fco.dst_account = t.src_account
    WHERE fco.depth < 7
      AND t.transfer_date >= DATEADD(MONTH, -6, GETDATE())
)
SELECT * FROM fraud_chain_optimized;
```

### Performance Comparison

```
BEFORE (7 Manual Self-Joins):
├─ Query Complexity: Very high (7 joins to write)
├─ Execution Time: 45 seconds
├─ Max Depth: 7 (fixed)
├─ Difficulty to Change: High (must rewrite query)
└─ Risk of Cartesian Product: High

AFTER (Recursive CTE):
├─ Query Complexity: Moderate (easier to understand)
├─ Execution Time: 8 seconds
├─ Max Depth: Configurable (set in WHILE condition)
├─ Difficulty to Change: Low (change 1 number)
└─ Risk of Cartesian Product: Low (with cycle detection)

IMPROVEMENT:
├─ 5.6x faster
├─ Flexible depth
├─ More maintainable
└─ Easier to debug
```

### Troubleshooting Common Issues

```sql
-- Issue 1: Infinite recursion (query runs forever)
-- Solution: Always have WHERE condition limiting depth
WHERE fc.depth < 10;

-- Issue 2: Cycles (same account visited multiple times)
-- Solution: Track visited nodes
DECLARE @VisitedAccounts TABLE (account_id VARCHAR(50));

-- Issue 3: Out of stack/memory
-- Solution: Reduce recursion depth, filter earlier

-- Issue 4: Performance degradation
-- Solution: Add indexes, materialize intermediate results

-- Monitoring recursive CTE performance
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

WITH RECURSIVE chain AS (
    SELECT ... 
)
SELECT * FROM chain;

-- Check execution time and logical reads
```

### PostgreSQL Implementation

```sql
-- PostgreSQL recursive CTE syntax
WITH RECURSIVE fraud_chain AS (
    -- Anchor member
    SELECT 
        src_account,
        dst_account,
        1 AS depth,
        ARRAY[src_account] AS path  -- Track visited nodes
    FROM transfers
    WHERE src_account = 'FRAUD001'
    
    UNION ALL
    
    -- Recursive member
    SELECT 
        fc.src_account,
        t.dst_account,
        fc.depth + 1,
        fc.path || t.dst_account  -- Append to path
    FROM fraud_chain fc
    JOIN transfers t ON fc.dst_account = t.src_account
    WHERE fc.depth < 7
      AND NOT t.dst_account = ANY(fc.path)  -- Prevent cycles
)
SELECT * FROM fraud_chain;
```

### Key Lessons

1. **Recursive CTEs for Variable Depth**: Much cleaner than fixed self-joins
2. **Always Limit Recursion**: Prevent infinite loops with depth limit
3. **Prevent Cycles**: Track visited nodes or use history tables
4. **Index Strategically**: Index on recursion columns (src, dst)
5. **Test with Safety Limits**: Start with small depth limit during development

---

## Scenario 10: Avoid OR in JOIN Conditions

### Background
A loyalty program system needed to match customers with merchants. Merchants could be identified by either:
1. Their primary `merchant_id` (the unique ID)
2. Their `legacy_merchant_code` (from a previous system that was merged in)

The system needed to handle both identifiers during a gradual migration from the legacy system. However, queries using OR in JOIN conditions were performing terribly.

### The Problem

**Scenario: Flexible Join Conditions**

```sql
-- Original approach: OR in JOIN
SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customers c
LEFT JOIN merchants m ON 
    (c.merchant_id = m.merchant_id 
     OR c.legacy_merchant_code = m.legacy_code)
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'
ORDER BY t.transaction_date DESC;
```

**Performance Issues:**

```
Execution Plan:
├─ Scan transactions (100M rows) ✓
├─ For EACH transaction:
│  ├─ Try condition 1: c.merchant_id = m.merchant_id
│  ├─ Try condition 2: c.legacy_merchant_code = m.legacy_code
│  ├─ Choose option that matches (if either)
│  └─ Can't use b-tree index (OR makes predicate non-SARGable)
└─ Result: Full table scan, nested loop, no index usage

Performance:
├─ Execution Time: 9,000 ms
├─ Table Scans: Multiple full scans
├─ Index Usage: None (OR prevents index use)
└─ CPU: 85%
```

### Root Cause Analysis

**Why OR in JOIN is Problematic:**

1. **Non-SARGable Predicate**: SARG = Search Argument
   - Optimizer can't use index with OR across different columns
   - Must evaluate all rows instead of seeking

2. **Query Optimization Failure**: Optimizer can't determine:
   - Which rows satisfy condition 1?
   - Which rows satisfy condition 2?
   - How to use composite indexes?

3. **Cartesian Product Risk**: Can match same row twice if both conditions true

### The Solution: Separate the OR Conditions

```sql
-- Solution 1: Use UNION to separate OR into separate queries
SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customers c
INNER JOIN merchants m ON c.merchant_id = m.merchant_id
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'

UNION ALL

SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customers c
INNER JOIN merchants m ON c.legacy_merchant_code = m.legacy_code
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'
  AND NOT EXISTS (
    -- Avoid duplicates: exclude if already matched via merchant_id
    SELECT 1 FROM merchants m2 
    WHERE m2.merchant_id = c.merchant_id
  )
ORDER BY transaction_date DESC;
```

### Alternative Solution: WHERE-Based Filtering

```sql
-- Solution 2: Use separate JOINs, then filter with WHERE
SELECT 
    c.customer_id,
    c.customer_name,
    COALESCE(m1.merchant_name, m2.merchant_name) AS merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customers c
INNER JOIN transactions t ON c.customer_id = t.customer_id
LEFT JOIN merchants m1 ON c.merchant_id = m1.merchant_id
LEFT JOIN merchants m2 ON c.legacy_merchant_code = m2.legacy_code
WHERE t.transaction_date >= '2024-01-01'
  AND (m1.merchant_id IS NOT NULL 
       OR m2.merchant_id IS NOT NULL)
ORDER BY t.transaction_date DESC;
```

### Best Solution: Normalize Data

```sql
-- Solution 3: Create normalized view (best long-term)
-- Merge merchant_id and legacy_code into single identifier
CREATE VIEW customer_merchant_mapping AS
SELECT 
    customer_id,
    merchant_id,
    'PRIMARY' AS source
FROM customers
WHERE merchant_id IS NOT NULL

UNION ALL

SELECT 
    customer_id,
    m.merchant_id,
    'LEGACY' AS source
FROM customers c
INNER JOIN merchants m ON c.legacy_merchant_code = m.legacy_code
WHERE c.merchant_id IS NULL;

-- Now query becomes simple
SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customer_merchant_mapping cmm
INNER JOIN customers c ON cmm.customer_id = c.customer_id
INNER JOIN merchants m ON cmm.merchant_id = m.merchant_id
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'
ORDER BY t.transaction_date DESC;
```

### Complete Implementation Guide

```sql
-- Step 1: Analyze current query performance
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date
FROM customers c
LEFT JOIN merchants m ON 
    (c.merchant_id = m.merchant_id 
     OR c.legacy_merchant_code = m.legacy_code)
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'
ORDER BY t.transaction_date DESC;

-- Results: 9,000 ms, 234,567 reads

-- Step 2: Refactor to UNION approach
SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date,
    'primary' AS match_type
FROM customers c
INNER JOIN merchants m ON c.merchant_id = m.merchant_id
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'

UNION ALL

SELECT 
    c.customer_id,
    c.customer_name,
    m.merchant_name,
    t.transaction_amount,
    t.transaction_date,
    'legacy' AS match_type
FROM customers c
INNER JOIN merchants m ON c.legacy_merchant_code = m.legacy_code
INNER JOIN transactions t ON c.customer_id = t.customer_id
WHERE t.transaction_date >= '2024-01-01'
  AND NOT EXISTS (
    SELECT 1 FROM merchants m2 
    WHERE m2.merchant_id = c.merchant_id
  )
ORDER BY transaction_date DESC;

-- Results: 1,100 ms, 8,900 reads (dramatic improvement!)

-- Step 3: Add appropriate indexes
CREATE INDEX idx_merchants_id 
ON merchants(merchant_id);

CREATE INDEX idx_merchants_legacy 
ON merchants(legacy_code);

CREATE INDEX idx_customers_merchant_id 
ON customers(merchant_id);

CREATE INDEX idx_customers_legacy_code 
ON customers(legacy_merchant_code);

CREATE INDEX idx_transactions_customer_date
ON transactions(customer_id, transaction_date DESC)
INCLUDE (transaction_amount);
```

### Performance Comparison

```
BEFORE (OR in JOIN):
├─ Execution Time: 9,000 ms
├─ Logical Reads: 234,567
├─ Index Usage: None
├─ CPU: 85%
├─ Plan Complexity: High
└─ Users Supported: 10/sec

AFTER (UNION with separate JOINs):
├─ Execution Time: 1,100 ms
├─ Logical Reads: 8,900
├─ Index Usage: Full (both indexes used)
├─ CPU: 12%
├─ Plan Complexity: Moderate
└─ Users Supported: 80/sec (8x more!)

IMPROVEMENT:
├─ 8x faster
├─ 96% fewer disk reads
├─ Indexes now effective
└─ Much more CPU efficient
```

### Key Lessons

1. **Avoid OR in JOIN Conditions**: Non-SARGable predicates prevent index usage
2. **Use UNION Instead**: Separate OR conditions into separate queries
3. **Create Materialized Views**: Normalize data on insert, not query time
4. **Index Both Paths**: Ensure indexes exist for both join conditions
5. **Test Performance**: Always verify index usage with actual indexes

---

## Trade-offs & Common Challenges

When applying SQL optimization techniques, be aware of these trade-offs and common challenges:

| Challenge | Impact | Trade-Off | Solution |
|-----------|--------|-----------|----------|
| **Too Many Indexes** | Slower inserts/updates/deletes | High write cost | Monitor write performance, remove unused indexes |
| **Overuse of Partial Indexes** | Query planner confusion | May use full index scan | Test with production stats, keep WHERE simple |
| **Deep Recursion in CTEs** | Memory/execution limits | Hard to debug recursion | Set depth limit, materialize intermediate results |
| **Large Temp Tables** | Tempdb fragmentation | Disk I/O increases | Clean up explicitly, validate tempdb size |
| **Large Composite Indexes** | Index bloat, slow writes | Massive write overhead | Limit to hot query paths, use INCLUDE wisely |
| **Function-based WHERE** | Prevents index (non-SARGable) | Query becomes slow | Denormalize or computed columns |
| **SELECT *** | Wastes bandwidth/memory | Can disable index-only scans | Explicitly list needed columns |
| **Cross-Database Portability** | Optimization not portable | Different syntax/features | Use version-appropriate syntax |

---

## Final Checklist

When optimizing SQL queries, systematically work through this checklist:

### Query Analysis Phase
- ✔ Run EXPLAIN ANALYZE (PostgreSQL) or SET STATISTICS (SQL Server)
- ✔ Identify bottleneck operations (full scans, nested loops, sorts)
- ✔ Measure baseline performance (time, reads, CPU)
- ✔ Understand data volumes and distribution
- ✔ Check query frequency (is optimization worth the effort?)

### Index Strategy Phase
- ✔ Identify columns used in WHERE clauses
- ✔ Identify columns used in JOIN conditions
- ✔ Identify columns used in ORDER BY clauses
- ✔ Create composite indexes with proper column order
- ✔ Consider INCLUDE/covering columns for index-only scans
- ✔ Evaluate partial indexes for filtering hot queries
- ✔ Avoid indexing frequently updated columns

### Query Refactoring Phase
- ✔ Replace IN lists with JOINs (if list > 1K items)
- ✔ Replace correlated subqueries with CTEs
- ✔ Avoid UNION ALL when SELECT * is suboptimal
- ✔ Break complex queries into temp tables
- ✔ Use window functions instead of previous row calculations
- ✔ Avoid functions in WHERE clauses (non-SARGable)
- ✔ Remove OR conditions from JOIN predicates
- ✔ Rewrite OFFSET pagination to keyset pagination

### Data Type Phase
- ✔ Right-size data types (INT vs TINYINT)
- ✔ Avoid excessive precision (DATETIME(6) → DATETIME)
- ✔ Use appropriate data types for range (SMALLINT for 0-100)
- ✔ Consider storage impact (bytes × rows × volatility)

### Maintenance Phase
- ✔ Update statistics after large data changes
- ✔ Rebuild fragmented indexes (> 30% fragmentation)
- ✔ Reorganize moderately fragmented indexes (10-30%)
- ✔ Monitor index usage; remove unused indexes
- ✔ Schedule regular maintenance windows
- ✔ Plan for table/index growth
- ✔ Archive old data rather than deleting (keeps indexes compact)

### Validation Phase
- ✔ Verify optimization with realistic data volume
- ✔ Test with production-like data distribution
- ✔ Measure performance improvement quantitatively
- ✔ Check for correctness (results unchanged)
- ✔ Monitor for unintended side effects
- ✔ Verify in staging before production deployment
- ✔ Plan rollback if optimization degrades other queries
- ✔ Document baseline vs optimized metrics

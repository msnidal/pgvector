SET enable_seqscan = off;

-- L2

CREATE TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_l2_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <-> '[3,3,3]';
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> (SELECT NULL::vector)) t2;
SELECT COUNT(*) FROM t;

TRUNCATE t;
SELECT * FROM t ORDER BY val <-> '[3,3,3]';

DROP TABLE t;

-- inner product

CREATE TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_ip_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <#> '[3,3,3]';
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <#> (SELECT NULL::vector)) t2;

DROP TABLE t;

-- cosine

CREATE TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_cosine_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <=> '[3,3,3]';
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <=> '[0,0,0]') t2;
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <=> (SELECT NULL::vector)) t2;

DROP TABLE t;

-- L1

CREATE TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_l1_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <+> '[3,3,3]';
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <+> (SELECT NULL::vector)) t2;

DROP TABLE t;

-- iterative

CREATE TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_l2_ops);

SET hnsw.iterative_scan = strict_order;
SET hnsw.ef_search = 1;
SELECT * FROM t ORDER BY val <-> '[3,3,3]';

SET hnsw.iterative_scan = relaxed_order;
SELECT * FROM t ORDER BY val <-> '[3,3,3]';

TRUNCATE t;
SELECT * FROM t ORDER BY val <-> '[3,3,3]';

RESET hnsw.iterative_scan;
RESET hnsw.ef_search;
DROP TABLE t;

-- unlogged

CREATE UNLOGGED TABLE t (val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING hnsw (val vector_l2_ops);

SELECT * FROM t ORDER BY val <-> '[3,3,3]';

DROP TABLE t;

-- INCLUDE - build index

CREATE TABLE t (val vector(3), val2 int);
INSERT INTO t (val, val2) VALUES ('[0,0,0]', 1), ('[1,2,3]', 3), ('[1,1,1]', 2);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) INCLUDE (val2);

SELECT * FROM t ORDER BY val <-> '[3,3,3]';

DROP TABLE t;

-- INCLUDE - insert into index

CREATE TABLE t (val vector(3), val2 int);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) INCLUDE (val2);

INSERT INTO t (val, val2) VALUES ('[0,0,0]', 1), ('[1,2,3]', 3), ('[1,1,1]', 2);

SELECT * FROM t ORDER BY val <-> '[3,3,3]';

DROP TABLE t;

-- INCLUDE filters (extension-side ACORN predicates)

CREATE TABLE t (val vector(3), val2 int);
INSERT INTO t (val, val2) VALUES ('[0,0,0]', 1), ('[1,2,3]', 3), ('[1,1,1]', 2), ('[1,2,4]', 4);
CREATE INDEX t_hnsw_idx ON t USING hnsw (val vector_l2_ops) INCLUDE (val2);

BEGIN;
SELECT hnsw_set_filter('t_hnsw_idx', 'val2', '>=', '2');
SELECT hnsw_set_filter('t_hnsw_idx', 'val2', '<=', '3');
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
COMMIT;

SELECT * FROM t ORDER BY val <-> '[3,3,3]';

BEGIN;
SELECT hnsw_set_filter('t_hnsw_idx', 'val2', '=', '4');
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
SELECT hnsw_clear_filter('t_hnsw_idx');
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
COMMIT;

BEGIN;
SELECT hnsw_set_filter('t_hnsw_idx', 'val2', '>=', '3');
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
SELECT hnsw_clear_filters();
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
COMMIT;

SELECT hnsw_set_filter('t_hnsw_idx', 'val2', '!=', '2');
BEGIN;
SELECT hnsw_set_filter('t_hnsw_idx', 'missing', '=', '2');
SELECT * FROM t ORDER BY val <-> '[3,3,3]';
ROLLBACK;

SELECT * FROM t ORDER BY val <-> '[3,3,3]';

DROP TABLE t;

-- options

CREATE TABLE t (val vector(3));
CREATE INDEX ON t USING hnsw (val vector_l2_ops) WITH (m = 1);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) WITH (m = 101);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) WITH (ef_construction = 3);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) WITH (ef_construction = 1001);
CREATE INDEX ON t USING hnsw (val vector_l2_ops) WITH (m = 16, ef_construction = 31);

SHOW hnsw.ef_search;

SET hnsw.ef_search = 0;
SET hnsw.ef_search = 1001;

SHOW hnsw.iterative_scan;

SET hnsw.iterative_scan = on;

SHOW hnsw.max_scan_tuples;

SET hnsw.max_scan_tuples = 0;

SHOW hnsw.scan_mem_multiplier;

SET hnsw.scan_mem_multiplier = 0;
SET hnsw.scan_mem_multiplier = 1001;

DROP TABLE t;

-- Pin the current coverage of `allow_non_metadata_alters = 0` on MergeTree.
--
-- The setting is only enforced by `MergeTreeData::checkAlterIsPossible`,
-- which routes AlterCommands through `AlterCommands::getMutationCommands`
-- with `with_alters = false`. Anything that reaches the engine as an explicit
-- `MutationCommand` (ALTER UPDATE/DELETE, MATERIALIZE ..., APPLY ...) or
-- through the lightweight `DELETE`/`UPDATE` paths bypasses the check.
--
-- This test pins both the blocked and the not-blocked cases so a coverage
-- change in either direction shows up as a diff. See
-- notes/allow_non_metadata_alters-gap-testing-handover.md for context.
-- Extends 01413_allow_non_metadata_alters (do not fold into that file).
--
-- Assertion mechanics (why the reference file looks sparse):
--   - Positive block: each ALTER carries a
--       -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }
--     directive. `clickhouse-test` parses this and fails the test if the
--     statement succeeds OR throws a different error code. When the
--     expected error fires, the harness suppresses the exception text and
--     the reference file contains only the section-marker `SELECT` line.
--   - Gap block: no `serverError` directive. The statement must succeed —
--     if it throws, the exception text lands in stdout and the reference
--     diff fails. Each gap is then followed by a `SELECT count() FROM
--     system.mutations` so the reference pins both that the statement was
--     accepted AND (where applicable) that it enqueued a mutation entry.
--   - Happy-path block: no directive; a bare `SELECT 'ok'` per case
--     confirms the statement ran and no exception intercepted stdout.

DROP TABLE IF EXISTS ana_gaps;

CREATE TABLE ana_gaps
(
    key UInt64,
    v_str String,
    v_num UInt16,
    v_dt  DateTime,
    v_d   Date,
    v_mat UInt64 MATERIALIZED key * 2,
    v_ali UInt64 ALIAS key * 3
)
ENGINE = MergeTree()
PARTITION BY tuple()
ORDER BY key
SETTINGS
    enable_block_number_column = 1,
    enable_block_offset_column = 1,
    -- Pin `finished_mutations_to_keep` well above the number of mutations
    -- this test enqueues, so completed rows are never purged from
    -- `system.mutations` mid-test and the running counts below stay stable
    -- regardless of the server-level default.
    finished_mutations_to_keep = 1000;

INSERT INTO ana_gaps (key, v_str, v_num, v_dt, v_d) VALUES (1, 'a', 1, '2020-01-01 00:00:00', '2020-01-01');


-- ---------------------------------------------------------------------------
-- Positive assertions: the setting DOES refuse these on MergeTree.
-- ---------------------------------------------------------------------------

SET allow_non_metadata_alters = 0;

SELECT '-- positive: DROP COLUMN (physical)';
ALTER TABLE ana_gaps DROP COLUMN v_str; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: MODIFY COLUMN (non-metadata type change)';
ALTER TABLE ana_gaps MODIFY COLUMN v_str UInt64; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: RENAME COLUMN';
ALTER TABLE ana_gaps RENAME COLUMN v_str TO v_str2; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: CLEAR COLUMN IN PARTITION';
ALTER TABLE ana_gaps CLEAR COLUMN v_str IN PARTITION tuple(); -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

-- Index / projection / statistics drop paths.
SET allow_non_metadata_alters = 1;
ALTER TABLE ana_gaps ADD INDEX idx_v_num v_num TYPE minmax GRANULARITY 1;
ALTER TABLE ana_gaps ADD PROJECTION proj_v_num (SELECT v_num ORDER BY v_num);
SET allow_non_metadata_alters = 0;

SELECT '-- positive: DROP INDEX';
ALTER TABLE ana_gaps DROP INDEX idx_v_num; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: CLEAR INDEX IN PARTITION';
ALTER TABLE ana_gaps CLEAR INDEX idx_v_num IN PARTITION tuple(); -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: DROP PROJECTION';
ALTER TABLE ana_gaps DROP PROJECTION proj_v_num; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }

SELECT '-- positive: MODIFY TTL (rewrite path)';
SET materialize_ttl_after_modify = 1;
ALTER TABLE ana_gaps MODIFY TTL v_d + INTERVAL 5 DAY; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }
SET materialize_ttl_after_modify = 0;

SELECT '-- positive: DROP COLUMN of MATERIALIZED column (has physical data)';
ALTER TABLE ana_gaps DROP COLUMN v_mat; -- { serverError ALTER_OF_COLUMN_IS_FORBIDDEN }


-- ---------------------------------------------------------------------------
-- Negative assertions: the setting does NOT refuse these today. Pin the gap.
-- Each block ends with a marker so the reference file makes the gap explicit.
-- ---------------------------------------------------------------------------

SET allow_non_metadata_alters = 0;

SELECT '-- gap: ALTER TABLE ... UPDATE (explicit heavy mutation)';
ALTER TABLE ana_gaps UPDATE v_num = 42 WHERE key = 1;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: ALTER TABLE ... DELETE (explicit heavy mutation)';
ALTER TABLE ana_gaps DELETE WHERE key = 999;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: MATERIALIZE INDEX';
-- idx_v_num was added earlier and its DROP was refused, so it still exists.
ALTER TABLE ana_gaps MATERIALIZE INDEX idx_v_num;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: MATERIALIZE PROJECTION';
-- proj_v_num was added earlier and its DROP was refused, so it still exists.
ALTER TABLE ana_gaps MATERIALIZE PROJECTION proj_v_num;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: MATERIALIZE COLUMN (default backfill)';
SET allow_non_metadata_alters = 1;
ALTER TABLE ana_gaps ADD COLUMN v_backfill UInt64 DEFAULT key + 100;
SET allow_non_metadata_alters = 0;
ALTER TABLE ana_gaps MATERIALIZE COLUMN v_backfill;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: MATERIALIZE TTL';
-- Need a TTL to materialize. Setting it requires a metadata-only path
-- (materialize_ttl_after_modify = 0 keeps MODIFY TTL from being routed as a
-- data-rewrite mutation).
SET allow_non_metadata_alters = 1;
SET materialize_ttl_after_modify = 0;
ALTER TABLE ana_gaps MODIFY TTL v_d + INTERVAL 5 DAY;
SET allow_non_metadata_alters = 0;
ALTER TABLE ana_gaps MATERIALIZE TTL;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: APPLY DELETED MASK';
ALTER TABLE ana_gaps APPLY DELETED MASK;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: DROP COLUMN of ALIAS column (metadata-only, not blocked, does not enqueue a mutation)';
ALTER TABLE ana_gaps DROP COLUMN v_ali;
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';


-- ---------------------------------------------------------------------------
-- Lightweight DELETE / UPDATE — bypass checkAlterIsPossible entirely.
-- Both are enabled by default (enable_lightweight_update = 1).
-- ---------------------------------------------------------------------------

-- Lightweight DELETE / UPDATE default to refusing tables that have projections
-- (`lightweight_mutation_projection_mode = 'throw'` is a MergeTree table-level
-- setting). Drop the projection first so the lightweight path itself is what
-- gets exercised.
SET allow_non_metadata_alters = 1;
ALTER TABLE ana_gaps DROP PROJECTION proj_v_num;
SET allow_non_metadata_alters = 0;

SELECT '-- gap: lightweight DELETE FROM ... WHERE';
DELETE FROM ana_gaps WHERE key = 999;
-- Empirically lightweight DELETE enqueues two `system.mutations` entries here
-- (the deletion itself plus a follow-up); pin the observed count.
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';

SELECT '-- gap: lightweight UPDATE ... SET ... WHERE';
UPDATE ana_gaps SET v_num = 7 WHERE key = 1;
-- Empirically lightweight UPDATE does NOT go through `system.mutations` — it
-- routes only through patch parts. Count stays unchanged.
SELECT 'mutations:', count() FROM system.mutations WHERE database = currentDatabase() AND table = 'ana_gaps';


-- ---------------------------------------------------------------------------
-- Metadata-only ALTERs that should keep working (happy-path regression guard).
-- ---------------------------------------------------------------------------

SELECT '-- happy: ADD COLUMN with constant DEFAULT (metadata-only)';
ALTER TABLE ana_gaps ADD COLUMN v_meta UInt64 DEFAULT 0;
SELECT 'ok';

SELECT '-- happy: MODIFY COLUMN with metadata-only Enum widening';
ALTER TABLE ana_gaps ADD COLUMN v_enum Enum8('a' = 1);
ALTER TABLE ana_gaps MODIFY COLUMN v_enum Enum8('a' = 1, 'b' = 2);
SELECT 'ok';

SELECT '-- happy: COMMENT COLUMN';
ALTER TABLE ana_gaps COMMENT COLUMN v_num 'a comment';
SELECT 'ok';


DROP TABLE ana_gaps;

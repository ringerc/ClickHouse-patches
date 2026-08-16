#!/usr/bin/env bash
# Pin that `allow_non_metadata_alters = 0` does NOT fire on non-MergeTree
# engines. The enforcement lives in `MergeTreeData::checkAlterIsPossible`, so
# every other engine bypasses it.
#
# For each engine we try a representative ALTER (`DROP COLUMN`) that would be
# refused on MergeTree with `allow_non_metadata_alters = 0`. We assert that
# the ALTER either succeeds or fails for a reason other than
# `ALTER_OF_COLUMN_IS_FORBIDDEN` (error code 524). The specific engine-level
# refusal (e.g. NOT_IMPLEMENTED = 48) is not asserted — the point is that the
# setting is not what refused it.
#
# See notes/allow_non_metadata_alters-gap-testing-handover.md for context.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

set -eu

run_case()
{
    local engine=$1
    local create_body=$2

    local table="ana_engines_${engine,,}"
    ${CLICKHOUSE_CLIENT} --query="DROP TABLE IF EXISTS ${table}"
    ${CLICKHOUSE_CLIENT} --query="CREATE TABLE ${table} ${create_body} ENGINE = ${engine}"

    local out
    out=$(${CLICKHOUSE_CLIENT} --allow_non_metadata_alters=0 --server_logs_file=/dev/null \
        --query="ALTER TABLE ${table} DROP COLUMN v" 2>&1 || true)

    if echo "${out}" | grep -q "Code: 524"
    then
        echo "engine=${engine}: BLOCKED (setting fired) [regression]"
    else
        echo "engine=${engine}: not blocked"
    fi

    ${CLICKHOUSE_CLIENT} --query="DROP TABLE IF EXISTS ${table}"
}

run_case Memory    '(key UInt64, v UInt64)'
run_case Log       '(key UInt64, v UInt64)'
run_case TinyLog   '(key UInt64, v UInt64)'
run_case StripeLog '(key UInt64, v UInt64)'

#!/bin/bash
# Disk I/O benchmark using fio.
# Requires: fio.

set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/utils.sh"

TEST_DIR="${1:-/data/fio-test}"
TEST_SIZE="${2:-10G}"

log_info "Running fio benchmark on ${TEST_DIR}..."

mkdir -p "$TEST_DIR"

fio --name=seq-write --rw=write --bs=1M --size="$TEST_SIZE" \
    --directory="$TEST_DIR" --numjobs=1 --direct=1 --iodepth=16 \
    --output-format=json | jq '.jobs[0].write'

fio --name=seq-read --rw=read --bs=1M --size="$TEST_SIZE" \
    --directory="$TEST_DIR" --numjobs=1 --direct=1 --iodepth=16 \
    --output-format=json | jq '.jobs[0].read'

rm -rf "$TEST_DIR"
log_info "fio benchmark completed."

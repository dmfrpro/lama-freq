import filecmp

import pytest

from helpers import statistics
from stress_units import (
    make_deferred_joins,
    make_dense_external,
    make_fallback_replay,
    make_large_closure,
    make_pending_closures,
    make_worklist,
)

pytestmark = pytest.mark.stress


def test_worklist_ram(run_file_analyzer, tmp_path):
    branches = make_worklist(tmp_path / "worklist.bc")
    result, _ = run_file_analyzer(tmp_path / "worklist.bc", "--stats")
    stats = statistics(result.stderr)
    assert stats["reachable instructions"] == 4 * branches + 3
    assert stats["jump labels"] == branches
    assert stats["bigram occurrences"] == 3 * branches + 2
    assert stats["temporary bytes written"] == 0


def test_pending_closures(run_file_analyzer, tmp_path):
    count = make_pending_closures(tmp_path / "pending.bc")
    result, _ = run_file_analyzer(tmp_path / "pending.bc", "--stats")
    stats = statistics(result.stderr)
    assert stats["reachable instructions"] == 2 * count + 4
    assert stats["bigram occurrences"] == 2 * count + 3
    assert stats["temporary bytes written"] == 0


def test_large_closure_keys(run_file_analyzer, tmp_path):
    path = tmp_path / "closure.bc"
    make_large_closure(path)
    interned, interned_output = run_file_analyzer(path, "--memory-limit-mib", "64", "--stats")
    raw, raw_output = run_file_analyzer(path, "--raw-counter", "--memory-limit-mib", "1", "--stats")
    assert statistics(interned.stderr)["raw-key fallback"] == "no"
    assert statistics(raw.stderr)["sorting runs/merges"] > 0
    assert filecmp.cmp(interned_output, raw_output, shallow=False)


def test_dense_external_merge(run_file_analyzer, tmp_path):
    path = tmp_path / "dense.bc"
    make_dense_external(path)
    interned, interned_output = run_file_analyzer(path, "--memory-limit-mib", "64", "--stats")
    raw, raw_output = run_file_analyzer(path, "--raw-counter", "--memory-limit-mib", "1", "--stats")
    assert statistics(interned.stderr)["raw-key fallback"] == "no"
    raw_stats = statistics(raw.stderr)
    assert raw_stats["largest sorting run set"] > 16
    assert raw_stats["sorting merge rounds"] >= 2
    assert filecmp.cmp(interned_output, raw_output, shallow=False)


def test_fallback_replay(run_file_analyzer, tmp_path):
    path = tmp_path / "replay.bc"
    make_fallback_replay(path)
    fallback, fallback_output = run_file_analyzer(path, "--memory-limit-mib", "1", "--stats")
    _, raw_output = run_file_analyzer(path, "--raw-counter", "--memory-limit-mib", "1")
    stats = statistics(fallback.stderr)
    assert stats["raw-key fallback"] == "yes"
    assert stats["sorting runs/merges"] > 0
    assert filecmp.cmp(fallback_output, raw_output, shallow=False)


def test_deferred_joins(run_file_analyzer, tmp_path):
    path = tmp_path / "joins.bc"
    count = make_deferred_joins(path)
    deferred, deferred_output = run_file_analyzer(path, "--stats")
    _, raw_output = run_file_analyzer(path, "--raw-counter", "--memory-limit-mib", "1")
    stats = statistics(deferred.stderr)
    assert stats["reachable instructions"] == 2 * count + 3
    assert stats["jump labels"] == count
    assert stats["bigram occurrences"] == count + 2
    assert filecmp.cmp(deferred_output, raw_output, shallow=False)

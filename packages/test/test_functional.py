from collections import Counter

import pytest

from helpers import check_oracle, frequencies, output_rows, statistics
from isa_cases import CASES, begin, begin_closure, const, i32, instruction, public_main
import make_bad_bc as bad
from oracle import NAMES, expected_output

pytestmark = pytest.mark.functional

BASIC = public_main(begin() + const(1) + const(1) + bytes([0x19, 0x01, 0x18, 0x16, 0x77, 0xFF]))


def test_hand_computed_frequencies(run_analyzer):
    output = check_oracle(run_analyzer, BASIC)
    assert frequencies(output) == Counter(
        {
            "BEGIN 0 0": 1,
            "CONST 1": 2,
            "DUP": 1,
            "ADD": 1,
            "DROP": 1,
            "END": 1,
            "BEGIN 0 0 ; CONST 1": 1,
            "CONST 1 ; CONST 1": 1,
            "CONST 1 ; DUP": 1,
            "DUP ; ADD": 1,
            "ADD ; DROP": 1,
            "DROP ; END": 1,
        }
    )
    assert "0x77" not in output


def test_forward_label_breaks_physical_bigram(run_analyzer):
    unit = public_main(
        begin() + const(0) + instruction(0x50, 25) + const(1) + bytes([0x18]) + const(2) + bytes([0x16, 0x77, 0xFF])
    )
    rows = frequencies(check_oracle(run_analyzer, unit))
    assert "DROP ; CONST 2" not in rows
    assert rows["CJMP_Z 25 ; CONST 1"] == 1


def test_unconditional_jump_skips_code(run_analyzer):
    unit = public_main(begin() + instruction(0x15, 19) + const(1) + const(2) + bytes([0x19, 0x18, 0x16, 0xFF]))
    rows = frequencies(check_oracle(run_analyzer, unit))
    assert "CONST 1" not in rows
    assert rows["CONST 2 ; DUP"] == 1
    assert "JMP 19 ; CONST 2" not in rows


def test_backward_label_discovered_after_fallthrough(run_analyzer):
    unit = public_main(
        begin()
        + const(0)
        + instruction(0x51, 30)
        + const(1)
        + bytes([0x18])
        + instruction(0x15, 40)
        + const(2)
        + instruction(0x50, 19)
        + const(3)
        + bytes([0x16, 0xFF])
    )
    rows = frequencies(check_oracle(run_analyzer, unit))
    assert rows["DROP"] == 1
    assert rows["CJMP_Z 19"] == 1
    assert "CJMP_NZ 30 ; CONST 1" not in rows


def test_direct_call_counts_target_and_continuation(run_analyzer):
    unit = public_main(
        begin() + instruction(0x56, 25, 0) + const(7) + bytes([0x18, 0x16]) + begin() + const(8) + bytes([0x16, 0xFF])
    )
    rows = frequencies(check_oracle(run_analyzer, unit))
    assert rows["CALL 25 0 ; CONST 7"] == 1
    assert rows["CONST 8"] == 1
    assert "END ; BEGIN 0 0" not in rows


def closure_without_call():
    return public_main(
        begin(0, 1)
        + instruction(0x54, 24, 1)
        + bytes([1])
        + i32(0)
        + bytes([0x16])
        + begin_closure(0, 0, 1)
        + instruction(0x23, 0)
        + bytes([0x16, 0xFF])
    )


def closure_calls():
    return public_main(
        begin(0, 1)
        + instruction(0x54, 49, 1)
        + bytes([1])
        + i32(0)
        + instruction(0x55, 0)
        + instruction(0x54, 68, 1)
        + bytes([1])
        + i32(0)
        + instruction(0x55, 0)
        + bytes([0x18, 0x16])
        + begin_closure(0, 0, 1)
        + instruction(0x23, 0)
        + bytes([0x16])
        + begin_closure(0, 0, 1)
        + instruction(0x23, 0)
        + bytes([0x16, 0xFF])
    )


def test_closure_body_is_not_reachable_without_indirect_call(run_analyzer):
    rows = frequencies(check_oracle(run_analyzer, closure_without_call()))
    assert "BEGIN_CLOSURE 0 0 1" not in rows
    assert "LD_CLO 0" not in rows


def test_indirect_calls_activate_all_created_closures(run_analyzer):
    rows = frequencies(check_oracle(run_analyzer, closure_calls()))
    assert rows["BEGIN_CLOSURE 0 0 1"] == 2
    assert rows["LD_CLO 0"] == 2
    assert rows["CALLC 0"] == 2


def test_unreachable_closure_body_is_not_decoded(run_analyzer):
    unit = public_main(
        begin(0, 1)
        + instruction(0x54, 24, 1)
        + bytes([1])
        + i32(0)
        + bytes([0x16, 0x53])
        + i32(0, 0, 1)
        + bytes([0x77, 0xFF])
    )
    assert "BEGIN_CLOSURE" not in check_oracle(run_analyzer, unit)


def test_public_roots_and_root_flag_precedence(run_analyzer):
    unit = bad.with_code(
        begin() + const(0) + bytes([0x16]) + begin() + const(42) + bytes([0x16, 0xFF]),
        strings=b"f\0",
        pubs=[(0, 15, 0)],
    )
    default = check_oracle(run_analyzer, unit)
    rooted = check_oracle(run_analyzer, unit, "--root-zero", root_zero=True)
    assert check_oracle(run_analyzer, unit, "--root-zero", "--public-only") == default
    assert check_oracle(run_analyzer, unit, "--public-only", "--root-zero", root_zero=True) == rooted
    assert frequencies(default)["CONST 42"] == 1
    assert frequencies(rooted)["BEGIN 0 0"] == 2
    assert frequencies(rooted)["CONST 42"] == 1


def test_public_function_and_global_namespaces_are_independent(run_analyzer):
    unit = bad.with_code(
        begin() + const(1) + bytes([0x16, 0xFF]),
        strings=b"x\0",
        globals_=1,
        pubs=[(0, 0, 0), (0, 0, 1)],
    )
    assert frequencies(check_oracle(run_analyzer, unit))["CONST 1"] == 1


def test_invalid_zero_root_does_not_hide_valid_public_root(run_analyzer):
    unit = bad.with_code(
        bytes([0x77]) + begin() + const(42) + bytes([0x16, 0xFF]),
        strings=b"f\0",
        pubs=[(0, 1, 0)],
    )
    assert frequencies(check_oracle(run_analyzer, unit))["CONST 42"] == 1
    result = run_analyzer(unit, "--root-zero", expect_success=False)
    assert "does not point to a function entry" in result.stderr


def test_strings_are_rendered_independently_of_raw_table_offsets(run_analyzer):
    unit = bad.with_code(
        begin()
        + instruction(0x11, 5)
        + bytes([0x18])
        + instruction(0x11, 7)
        + bytes([0x18])
        + const(0)
        + bytes([0x16, 0xFF]),
        strings=b"main\0x\0x\0tail",
        pubs=[(0, 0, 0)],
    )
    rows = output_rows(check_oracle(run_analyzer, unit))
    assert rows.count((1, 'STRING "x"')) == 2
    assert rows.count((1, 'STRING "x" ; DROP')) == 2


def test_no_public_roots_produces_no_sequences(run_analyzer):
    unit = bad.with_code(bytes([0x77, 0xFF]))
    for extra in ((), ("--raw-counter",)):
        result = run_analyzer(unit, "--stats", *extra)
        assert result.stdout == ""
        stats = statistics(result.stderr)
        assert stats["reachable instructions"] == 0
        assert stats["sorting runs/merges"] == 0
        assert stats["temporary bytes written"] == 0


def test_external_merging_preserves_exact_output(run_analyzer):
    unit = public_main(
        begin() + b"".join(const(value) + bytes([0x18]) for value in range(30000)) + const(0) + bytes([0x16, 0xFF])
    )
    for extra in ((), ("--raw-counter",)):
        result = run_analyzer(unit, "--memory-limit-mib", "1", "--stats", *extra)
        assert result.stdout == expected_output(unit)
        assert len(output_rows(result.stdout)) == 90005
        assert statistics(result.stderr)["sorting runs/merges"] > 2


def test_isa_cases_cover_every_countable_opcode():
    assert {opcode for _, opcode, _ in CASES} == set(NAMES) - {0xFF}


@pytest.mark.parametrize(("name", "opcode", "unit"), CASES, ids=[case[0] for case in CASES])
def test_isa_conformance(run_analyzer, name, opcode, unit):
    output = check_oracle(run_analyzer, unit)
    unary = [sequence for _, sequence in output_rows(output) if " ; " not in sequence]
    assert name in unary or any(row.startswith(name + " ") for row in unary)
    assert opcode in NAMES

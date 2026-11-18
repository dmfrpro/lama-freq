import pytest

import make_bad_bc as bad

pytestmark = pytest.mark.malformed

ACCEPTED_FOR_STATIC_ANALYSIS = {
    "missing_eof_opcode",
    "undefined_external_function",
    "undefined_external_global",
    "missing_import",
    "division_by_zero",
    "modulo_by_zero",
}

DIAGNOSTICS = {
    "bad_magic": "bad magic",
    "bad_version": "unsupported bytecode version",
    "unknown_opcode": "unknown opcode",
    "truncated_operand": "truncated instruction",
    "string_after_last_nul": "not NUL-terminated",
    "jump_into_operand": "not an instruction boundary",
    "forward_jump_into_operand": "instruction overlaps another instruction",
    "backward_jump_into_operand": "not an instruction boundary",
    "call_target_not_begin": "does not point to a function entry",
    "closure_capture_count_mismatch": "does not match target capture count",
    "public_function_not_begin": "does not point to a function entry",
    "binop_stack_underflow": "stack underflow",
    "drop_stack_underflow": "stack underflow",
    "swap_stack_underflow": "stack underflow",
    "dup_stack_underflow": "stack underflow",
    "end_stack_underflow": "requires stack depth 1",
    "end_extra_operands": "requires stack depth 1",
    "jump_to_current_begin": "points to a function entry",
    "cjump_to_current_begin": "points to a function entry",
    "jump_into_skipped_function_body": "outside function body",
    "eof_inside_function": "inside a function body",
    "forward_stack_mismatch": "stack depth mismatch",
    "backward_stack_mismatch": "stack depth mismatch",
}


@pytest.mark.parametrize("name", list(bad.CASES))
def test_malformed_input(run_analyzer, name):
    result = run_analyzer(bad.CASES[name](), root_zero=True, expect_success=None)
    if name in ACCEPTED_FOR_STATIC_ANALYSIS:
        assert result.returncode == 0
        return
    assert result.returncode != 0, "analyzer accepted malformed input"
    assert 0 < result.returncode < 128, f"analyzer crashed with status {result.returncode}"
    assert result.stderr.strip(), "analyzer rejected input without a diagnostic"
    if name in DIAGNOSTICS:
        assert DIAGNOSTICS[name] in result.stderr

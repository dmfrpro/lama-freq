from collections import Counter

from oracle import expected_output


def output_rows(output):
    rows = []
    previous = None
    for line in output.splitlines():
        count, separator, sequence = line.partition("\t")
        assert separator, f"malformed output row: {line!r}"
        count = int(count)
        assert count > 0, f"non-positive frequency was rendered: {line!r}"
        if previous is not None:
            assert previous >= count, "frequencies are not sorted in descending order"
        previous = count
        rows.append((count, sequence))
    return rows


def frequencies(output):
    result = Counter()
    for count, sequence in output_rows(output):
        assert sequence not in result, f"duplicate rendered sequence: {sequence!r}"
        result[sequence] = count
    return result


def check_oracle(run, data, *arguments, root_zero=False):
    expected = expected_output(data, root_zero)
    output = None
    for extra in ((), ("--raw-counter",)):
        result = run(data, *arguments, *extra, root_zero=root_zero)
        output = result.stdout
        assert output == expected
    return output


def statistics(output):
    result = {}
    for line in output.splitlines():
        name, separator, value = line.partition(": ")
        if separator:
            number = value.split(maxsplit=1)[0]
            result[name] = int(number) if number.isdigit() else value
    return result

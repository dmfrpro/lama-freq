import std.sys as sys

from analysis import Analyzer
from argmojo import Argument, Command, ParseResult
from frequency import AnalysisResult, CounterOptions, render_result
from lama import LamaBackend

comptime MIB = 1024 * 1024


def usage_line(program: String) -> String:
    return (
        program
        + " [--root-zero] [--raw-counter] [--stats]\n"
        + "          [--memory-limit-mib N] [--temp-dir DIR] file.bc"
    )


def add_root_arguments(mut app: Command) raises:
    app.add_argument(
        Argument("root-zero", help="Also use bytecode offset zero as a root")
        .long["root-zero"]()
        .flag()
    )
    app.add_argument(
        Argument("public-only", help="Use only public function roots")
        .long["public-only"]()
        .flag()
    )


def add_counter_arguments(mut app: Command) raises:
    app.add_argument(
        Argument("raw-counter", help="Use the bounded raw-key counter")
        .long["raw-counter"]()
        .flag()
    )
    app.add_argument(
        Argument("stats", help="Print analyzer statistics to stderr")
        .long["stats"]()
        .flag()
    )
    app.add_argument(
        Argument("memory-limit-mib", help="In-memory counter budget in MiB")
        .long["memory-limit-mib"]()
        .value_name["N"]()
        .allow_hyphen_values()
        .range[1, 4096]()
        .default["1024"]()
    )
    app.add_argument(
        Argument("temp-dir", help="Directory for external sorting runs")
        .long["temp-dir"]()
        .value_name["DIR"]()
        .allow_hyphen_values()
        .default["/tmp"]()
    )


def make_command(program: String) raises -> Command:
    var app = Command(
        program, "Analyze reachable Lama bytecode instruction frequencies"
    )
    app.usage(usage_line(program))
    app.disable_default_completions()
    app.add_argument(
        Argument("input", help="Lama bytecode file").positional().required()
    )
    add_root_arguments(app)
    add_counter_arguments(app)
    return app^


def resolve_root_zero(arguments: List[String]) -> Bool:
    var root_zero = False
    var index = 1

    while index < len(arguments):
        var argument = arguments[index]

        if argument == "--":
            break

        if argument == "--root-zero":
            root_zero = True
        elif argument == "--public-only":
            root_zero = False
        elif argument == "--memory-limit-mib" or argument == "--temp-dir":
            index += 1

        index += 1

    return root_zero


def copy_arguments() -> List[String]:
    var raw = sys.argv()
    var arguments = List[String](capacity=len(raw))

    for argument in raw:
        arguments.append(String(argument))

    return arguments^


def counter_options(parsed: ParseResult) raises -> CounterOptions:
    return CounterOptions(
        parsed.get_int("memory-limit-mib") * MIB,
        parsed.get_string("temp-dir"),
        parsed.get_flag("raw-counter"),
    )


def print_statistics(result: AnalysisResult):
    print(
        t"reachable instructions: {result.stats.reachable_instructions}",
        file=sys.stderr,
    )
    print(t"jump labels: {result.stats.jump_labels}", file=sys.stderr)
    print(
        t"bigram occurrences: {result.stats.bigram_occurrences}",
        file=sys.stderr,
    )
    print(
        t"sorting runs/merges: {result.external.stats.spills}", file=sys.stderr
    )
    print(
        t"largest sorting run set: {result.external.stats.maximum_runs}",
        file=sys.stderr,
    )
    print(
        t"sorting merge rounds: {result.external.stats.merge_rounds}",
        file=sys.stderr,
    )
    print(
        t"raw-key fallback: {'yes' if result.raw_mode else 'no'}",
        file=sys.stderr,
    )
    print(
        t"temporary bytes written: {result.external.stats.temporary_bytes}",
        file=sys.stderr,
    )


def analyze_arguments(arguments: List[String], parsed: ParseResult) raises:
    var root_zero = resolve_root_zero(arguments)
    var backend = LamaBackend(parsed.get_string("input"))
    var roots = backend.roots(root_zero)
    var analyzer = Analyzer(backend^, roots, counter_options(parsed))

    analyzer.run()
    render_result(analyzer.backend, analyzer.result)

    if parsed.get_flag("stats"):
        print_statistics(analyzer.result)


def run() raises:
    var arguments = copy_arguments()
    var program = arguments[0] if len(arguments) != 0 else "lama-freq"

    if len(arguments) == 1:
        print("Syntax: " + usage_line(program), file=sys.stderr)
        sys.exit(1)

    var app = make_command(program)
    var parsed = app.parse_arguments(arguments)

    analyze_arguments(arguments, parsed)


def main():
    try:
        run()
    except error:
        print(String(error), file=sys.stderr)
        sys.exit(1)

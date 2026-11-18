def show_section [section, width] {
    print $"\n($section.title)"
    print ($section.results | table --width $width)

    let diagnostics = $section | get -o diagnostics | default []
    if ($diagnostics | length) > 0 {
        print "\nDiagnostics"
        print ($diagnostics | table --width $width)
    }

    let analysis = $section | get -o analysis | default []
    if ($analysis | length) > 0 {
        print "\nAnalyzer statistics"
        print ($analysis | table --width $width)
    }

    let performance = $section | get -o performance | default []
    if ($performance | length) > 0 {
        print "\nProcess resources"
        print ($performance | table --width $width)
    }
}

def main [] {
    let report = $in | from json
    let requested_width = $env.TABLE_WIDTH? | default $env.COLUMNS? | default 140 | into int
    let width = if $requested_width > 0 { $requested_width } else { 140 }

    for section in $report.sections {
        show_section $section $width
    }

    let summary = $report | get -o summary
    if $summary != null {
        print "\nSummary"
        print ($summary | table --width $width)
    }
}

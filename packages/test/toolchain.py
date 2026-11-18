from pathlib import Path
import shutil
import subprocess


def compile_lama(source: Path, destination: Path, environment):
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / source.name
    shutil.copyfile(source, target)
    result = subprocess.run(
        [
            environment["LAMAC"],
            "-I",
            str(Path(environment["LAMA_DIR"]) / "runtime"),
            "-I",
            str(Path(environment["LAMA_DIR"]) / "stdlib/x64"),
            "-b",
            source.name,
        ],
        cwd=destination,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return result, target.with_suffix(".bc")

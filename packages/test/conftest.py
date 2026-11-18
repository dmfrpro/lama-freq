import os
import resource
import subprocess

import pytest


@pytest.fixture(scope="session")
def analyzer():
    executable = os.environ.get("ANALYZER") or shutil.which("lama-freq")
    if not executable:
        pytest.fail("set ANALYZER or put lama-freq on PATH")
    return executable


@pytest.fixture
def run_analyzer(analyzer, tmp_path):
    serial = 0

    def run(data, *arguments, root_zero=False, expect_success=True, timeout=120):
        nonlocal serial
        serial += 1
        path = tmp_path / f"input-{serial}.bc"
        path.write_bytes(data)
        (tmp_path / "runs").mkdir(exist_ok=True)
        command = [analyzer, "--temp-dir", str(tmp_path / "runs")]
        if root_zero:
            command.append("--root-zero")
        command.extend((*arguments, str(path)))
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        if expect_success is True:
            assert result.returncode == 0, f"analyzer failed: {result.stderr}"
        elif expect_success is False:
            assert result.returncode != 0, "analyzer accepted malformed input"
            assert 0 < result.returncode < 128, f"analyzer crashed with status {result.returncode}"
            assert result.stderr.strip(), "analyzer rejected input without a diagnostic"
        return result

    return run


@pytest.fixture
def run_file_analyzer(analyzer, tmp_path):
    serial = 0

    def run(path, *arguments, timeout=300):
        nonlocal serial
        serial += 1
        (tmp_path / "runs").mkdir(exist_ok=True)
        output = tmp_path / f"output-{serial}.txt"
        with output.open("w") as stdout:
            result = subprocess.run(
                [analyzer, "--temp-dir", str(tmp_path / "runs"), *arguments, str(path)],
                stdout=stdout,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
        assert result.returncode == 0, f"analyzer failed: {result.stderr}"
        peak_rss_kib = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        assert peak_rss_kib < 32 * 1024 * 1024, "analyzer reached the 32-GiB test limit"
        return result, output

    return run


@pytest.fixture(scope="session")
def lama_environment():
    missing = [name for name in ("LAMAC", "LAMA_DIR", "LAMA_SRC", "LAMAVM") if not os.environ.get(name)]
    if missing:
        pytest.skip("Lama toolchain is unavailable: " + ", ".join(missing))
    return {name: os.environ[name] for name in ("LAMAC", "LAMA_DIR", "LAMA_SRC", "LAMAVM")}

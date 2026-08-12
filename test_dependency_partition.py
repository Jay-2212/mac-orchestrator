"""Verify the public core/indexer dependency boundary."""

import ast
from pathlib import Path
import re

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 compatibility for this standalone test.
    tomllib = None


PYPROJECT = Path(__file__).with_name("pyproject.toml")

EXPECTED_CORE = {
    "mcp",
    "fastapi",
    "uvicorn",
    "pyautogui",
    "pyobjc-framework-quartz",
    "pyobjc-framework-cocoa",
    "pyobjc-framework-applicationservices",
    "easyocr",
    "numpy",
    "rich",
    "requests",
}

EXPECTED_INDEXER = {
    "pyngrok",
    "pypdf",
    "python-docx",
    "openpyxl",
    "python-pptx",
    "sentence-transformers",
}


def dependency_name(requirement: str) -> str:
    return requirement.split(">=", 1)[0].split("==", 1)[0].strip().lower()


def project_metadata() -> dict:
    text = PYPROJECT.read_text(encoding="utf-8")
    if tomllib is not None:
        return tomllib.loads(text)["project"]

    def array(section: str, key: str) -> list[str]:
        section_header = f"[{section}]"
        if section_header not in text:
            return []
        section_start = text.index(section_header)
        section_text = text[section_start:]
        match = re.search(rf"(?m)^{re.escape(key)}\s*=\s*\[", section_text)
        if match is None:
            return []
        values = []
        for line in section_text[match.end() :].splitlines():
            if line.strip() == "]":
                break
            item = line.split("#", 1)[0].strip().rstrip(",")
            if item:
                values.append(ast.literal_eval(item))
        return values

    return {
        "dependencies": array("project", "dependencies"),
        "optional-dependencies": {
            "indexer": array("project.optional-dependencies", "indexer")
        },
    }


def test_dependency_partition() -> None:
    project = project_metadata()
    core = {dependency_name(item) for item in project["dependencies"]}
    indexer = {
        dependency_name(item)
        for item in project.get("optional-dependencies", {}).get("indexer", [])
    }

    assert core == EXPECTED_CORE
    assert indexer == EXPECTED_INDEXER
    assert "pyngrok" not in core
    assert "fastapi>=0.115.0" in project["dependencies"]
    assert "uvicorn>=0.30.0" in project["dependencies"]
    assert "easyocr>=1.7.0" in project["dependencies"]


if __name__ == "__main__":
    test_dependency_partition()
    print("dependency partition: PASS")

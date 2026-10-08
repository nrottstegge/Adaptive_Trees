#!/usr/bin/env python3
"""Make legacy test fixture paths portable in the disposable source clones."""
import re
import sys
from pathlib import Path


def prepare(root):
    for name in ("octree_test.cu", "octree_regression_test.cu"):
        path = root / "tests" / name
        if not path.exists():
            continue
        text = path.read_text()
        text, count = re.subn(
            r'"/[^"\n]+/tests/test_data/input\.dat"',
            '(std::filesystem::path(__FILE__).parent_path() / "test_data/input.dat").string()',
            text,
        )
        text, reference_count = re.subn(
            r'"/[^"\n]+/tests/verification_data"',
            'std::filesystem::path(__FILE__).parent_path() / "verification_data"',
            text,
        )
        if count + reference_count:
            if "#include <filesystem>" not in text:
                text = "#include <filesystem>\n" + text
            path.write_text(text)
            print(f"Portable test paths: {root.name}/tests/{name}")


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))

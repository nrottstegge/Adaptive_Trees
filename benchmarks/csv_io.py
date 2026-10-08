#!/usr/bin/env python3
"""Read plain/gzip CSVs; run this file to losslessly pack results of at least 1 MiB."""
import gzip
import hashlib
import shutil
import sys
from pathlib import Path

LARGE_CSV = 1024 * 1024
BENCH = Path(__file__).resolve().parent


def csv_path(path):
    path = Path(path)
    return path if path.exists() else Path(str(path) + ".gz")


def read_csv(path, **kwargs):
    import pandas as pd

    return pd.read_csv(csv_path(path), **kwargs)


def csv_files(directory, pattern):
    """Find plain and compressed samples, preferring plain files if both exist."""
    files = {str(p): p for p in Path(directory).glob(pattern + ".gz")}
    files = {name.removesuffix(".gz"): p for name, p in files.items()}
    files.update({str(p): p for p in Path(directory).glob(pattern)})
    return [files[name] for name in sorted(files)]


def compress_csv(path):
    path = Path(path)
    if path.stat().st_size < LARGE_CSV:
        return False
    target = Path(str(path) + ".gz")
    temporary = target.with_suffix(".gz.tmp")
    try:
        with path.open("rb") as source, temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as dest:
                shutil.copyfileobj(source, dest)
        with path.open("rb") as source, gzip.open(temporary, "rb") as packed:
            if hashlib.file_digest(source, "sha256").digest() != hashlib.file_digest(packed, "sha256").digest():
                raise RuntimeError(f"compression verification failed: {path}")
        temporary.replace(target)
        path.unlink()
    finally:
        temporary.unlink(missing_ok=True)
    return True


def write_csv(frame, path, **kwargs):
    """Keep fresh results compact too; replace an older compressed copy safely."""
    path = Path(path)
    frame.to_csv(path, **kwargs)
    if not compress_csv(path):
        Path(str(path) + ".gz").unlink(missing_ok=True)


if __name__ == "__main__":
    roots = [BENCH / p for p in sys.argv[1:]] or [BENCH / d for d in ("data", "env", "logs")]
    count = 0
    for root in roots:
        for path in sorted(root.rglob("*.csv")):
            count += compress_csv(path)
    print(f"Compressed {count} large CSVs; decompressed SHA-256 verified for each file.")

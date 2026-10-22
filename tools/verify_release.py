"""Read-only source/ZIP integrity check; does not install or run PowerShell."""
import hashlib
from pathlib import Path, PurePosixPath
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.7"
ZIP = ROOT / "dist" / f"bam-portable-v{VERSION}.zip"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_payload(files):
    manifest = files["MANIFEST.sha256"].decode("utf-8-sig")
    expected = {}
    for line in manifest.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?(.+)", line)
        if not match:
            raise ValueError("Invalid manifest line")
        name = match[2].replace("\\", "/")
        if name in expected:
            raise ValueError("Duplicate manifest path")
        expected[name] = match[1].lower()
    if set(expected) != set(files) - {"MANIFEST.sha256"}:
        raise ValueError("Manifest/file set mismatch")
    for name, sha in expected.items():
        if digest(files[name]) != sha:
            raise ValueError(f"Payload hash mismatch: {name}")
    return len(expected)


def main():
    sidecar = ZIP.with_suffix(".zip.sha256").read_text(encoding="utf-8-sig").split()[0].lower()
    if digest(ZIP.read_bytes()) != sidecar:
        raise ValueError("ZIP sidecar mismatch")
    with zipfile.ZipFile(ZIP) as archive:
        files = {}
        for item in archive.infolist():
            if item.is_dir():
                continue
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or path.parts[0] != "bam-portable":
                raise ValueError("Unsafe ZIP path")
            name = "/".join(path.parts[1:])
            if name in files:
                raise ValueError("Duplicate ZIP path")
            files[name] = archive.read(item)
    count = validate_payload(files)
    source = {p.relative_to(ROOT / "package").as_posix(): p.read_bytes()
              for p in (ROOT / "package").rglob("*") if p.is_file()}
    if source != files:
        raise ValueError("Source/ZIP byte mismatch")
    print(f"PASS: ZIP checksum; {count} manifest entries; {len(files)} source/ZIP files byte-identical")
    print("NOT TESTED: runtime, installation, Skill selection, target LLM behavior")


if __name__ == "__main__":
    main()

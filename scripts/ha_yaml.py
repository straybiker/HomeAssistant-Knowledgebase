#!/usr/bin/env python3
"""Canonical YAML formatting + semantic diff for ha_control.ps1.

Provides ONE canonical formatting, shared by -Diff, -Pull and -Deploy, so config
files never churn between the local repo and the Home Assistant server no matter
where they were edited (local IDE, the Studio Code Server add-on, or the HA web
UI's automation/script editor, which re-serializes whole files).

It uses ruamel.yaml in round-trip mode, which preserves comments, key order,
custom !tags (!secret, !include, ...) and block-scalar styles (the folded EMHASS
payload stays folded), while normalizing the things that actually churn: quote
style (' vs ") and sequence indentation.

Usage:
    python ha_yaml.py format <file> [<file> ...]   # rewrite in place if changed
    python ha_yaml.py diff   <local> <remote> [name]

format exit codes:
    0  done (individual files reported as formatted/unchanged)
    1  one or more files could not be parsed (left untouched)
diff exit codes:
    0  semantically identical
    1  differ (a unified diff of the canonical form is printed)
    2  could not parse; caller should fall back to a raw text diff
"""
import sys
import io
import difflib

try:
    from ruamel.yaml import YAML
except ImportError:
    sys.stderr.write("ruamel.yaml not installed (pip install ruamel.yaml)\n")
    sys.exit(2)


def _make_yaml():
    y = YAML()  # round-trip mode: keeps comments, key order, tags, block scalars
    # Home Assistant parses YAML 1.1 (PyYAML). Pin ruamel to 1.1 so its quoting
    # decisions match HA: values like '23:05' (sexagesimal int) or 'on'/'no'
    # (booleans) under 1.1 stay quoted, instead of being silently un-quoted (as
    # 1.2 would) and then re-interpreted by HA as 1385 / True.
    y.version = (1, 1)
    y.preserve_quotes = False  # normalize the ' vs " churn to one style
    y.width = 4096  # don't hard-wrap long scalars
    y.indent(mapping=2, sequence=4, offset=2)  # indented sequences (HA UI style)
    return y


def format_text(text):
    """Return the canonical formatting of a YAML document string.

    Empty or comment-only documents parse as None; return them unchanged so we
    never turn an empty file into the literal "null"."""
    yaml = _make_yaml()
    data = yaml.load(text)
    if data is None:
        return text
    buf = io.StringIO()
    yaml.dump(data, buf)
    out = buf.getvalue()
    # Pinning the version makes ruamel emit a "%YAML 1.1\n---\n" directive. HA
    # config files don't use document markers, so strip it for clean output.
    if out.startswith("%YAML"):
        parts = out.split("\n", 2)
        if len(parts) == 3 and parts[1].strip() == "---":
            out = parts[2]
    return out


def cmd_format(paths):
    rc = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                original = f.read()
            formatted = format_text(original)
        except Exception as exc:  # noqa: BLE001 - leave anything unparseable alone
            sys.stderr.write(f"skip (parse failed): {path}: {exc}\n")
            rc = 1
            continue
        if formatted != original:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(formatted)
            print(f"formatted: {path}")
        else:
            print(f"unchanged: {path}")
    return rc


def cmd_diff(local_path, remote_path, name):
    try:
        with open(local_path, encoding="utf-8") as f:
            local = format_text(f.read())
        with open(remote_path, encoding="utf-8") as f:
            remote = format_text(f.read())
    except Exception as exc:  # noqa: BLE001 - signal caller to use raw fallback
        sys.stderr.write(f"parse failed for {name}: {exc}\n")
        return 2

    if local == remote:
        return 0

    diff = difflib.unified_diff(
        local.splitlines(keepends=True),
        remote.splitlines(keepends=True),
        fromfile=f"{name} (local)",
        tofile=f"{name} (HA)",
    )
    sys.stdout.writelines(diff)
    return 1


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: ha_yaml.py format <file>... | diff <local> <remote> [name]\n"
        )
        return 2

    mode = argv[1]
    if mode == "format":
        if len(argv) < 3:
            sys.stderr.write("usage: ha_yaml.py format <file>...\n")
            return 2
        return cmd_format(argv[2:])
    if mode == "diff":
        if len(argv) < 4:
            sys.stderr.write("usage: ha_yaml.py diff <local> <remote> [name]\n")
            return 2
        name = argv[4] if len(argv) > 4 else argv[2]
        return cmd_diff(argv[2], argv[3], name)

    sys.stderr.write(f"unknown mode: {mode}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

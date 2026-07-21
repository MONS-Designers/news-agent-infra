import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_sources import DEFAULT_PATH, validate  # noqa: E402

SCRIPT_PATH = Path(__file__).resolve().parent / "validate_sources.py"


def load(yaml_text):
    return yaml.safe_load(yaml_text)


def test_happy_path():
    data = load(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            category: tech
            language: en
          - name: Source B
            url: https://b.example.com/rss.xml
            category: world_news
            language: en
        """
    )
    assert validate(data) == []


def test_real_default_sources_file_is_valid():
    with DEFAULT_PATH.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    errors = validate(data)
    assert errors == []
    assert len(data["sources"]) == 10


def test_missing_field():
    data = load(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "category" in errors[0]


def test_malformed_url():
    data = load(
        """
        sources:
          - name: Source A
            url: not-a-url
            category: tech
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "invalid url" in errors[0]


def test_unknown_category():
    data = load(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            category: sports
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "unknown category" in errors[0]


def test_duplicate_url():
    data = load(
        """
        sources:
          - name: Source A
            url: https://dup.example.com/rss.xml
            category: tech
            language: en
          - name: Source B
            url: https://dup.example.com/rss.xml
            category: science
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "duplicate url" in errors[0]


def test_duplicate_name():
    data = load(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            category: tech
            language: en
          - name: Source A
            url: https://b.example.com/rss.xml
            category: science
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "duplicate name" in errors[0]


def test_duplicate_detection_ignores_surrounding_whitespace():
    data = load(
        """
        sources:
          - name: " Source A "
            url: "https://dup.example.com/rss.xml"
            category: tech
            language: en
          - name: Source B
            url: "https://dup.example.com/rss.xml "
            category: science
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 1
    assert "duplicate url" in errors[0]


def test_category_with_surrounding_whitespace_is_accepted():
    data = load(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            category: " tech "
            language: en
        """
    )
    assert validate(data) == []


def test_empty_sources_list_is_rejected():
    data = load("sources: []")
    errors = validate(data)
    assert len(errors) == 1
    assert "at least one entry" in errors[0]


def test_multiple_simultaneous_errors_are_all_collected():
    data = load(
        """
        sources:
          - name: Source A
            url: not-a-url
            category: sports
            language: en
          - name: Source A
            url: https://a.example.com/rss.xml
            category: tech
            language: en
        """
    )
    errors = validate(data)
    assert len(errors) == 3
    assert any("invalid url" in e for e in errors)
    assert any("unknown category" in e for e in errors)
    assert any("duplicate name" in e for e in errors)


def test_cli_exits_zero_on_valid_file():
    result = subprocess.run(
        [sys.executable, str(SCRIPT_PATH), str(DEFAULT_PATH)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert "OK: 10 sources validated" in result.stdout


def test_cli_exits_nonzero_on_invalid_file(tmp_path):
    bad_file = tmp_path / "bad_sources.yaml"
    bad_file.write_text(
        """
        sources:
          - name: Source A
            url: https://a.example.com/rss.xml
            category: tech
        """
    )
    result = subprocess.run(
        [sys.executable, str(SCRIPT_PATH), str(bad_file)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "language" in result.stderr


def test_cli_exits_nonzero_on_missing_file(tmp_path):
    missing = tmp_path / "does_not_exist.yaml"
    result = subprocess.run(
        [sys.executable, str(SCRIPT_PATH), str(missing)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "ERROR" in result.stderr

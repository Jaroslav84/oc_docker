"""Unit tests for src/builder-api/config.py — the daemon boot-time config loader."""
import pytest

import config


def test_load_minimal_returns_valid_config(fixture_config_path):
    """A well-formed TOML with a [project.testproj] block loads cleanly."""
    cfg = config.load("testproj", config_path=fixture_config_path)
    assert cfg.port == 16666
    # project_root is a Path; compare its string form for portability.
    assert str(cfg.project_root) == "/tmp"


def test_load_missing_project_raises(fixture_config_path):
    """Asking for a project name with no matching block hard-fails.
    ConfigError inherits SystemExit — pytest catches it via SystemExit."""
    with pytest.raises(SystemExit):
        config.load("nonexistent", config_path=fixture_config_path)


def test_load_missing_port_raises(fixture_config_no_port):
    """A block that omits the required `port` field hard-fails."""
    with pytest.raises(SystemExit):
        config.load("foo", config_path=fixture_config_no_port)

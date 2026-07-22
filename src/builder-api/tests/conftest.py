"""Shared pytest fixtures for builder-api unit tests."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make the builder-api modules importable from the test files without
# requiring the whole repo on PYTHONPATH.
_BUILDER_API = Path(__file__).resolve().parent.parent
if str(_BUILDER_API) not in sys.path:
    sys.path.insert(0, str(_BUILDER_API))


MINIMAL_TOML = """\
[defaults]
password = "test-p4ss"

[project.testproj]
port = 16666
root = "/tmp"
languages = []
"""


@pytest.fixture
def fixture_config_path(tmp_path):
    """A minimal builder-api.toml with one valid [project.testproj] block."""
    p = tmp_path / "builder-api.toml"
    p.write_text(MINIMAL_TOML)
    return p


@pytest.fixture
def fixture_config_no_port(tmp_path):
    """A TOML with a [project.foo] block missing the required `port` field."""
    p = tmp_path / "builder-api.toml"
    p.write_text(
        "[defaults]\npassword = \"x\"\n\n"
        "[project.foo]\nroot = \"/tmp\"\nlanguages = []\n"
    )
    return p

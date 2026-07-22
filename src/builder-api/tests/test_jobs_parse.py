"""Unit tests for src/builder-api/jobs_parse.py — TOML → Job model parser."""
import pytest

import jobs_parse
from jobs_errors import JobConfigError


def test_parse_jobs_rejects_non_table():
    """[jobs] must be a table (dict). Passing a list should raise."""
    with pytest.raises(JobConfigError):
        jobs_parse.parse_jobs(["not", "a", "table"], file_label="test.toml")


def test_parse_jobs_empty_dict_returns_empty():
    """An empty [jobs] table parses to an empty dict — not an error."""
    result = jobs_parse.parse_jobs({}, file_label="test.toml")
    assert result == {}

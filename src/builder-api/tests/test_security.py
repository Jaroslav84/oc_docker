"""Unit tests for src/builder-api/security.py helpers (no server boot)."""
import security


def test_constant_time_eq_matching_strings():
    assert security._constant_time_eq("abc123", "abc123") is True


def test_constant_time_eq_mismatched_strings():
    assert security._constant_time_eq("abc", "abd") is False


def test_constant_time_eq_length_mismatch():
    assert security._constant_time_eq("abc", "abcd") is False


def test_constant_time_eq_empty_strings():
    assert security._constant_time_eq("", "") is True

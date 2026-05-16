"""Tests for :mod:`app.ai.signals.diversity`.

Pure-Python module — no DB, no async, no fixtures beyond constructing UUIDs.
Should run cleanly with ``pytest backend/tests/ai/test_diversity.py -v``.
"""

from __future__ import annotations

from uuid import UUID, uuid4

import pytest

from app.ai.signals.diversity import DiversityConfig, apply_author_diversity


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _uuid(seed: int) -> UUID:
    """Deterministic UUID factory — easier to read in failure diffs than uuid4."""
    return UUID(int=seed)


# Multipliers for the default config (decay=0.6, floor=0.1):
#   floor + (1 - floor) * decay**index
#   index 0 → 0.1 + 0.9 * 1       = 1.0
#   index 1 → 0.1 + 0.9 * 0.6     = 0.64
#   index 2 → 0.1 + 0.9 * 0.36    = 0.424
#   index 3 → 0.1 + 0.9 * 0.216   = 0.2944
#   index 4 → 0.1 + 0.9 * 0.1296  = 0.21664
_DEFAULT_MULTIPLIERS = [1.0, 0.64, 0.424, 0.2944, 0.21664]


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_empty_list_returns_empty_list() -> None:
    assert apply_author_diversity([]) == []


def test_single_item_unchanged() -> None:
    item_id, author_id = _uuid(1), _uuid(101)
    result = apply_author_diversity([(item_id, 5.0, author_id)])

    assert len(result) == 1
    out_item, out_score, out_author = result[0]
    assert out_item == item_id
    assert out_author == author_id
    # First (and only) appearance → multiplier exactly 1.0.
    assert out_score == pytest.approx(5.0)


def test_input_is_not_mutated() -> None:
    """``apply_author_diversity`` is documented as pure — verify the input
    list and its tuples are untouched."""
    a = _uuid(201)
    original = [
        (_uuid(1), 10.0, a),
        (_uuid(2), 9.0, a),
        (_uuid(3), 8.0, a),
    ]
    snapshot = list(original)

    apply_author_diversity(original)

    assert original == snapshot


# ---------------------------------------------------------------------------
# Core math
# ---------------------------------------------------------------------------


def test_single_author_default_multipliers() -> None:
    """Five items from the same author should be multiplied by the
    well-known default-config series and remain in the same order
    (because the multipliers are monotonically decreasing alongside
    the input scores)."""
    author = _uuid(301)
    inputs = [(_uuid(i), score, author) for i, score in enumerate([10.0, 9.0, 8.0, 7.0, 6.0])]

    result = apply_author_diversity(inputs)

    assert len(result) == 5
    expected_scores = [
        10.0 * _DEFAULT_MULTIPLIERS[0],
        9.0 * _DEFAULT_MULTIPLIERS[1],
        8.0 * _DEFAULT_MULTIPLIERS[2],
        7.0 * _DEFAULT_MULTIPLIERS[3],
        6.0 * _DEFAULT_MULTIPLIERS[4],
    ]
    # Order is preserved here because both scores and multipliers decay
    # together — adjusted scores stay monotonically decreasing.
    for (out_item, out_score, out_author), in_triple, expected in zip(
        result, inputs, expected_scores, strict=True
    ):
        assert out_item == in_triple[0]
        assert out_author == author
        assert out_score == pytest.approx(expected)


def test_two_authors_interleaved_first_appearance_keeps_full_score() -> None:
    """Each author's *first* appearance should keep multiplier 1.0
    regardless of where it lands in the input."""
    a, b = _uuid(401), _uuid(402)
    inputs = [
        (_uuid(1), 10.0, a),  # a #0 → ×1.0
        (_uuid(2), 9.0, b),   # b #0 → ×1.0
        (_uuid(3), 8.0, a),   # a #1 → ×0.64
        (_uuid(4), 7.0, b),   # b #1 → ×0.64
    ]

    result = apply_author_diversity(inputs)

    by_id = {item_id: (score, author) for item_id, score, author in result}
    assert by_id[_uuid(1)][0] == pytest.approx(10.0)        # a #0
    assert by_id[_uuid(2)][0] == pytest.approx(9.0)         # b #0
    assert by_id[_uuid(3)][0] == pytest.approx(8.0 * 0.64)  # a #1 → 5.12
    assert by_id[_uuid(4)][0] == pytest.approx(7.0 * 0.64)  # b #1 → 4.48


def test_result_is_sorted_by_adjusted_score() -> None:
    """The classic case: a repeat-author item that was originally #2
    should slide below a fresh-author item that was originally #3."""
    a, b = _uuid(501), _uuid(502)
    inputs = [
        (_uuid(1), 10.0, a),  # a #0 → 10.0
        (_uuid(2), 9.0, a),   # a #1 → 9.0 * 0.64 = 5.76
        (_uuid(3), 7.0, b),   # b #0 → 7.0  (now beats the demoted a #1)
    ]

    result = apply_author_diversity(inputs)
    scores_in_order = [score for _, score, _ in result]

    # Scores must come out in descending order ...
    assert scores_in_order == sorted(scores_in_order, reverse=True)
    # ... and specifically: a#0 (10.0) > b#0 (7.0) > a#1 (5.76).
    assert [item for item, _, _ in result] == [_uuid(1), _uuid(3), _uuid(2)]
    assert scores_in_order[0] == pytest.approx(10.0)
    assert scores_in_order[1] == pytest.approx(7.0)
    assert scores_in_order[2] == pytest.approx(9.0 * 0.64)


# ---------------------------------------------------------------------------
# Floor behaviour
# ---------------------------------------------------------------------------


def test_floor_honored_for_long_same_author_run() -> None:
    """100 items all from the same author: ``decay**99`` is effectively
    zero so the smallest adjusted score must equal
    ``lowest_input_score * floor`` to within floating-point tolerance."""
    author = _uuid(601)
    n = 100
    # Use a constant input score so the floor check is unambiguous —
    # otherwise the lowest input would also be affected by its position.
    inputs = [(_uuid(i), 5.0, author) for i in range(n)]

    config = DiversityConfig()  # floor=0.1
    result = apply_author_diversity(inputs, config)
    min_score = min(score for _, score, _ in result)

    # 5.0 * (0.1 + 0.9 * 0.6**99); the 0.6**99 term is ≈ 1.7e-22, so the
    # adjusted score should converge to floor * input within machine epsilon.
    assert min_score == pytest.approx(5.0 * config.floor, rel=1e-9, abs=1e-9)
    assert min_score > 0.0  # floor strictly above zero by construction


# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_decay", [-0.1, 0.0, 1.0, 1.5])
def test_invalid_decay_raises(bad_decay: float) -> None:
    with pytest.raises(ValueError, match="decay"):
        DiversityConfig(decay=bad_decay)


@pytest.mark.parametrize("bad_floor", [-0.01, 1.0, 1.5])
def test_invalid_floor_raises(bad_floor: float) -> None:
    with pytest.raises(ValueError, match="floor"):
        DiversityConfig(floor=bad_floor)


def test_floor_zero_is_allowed() -> None:
    """``floor = 0`` means "fully silence repeat authors after enough
    appearances" — explicitly inside the closed-open interval ``[0, 1)``."""
    cfg = DiversityConfig(floor=0.0)
    assert cfg.floor == 0.0

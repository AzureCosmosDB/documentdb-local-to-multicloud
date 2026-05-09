"""Query examples used for the DocumentDB demo.

This script connects to the local DocumentDB (Mongo API) instance and provides
an interactive, presenter-friendly menu for demonstrating:

- Common query patterns (find, projection, operator predicates, aggregation)
- How indexes can change query plans (COLLSCAN → IXSCAN)
- Before/after elapsed time for the same query with and without an index

For the "index tuning" demos (menu items 2–6), the script:

- Resets the collection to a known state by dropping all non-``_id`` indexes
- Shows an ``explain()`` summary and a timing baseline
- Creates an index appropriate for that specific query pattern
- Shows the new ``explain()`` summary and timing
- Tracks results so it can print a final before/after timing comparison

Usage:

    # Interactive (menu) mode
    python ./scripts/query_examples.py

    # Run everything end-to-end (non-interactive)
    python ./scripts/query_examples.py --mode all --repeats 30 --warmup 5

Notes:

- This script is intended for live demos; it intentionally mutates indexes in
    ``foodservice.restaurants``.
- DocumentDB Local may return only a query plan (planner) for ``explain()`` and
    omit execution metrics like ``nReturned`` / ``totalDocsExamined``.
- If your dataset is small or not skewed toward the demo filter, the timing
    difference may be less dramatic.
"""

import argparse
import pprint
import random
import sys
import time
from collections.abc import Callable
from typing import Any

from pymongo import MongoClient


def _pick_rare_cuisine(restaurants: Any) -> tuple[str, int] | None:
    """Pick a cuisine value with the fewest documents.

    The goal is to make the impact of adding an index on ``cuisine`` as clear
    as possible: a selective predicate forces a COLLSCAN to read the entire
    collection, while an IXSCAN can jump directly to a small set of matches.
    """
    pipeline = [
        {"$group": {"_id": "$cuisine", "count": {"$sum": 1}}},
        {"$sort": {"count": 1}},
        {"$limit": 1},
    ]
    try:
        rows = list(restaurants.aggregate(pipeline))
    except Exception:  # noqa: BLE001
        return None

    if not rows:
        return None

    cuisine = rows[0].get("_id")
    count = rows[0].get("count")
    if not isinstance(cuisine, str) or not cuisine:
        return None
    if not isinstance(count, int):
        try:
            count = int(count)
        except Exception:  # noqa: BLE001
            count = 0
    return cuisine, count


def _pick_rare_tag(restaurants: Any) -> tuple[str, int] | None:
    """Pick a tag value with the fewest documents.

    Tags are an array field; indexing them creates a multikey index. We use a
    rare tag so the before/after difference is easy to observe.
    """
    pipeline = [
        {"$unwind": "$tags"},
        {"$group": {"_id": "$tags", "count": {"$sum": 1}}},
        {"$sort": {"count": 1}},
        {"$limit": 1},
    ]
    try:
        rows = list(restaurants.aggregate(pipeline))
    except Exception:  # noqa: BLE001
        return None

    if not rows:
        return None

    tag = rows[0].get("_id")
    count = rows[0].get("count")
    if not isinstance(tag, str) or not tag:
        return None
    if not isinstance(count, int):
        try:
            count = int(count)
        except Exception:  # noqa: BLE001
            count = 0
    return tag, count


def _pick_good_tags_all_pair(restaurants: Any) -> tuple[str, str, int] | None:
    """Pick a reasonably selective tags $all pair for a multikey demo.

    We want a query that is selective enough to show a clear win with an index,
    but not so selective that it returns ~0 results and becomes noisy.

    This uses a small, deterministic random sample of tag pairs.
    """
    try:
        tags = restaurants.distinct("tags")
    except Exception:  # noqa: BLE001
        return None

    tag_values = [t for t in tags if isinstance(t, str) and t]
    if len(tag_values) < 2:
        return None

    rng = random.Random(0)
    best: tuple[str, str, int] | None = None

    # Sample up to 40 pairs (small + predictable for demos).
    for _ in range(40):
        a, b = rng.sample(tag_values, 2)
        query = {"tags": {"$all": [a, b]}}
        try:
            count = int(restaurants.count_documents(query))
        except Exception:  # noqa: BLE001
            continue

        # Avoid too-tiny results which can make timing noisy.
        if count < 50:
            continue

        if best is None or count < best[2]:
            best = (a, b, count)

    return best


def _format_find_query_text(
    *,
    collection: str,
    query: dict[str, Any],
    projection: dict[str, Any] | None = None,
    sort: list[tuple[str, int]] | None = None,
    limit: int | None = None,
) -> str:
    def _pf(value: Any) -> str:
        return pprint.pformat(value, width=140, compact=True, sort_dicts=True)

    parts: list[str] = []
    if projection is None:
        parts.append(f"db.{collection}.find({_pf(query)})")
    else:
        parts.append(
            f"db.{collection}.find({_pf(query)}, {_pf(projection)})"
        )
    if sort:
        parts.append(f".sort({_pf(sort)})")
    if limit is not None:
        parts.append(f".limit({limit})")
    return "".join(parts)


def _format_count_query_text(*, collection: str, query: dict[str, Any]) -> str:
    return f"db.{collection}.count_documents({pprint.pformat(query, width=140, compact=True, sort_dicts=True)})"


def _format_aggregate_query_text(*, collection: str, pipeline: list[dict[str, Any]]) -> str:
    return f"db.{collection}.aggregate({pprint.pformat(pipeline, width=140, compact=True, sort_dicts=True)})"


def _print_query_and_samples(*, query_text: str, samples: Any, sample_limit: int = 3) -> None:
    print("Query:")
    print(query_text)
    print()
    print("Sample results:")

    if samples is None:
        print("  (no samples)")
        return

    if isinstance(samples, (int, float, str, bool)):
        print(f"  {samples!r}")
        return

    if isinstance(samples, dict):
        print(f"  {pprint.pformat(samples, width=88)}")
        return

    if isinstance(samples, list):
        to_show = samples[: max(0, sample_limit)]
        if not to_show:
            print("  (no results)")
            return
        for item in to_show:
            print(f"  {pprint.pformat(item, width=88)}")
        return

    # Fallback for unexpected sample types
    print(f"  {samples!r}")


def timed(label: str, fn: Callable[[], Any]) -> Any:
    """Run a callable once, print its wall-clock duration, and return its result."""
    start = time.perf_counter()
    value = fn()
    duration_ms = (time.perf_counter() - start) * 1000
    print(f"{label}: {duration_ms:.1f}ms")
    return value


def timed_many(label: str, fn: Callable[[], Any], repeats: int, warmup: int = 1) -> None:
    """Run a callable multiple times and print average/best timing.

    Executes an optional warmup phase (not included in timings) to reduce one-time
    effects (connection setup, caches, JIT, etc.).
    """
    for _ in range(max(warmup, 0)):
        fn()

    durations_ms: list[float] = []
    for _ in range(max(repeats, 1)):
        start = time.perf_counter()
        fn()
        durations_ms.append((time.perf_counter() - start) * 1000)

    avg = sum(durations_ms) / len(durations_ms)
    best = min(durations_ms)
    print(f"{label}: avg={avg:.1f}ms best={best:.1f}ms (n={len(durations_ms)})")


def timed_many_stats(label: str, fn: Callable[[], Any], repeats: int, warmup: int = 1) -> dict[str, float]:
    """Run a callable multiple times, print timings, and return avg/best."""
    for _ in range(max(warmup, 0)):
        fn()

    durations_ms: list[float] = []
    for _ in range(max(repeats, 1)):
        start = time.perf_counter()
        fn()
        durations_ms.append((time.perf_counter() - start) * 1000)

    avg = sum(durations_ms) / len(durations_ms)
    best = min(durations_ms)
    print(f"{label}: avg={avg:.1f}ms best={best:.1f}ms (n={len(durations_ms)})")
    return {"avg_ms": avg, "best_ms": best}


def _collect_stages(plan: Any, out: list[str]) -> None:
    """Recursively walk an explain plan and collect any 'stage' strings.

    DocumentDB/Mongo explain output is a nested structure of dicts/lists; this
    helper extracts all stage names (e.g., IXSCAN, COLLSCAN) into a flat list.
    """
    if isinstance(plan, dict):
        stage = plan.get("stage")
        if isinstance(stage, str):
            out.append(stage)
        for value in plan.values():
            _collect_stages(value, out)
        return
    if isinstance(plan, list):
        for value in plan:
            _collect_stages(value, out)


def _collect_field_strings(plan: Any, field: str, out: list[str]) -> None:
    """Recursively collect string values for a given field from an explain plan."""
    if isinstance(plan, dict):
        value = plan.get(field)
        if isinstance(value, str):
            out.append(value)
        for child in plan.values():
            _collect_field_strings(child, field, out)
        return
    if isinstance(plan, list):
        for child in plan:
            _collect_field_strings(child, field, out)


def _unique_preserve_order(values: list[str]) -> list[str]:
    """Return unique items while preserving original order."""
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if value not in seen:
            out.append(value)
            seen.add(value)
    return out


def _pick_scan_stage(stages: list[str]) -> str | None:
    """Pick the most relevant scan stage from a list of stage names.

    Prefers IXSCAN over COLLSCAN when present; otherwise returns the first stage
    if any.
    """
    if not stages:
        return None
    normalized = [s.upper() for s in stages if isinstance(s, str)]
    for preferred in ("IXSCAN", "COLLSCAN"):
        if preferred in normalized:
            return preferred
    return normalized[0] if normalized else None


def _safe_explain(cursor: Any) -> dict | None:
    """Best-effort explain wrapper across Mongo/DocumentDB variations.

    Tries verbosity modes in descending usefulness, and falls back to whatever
    the server supports. Returns None if explain isn't available.
    """
    for verbosity in ("executionStats", "queryPlanner"):
        try:
            # Some PyMongo versions (or shims) don't accept a keyword argument
            # here, so pass verbosity positionally.
            return cursor.explain(verbosity)
        except TypeError:
            try:
                # Try keyword form as a secondary fallback for environments that
                # *only* accept a keyword argument.
                return cursor.explain(verbosity=verbosity)
            except TypeError:
                try:
                    return cursor.explain()
                except Exception:  # noqa: BLE001
                    continue
            except Exception:  # noqa: BLE001
                continue
        except Exception:  # noqa: BLE001
            continue
    return None


def _explain_summary_from_explain(explain: dict) -> dict[str, Any]:
    planner = explain.get("queryPlanner", {}) if isinstance(explain, dict) else {}
    winning_plan = planner.get("winningPlan", {}) if isinstance(planner, dict) else {}

    stages: list[str] = []
    _collect_stages(winning_plan, stages)

    index_names: list[str] = []
    _collect_field_strings(winning_plan, "indexName", index_names)
    index_names = _unique_preserve_order([n for n in index_names if isinstance(n, str)])

    stats = explain.get("executionStats") if isinstance(explain, dict) else None
    has_execution_stats = isinstance(stats, dict)

    summary: dict[str, Any] = {
        "scanStage": _pick_scan_stage(stages),
        "indexName": index_names[0] if index_names else None,
    }
    if has_execution_stats:
        summary.update(
            {
                "nReturned": stats.get("nReturned"),
                "totalDocsExamined": stats.get("totalDocsExamined"),
                "totalKeysExamined": stats.get("totalKeysExamined"),
            }
        )
    return summary


def get_find_explain_summary(cursor: Any) -> dict[str, Any] | None:
    explain = _safe_explain(cursor)
    if not explain or not isinstance(explain, dict):
        return None
    return _explain_summary_from_explain(explain)


def print_explain_summary(label: str, cursor: Any) -> dict[str, Any] | None:
    """Print a small, stable subset of explain output for demos.

    Summarizes whether the query is using an index scan vs collection scan and
    (when available) includes basic execution metrics.
    """
    summary = get_find_explain_summary(cursor)
    if summary is None:
        print(f"{label}:", {"scanStage": None, "indexName": None})
        return None
    print(f"{label}:", summary)
    return summary


def _safe_aggregate_explain(db: Any, collection_name: str, pipeline: list[dict]) -> dict | None:
    for verbosity in ("executionStats", "queryPlanner"):
        cmd = {
            "explain": {"aggregate": collection_name, "pipeline": pipeline, "cursor": {}},
            "verbosity": verbosity,
        }
        try:
            out = db.command(cmd)
            if isinstance(out, dict):
                return out
        except Exception:  # noqa: BLE001
            continue
    return None


def get_aggregate_explain_summary(restaurants: Any, pipeline: list[dict]) -> dict[str, Any] | None:
    db = restaurants.database
    explain = _safe_aggregate_explain(db, restaurants.name, pipeline)
    if not explain or not isinstance(explain, dict):
        return None

    # Mongo-style aggregation explain responses can vary; try to reuse the same
    # planner parsing when possible.
    if "queryPlanner" in explain:
        return _explain_summary_from_explain(explain)

    # Fallback: attempt to find stages in a top-level "stages" array.
    stages: list[str] = []
    index_names: list[str] = []
    _collect_stages(explain, stages)
    _collect_field_strings(explain, "indexName", index_names)
    index_names = _unique_preserve_order([n for n in index_names if isinstance(n, str)])
    return {
        "scanStage": _pick_scan_stage(stages),
        "indexName": index_names[0] if index_names else None,
    }


def print_aggregate_explain_summary(label: str, restaurants: Any, pipeline: list[dict]) -> dict[str, Any] | None:
    summary = get_aggregate_explain_summary(restaurants, pipeline)
    if summary is None:
        print(f"{label}:", {"scanStage": None, "indexName": None})
        return None
    print(f"{label}:", summary)
    return summary


def _connect(uri: str) -> tuple[MongoClient, Any]:
    client = MongoClient(uri)
    client.admin.command("ping")
    return client, client["foodservice"]["restaurants"]


def op_show_counts(restaurants: Any) -> None:
    total_docs = restaurants.estimated_document_count()
    print(f"Connected. restaurants documents: ~{total_docs}")
    if total_docs < 1000:
        print(
            "Note: dataset is small; index timing differences may be hard to see. "
            "Consider regenerating/restoring more sample docs for a clearer before/after."
        )


def op_reset_indexes(restaurants: Any) -> list[str]:
    """Drop all non-_id indexes and return the names that were removed."""
    dropped: list[str] = []
    try:
        for idx in restaurants.list_indexes():
            name = idx.get("name")
            if name and name != "_id_":
                try:
                    restaurants.drop_index(name)
                    dropped.append(name)
                except Exception:  # noqa: BLE001
                    pass
    except Exception:  # noqa: BLE001
        pass
    if dropped:
        print(f"Reset indexes: dropped {len(dropped)} index(es)")
    else:
        print("Reset indexes: no non-_id indexes to drop")
    return dropped


def _print_before_after_summary(result: dict[str, Any]) -> None:
    before = result.get("before", {})
    after = result.get("after", {})

    before_avg = float(before.get("avg_ms", 0.0))
    after_avg = float(after.get("avg_ms", 0.0))
    before_best = float(before.get("best_ms", 0.0))
    after_best = float(after.get("best_ms", 0.0))

    print(
        "Summary:",
        f"avg before={before_avg:.1f}ms after={after_avg:.1f}ms | best before={before_best:.1f}ms after={after_best:.1f}ms",
    )


def _run_index_tuning_find_cuisine(restaurants: Any, repeats: int, warmup: int, variant: str = "covered") -> dict[str, Any]:
    """Menu item 2: optimize a filter query on cuisine using a single-field index.

    Variants:
        - read_all: consume all matching documents (shows filter selectivity)
        - count: count matching docs (often most dramatic with an index)
        - covered: covered projection on cuisine only (index-only read)
    """
    title = {
        "covered": "Find: cuisine (rare) — covered projection (cuisine only)",
        "count": "Count: cuisine (rare) — count_documents",
        "read_all": "Find: filter by cuisine (rare) — read all matches",
    }.get(variant, f"Cuisine demo ({variant})")

    number = {
        "covered": "2",
        "count": "3",
        "read_all": "2",
    }.get(variant, "2")

    print(f"\n{number}) {title}")
    op_reset_indexes(restaurants)

    picked = _pick_rare_cuisine(restaurants)
    cuisine_value, cuisine_count = (picked if picked is not None else ("Italian", 0))
    query = {"cuisine": cuisine_value}

    print(f"Using cuisine={cuisine_value!r} (matches: {cuisine_count if cuisine_count else 'unknown'})")

    projection: dict[str, Any] | None = None
    if variant == "covered":
        # Covered query when combined with { cuisine: 1 } and excluding _id.
        projection = {"_id": 0, "cuisine": 1}
        print("Query shape: covered projection (consume cursor; no limit)")
    elif variant == "count":
        print("Query shape: count_documents")
    else:
        print("Query shape: read all matches (consume cursor; no limit)")

    # Print the query once (and a few results) before timing/explain.
    if variant == "covered":
        query_text = _format_find_query_text(
            collection=restaurants.name,
            query=query,
            projection=projection,
        )
        sample_docs = list(restaurants.find(query, projection).limit(3))
        _print_query_and_samples(query_text=query_text, samples=sample_docs)
    elif variant == "count":
        query_text = _format_count_query_text(collection=restaurants.name, query=query)
        sample_docs = list(restaurants.find(query, {"_id": 0, "name": 1, "cuisine": 1}).limit(3))
        _print_query_and_samples(query_text=query_text, samples=sample_docs)
    else:
        query_text = _format_find_query_text(collection=restaurants.name, query=query)
        sample_docs = list(restaurants.find(query, {"_id": 0, "name": 1, "cuisine": 1}).limit(3))
        _print_query_and_samples(query_text=query_text, samples=sample_docs)

    def _run_query_read_all_docs() -> int:
        n = 0
        for _ in restaurants.find(query):
            n += 1
        return n

    def _run_query_covered_projection() -> int:
        n = 0
        for _ in restaurants.find(query, projection):
            n += 1
        return n

    def _run_query_count() -> int:
        return int(restaurants.count_documents(query))

    if variant == "covered":
        _run_query = _run_query_covered_projection
        def _make_explain_cursor() -> Any:
            return restaurants.find(query, projection)
    elif variant == "count":
        _run_query = _run_query_count
        # Best-effort explain: show planner info for the equivalent filter query.
        def _make_explain_cursor() -> Any:
            return restaurants.find(query)
    else:
        _run_query = _run_query_read_all_docs
        def _make_explain_cursor() -> Any:
            return restaurants.find(query)

    before_explain = print_explain_summary("Explain (before index)", _make_explain_cursor())
    before_time = timed_many_stats("Elapsed (before index)", _run_query, repeats=repeats, warmup=warmup)

    print("Creating index: { cuisine: 1 }")
    restaurants.create_index([("cuisine", 1)], name="idx_cuisine_1")

    after_explain = print_explain_summary("Explain (after index)", _make_explain_cursor())
    after_time = timed_many_stats("Elapsed (after index)", _run_query, repeats=repeats, warmup=warmup)

    result = {
        "label": f"Cuisine={cuisine_value} ({variant})",
        "before": {"explain": before_explain, **before_time},
        "after": {"explain": after_explain, **after_time},
        "index": "idx_cuisine_1",
    }

    _print_before_after_summary(result)
    return result


def _run_index_tuning_sort_by_name(restaurants: Any, repeats: int, warmup: int) -> dict[str, Any]:
    """Compound index demo: filter + sort + limit.

    This shows how a compound index can avoid an in-memory sort and allow the
    engine to stop early once it has produced the first N results.
    """
    print("\n4) Find: cuisine (rare) + sort by name + limit → create { cuisine: 1, name: 1 }")
    op_reset_indexes(restaurants)

    picked = _pick_rare_cuisine(restaurants)
    cuisine_value, cuisine_count = (picked if picked is not None else ("Italian", 0))
    query = {"cuisine": cuisine_value}
    projection = {"_id": 0, "name": 1, "cuisine": 1}
    limit_n = 50

    print(f"Using cuisine={cuisine_value!r} (matches: {cuisine_count if cuisine_count else 'unknown'})")
    print(f"Query shape: sort by name, limit {limit_n}")

    query_text = _format_find_query_text(
        collection=restaurants.name,
        query=query,
        projection=projection,
        sort=[("name", 1)],
        limit=limit_n,
    )
    sample_docs = list(restaurants.find(query, projection).sort("name", 1).limit(3))
    _print_query_and_samples(query_text=query_text, samples=sample_docs)

    def _run_query() -> list[dict]:
        return list(restaurants.find(query, projection).sort("name", 1).limit(limit_n))

    before_explain = print_explain_summary(
        "Explain (before index)",
        restaurants.find(query, projection).sort("name", 1).limit(limit_n),
    )
    before_time = timed_many_stats("Elapsed (before index)", _run_query, repeats=repeats, warmup=warmup)

    print("Creating index: { cuisine: 1, name: 1 }")
    restaurants.create_index([("cuisine", 1), ("name", 1)], name="idx_cuisine_name_1")

    after_explain = print_explain_summary(
        "Explain (after index)",
        restaurants.find(query, projection).sort("name", 1).limit(limit_n),
    )
    after_time = timed_many_stats("Elapsed (after index)", _run_query, repeats=repeats, warmup=warmup)

    result = {
        "label": f"Sort by name for cuisine={cuisine_value}",
        "before": {"explain": before_explain, **before_time},
        "after": {"explain": after_explain, **after_time},
        "index": "idx_cuisine_name_1",
    }

    _print_before_after_summary(result)
    return result


def _run_index_tuning_multikey_tags(restaurants: Any, repeats: int, warmup: int) -> dict[str, Any]:
    """Multikey index demo: filter on an array field (tags)."""
    print("\n5) Find: tags $all (array field) → create { tags: 1 } (multikey)")
    op_reset_indexes(restaurants)

    # Using $all makes the predicate more selective and usually yields a clearer
    # before/after difference than matching a single high-frequency tag.
    picked_pair = _pick_good_tags_all_pair(restaurants)
    if picked_pair is not None:
        tag_a, tag_b, match_count = picked_pair
    else:
        tag_a = "date-night"
        tag_b = "delivery"
        query = {"tags": {"$all": [tag_a, tag_b]}}
        try:
            match_count = int(restaurants.count_documents(query))
        except Exception:  # noqa: BLE001
            match_count = 0

    query = {"tags": {"$all": [tag_a, tag_b]}}

    print(f"Using tags $all={[tag_a, tag_b]!r} (matches: {match_count if match_count else 'unknown'})")
    print("Query shape: count_documents (tags $all)")

    query_text = _format_count_query_text(collection=restaurants.name, query=query)
    sample_docs = list(
        restaurants.find(query, {"_id": 0, "name": 1, "cuisine": 1, "tags": 1}).limit(3)
    )
    _print_query_and_samples(query_text=query_text, samples=sample_docs)

    def _run_query() -> int:
        return int(restaurants.count_documents(query))

    before_explain = print_explain_summary("Explain (before index)", restaurants.find(query))
    before_time = timed_many_stats("Elapsed (before index)", _run_query, repeats=repeats, warmup=warmup)

    print("Creating index: { tags: 1 }")
    restaurants.create_index([("tags", 1)], name="idx_tags_1")

    after_explain = print_explain_summary("Explain (after index)", restaurants.find(query))
    after_time = timed_many_stats("Elapsed (after index)", _run_query, repeats=repeats, warmup=warmup)

    result = {
        "label": f"Count tags $all={[tag_a, tag_b]}",
        "before": {"explain": before_explain, **before_time},
        "after": {"explain": after_explain, **after_time},
        "index": "idx_tags_1",
    }

    _print_before_after_summary(result)
    return result


def _run_index_tuning_aggregation(restaurants: Any, repeats: int, warmup: int) -> dict[str, Any]:
    """Menu item 5: optimize an aggregation pipeline with an initial match."""
    print("\n6) Aggregate: match cuisine (rare) + group by zipcode → create { cuisine: 1, 'address.zipcode': 1 }")
    op_reset_indexes(restaurants)

    picked = _pick_rare_cuisine(restaurants)
    cuisine_value, cuisine_count = (picked if picked is not None else ("Italian", 0))
    print(f"Using cuisine={cuisine_value!r} (matches: {cuisine_count if cuisine_count else 'unknown'})")

    pipeline = [
        {"$match": {"cuisine": cuisine_value}},
        {"$group": {"_id": "$address.zipcode", "count": {"$sum": 1}}},
        {"$sort": {"count": -1}},
        {"$limit": 20},
    ]

    query_text = _format_aggregate_query_text(collection=restaurants.name, pipeline=pipeline)
    sample_rows = list(restaurants.aggregate(pipeline))
    _print_query_and_samples(query_text=query_text, samples=sample_rows, sample_limit=5)

    def _run_query() -> list[dict]:
        return list(restaurants.aggregate(pipeline))

    before_explain = print_aggregate_explain_summary("Explain (before index)", restaurants, pipeline)
    before_time = timed_many_stats("Elapsed (before index)", _run_query, repeats=repeats, warmup=warmup)

    print("Creating index: { cuisine: 1, 'address.zipcode': 1 }")
    restaurants.create_index([("cuisine", 1), ("address.zipcode", 1)], name="idx_cuisine_zipcode_1")

    after_explain = print_aggregate_explain_summary("Explain (after index)", restaurants, pipeline)
    after_time = timed_many_stats("Elapsed (after index)", _run_query, repeats=repeats, warmup=warmup)

    result = {
        "label": f"Aggregate cuisine={cuisine_value} by zipcode",
        "before": {"explain": before_explain, **before_time},
        "after": {"explain": after_explain, **after_time},
        "index": "idx_cuisine_zipcode_1",
    }

    _print_before_after_summary(result)
    return result


def run_all(restaurants: Any, repeats: int, warmup: int) -> list[dict[str, Any]]:
    """Run the index tuning demos for menu items 2–6 and return results."""
    op_show_counts(restaurants)
    print("\nResetting indexes for a clean demo run...")
    op_reset_indexes(restaurants)

    results: list[dict[str, Any]] = []
    results.append(_run_index_tuning_find_cuisine(restaurants, repeats=repeats, warmup=warmup, variant="covered"))
    results.append(_run_index_tuning_find_cuisine(restaurants, repeats=repeats, warmup=warmup, variant="count"))
    results.append(_run_index_tuning_sort_by_name(restaurants, repeats=repeats, warmup=warmup))
    results.append(_run_index_tuning_multikey_tags(restaurants, repeats=repeats, warmup=warmup))
    results.append(_run_index_tuning_aggregation(restaurants, repeats=repeats, warmup=warmup))
    print("Done.")
    return results


def _print_menu() -> None:
    print("\n=== Query Examples Menu ===")
    print("\nIndex tuning demos")
    print("  1) Show document count / connection check")
    print("  2) Find: cuisine covered projection → create { cuisine: 1 }")
    print("  3) Count: cuisine count_documents → create { cuisine: 1 }")
    print("  4) Find: cuisine + sort by name + limit → create { cuisine: 1, name: 1 }")
    print("  5) Find: tags $all (array field) count_documents → create { tags: 1 } (multikey)")
    print("  6) Aggregate: match cuisine (rare) + group by zipcode → create { cuisine: 1, 'address.zipcode': 1 }")

    print("\nr) Reset indexes (drop all non-_id indexes)")
    print("q) Quit")


def _pause() -> None:
    if sys.stdin.isatty():
        input("\nPress Enter to return to the menu...")


def run_menu(restaurants: Any, repeats: int, warmup: int) -> None:
    results: list[dict[str, Any]] = []
    while True:
        _print_menu()
        choice = input("\nSelection: ").strip().lower()
        if choice in {"q", "quit", "exit"}:
            print("Exiting.")
            return

        try:
            match choice:
                case "1":
                    op_show_counts(restaurants)
                case "2":
                    results.append(_run_index_tuning_find_cuisine(restaurants, repeats=repeats, warmup=warmup, variant="covered"))
                case "3":
                    results.append(_run_index_tuning_find_cuisine(restaurants, repeats=repeats, warmup=warmup, variant="count"))
                case "4":
                    results.append(_run_index_tuning_sort_by_name(restaurants, repeats=repeats, warmup=warmup))
                case "5":
                    results.append(_run_index_tuning_multikey_tags(restaurants, repeats=repeats, warmup=warmup))
                case "6":
                    results.append(_run_index_tuning_aggregation(restaurants, repeats=repeats, warmup=warmup))
                case "r":
                    op_reset_indexes(restaurants)
                case _:
                    print(f"Unknown selection: {choice!r}")
            _pause()
        except Exception as exc:  # noqa: BLE001
            print(f"Operation failed: {type(exc).__name__}: {exc}")
            _pause()


def main() -> int:
    """CLI entry point for running the slide-deck query examples.

    Connects to the local DocumentDB instance and runs interactive index tuning
    demos showing before/after explain output and elapsed time.
    """
    parser = argparse.ArgumentParser(description="Run query examples used in the slide deck.")
    parser.add_argument(
        "--uri",
        type=str,
        default="mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true",
    )
    parser.add_argument(
        "--mode",
        choices=("menu", "all"),
        default=None,
        help="Run interactively (menu) or run all steps end-to-end.",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=10,
        help="How many times to run the index demo query for timings.",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=2,
        help="Warmup runs before timing the index demo query.",
    )
    parser.add_argument(
        "--only",
        nargs="+",
        choices=("2", "3", "4", "5", "6"),
        default=None,
        help="In --mode all, run only the specified step(s) (e.g., --only 2 3 6).",
    )
    args = parser.parse_args()

    client, restaurants = _connect(args.uri)

    # Default behavior:
    # - If stdin is a real terminal, go interactive (menu)
    # - If piped/redirected, run everything end-to-end
    mode = args.mode
    if mode is None:
        mode = "menu" if sys.stdin.isatty() else "all"

    if mode == "all":
        if args.only:
            op_show_counts(restaurants)
            print("\nResetting indexes for a clean demo run...")
            op_reset_indexes(restaurants)

            for step in args.only:
                match step:
                    case "2":
                        _run_index_tuning_find_cuisine(restaurants, repeats=args.repeats, warmup=args.warmup, variant="covered")
                    case "3":
                        _run_index_tuning_find_cuisine(restaurants, repeats=args.repeats, warmup=args.warmup, variant="count")
                    case "4":
                        _run_index_tuning_sort_by_name(restaurants, repeats=args.repeats, warmup=args.warmup)
                    case "5":
                        _run_index_tuning_multikey_tags(restaurants, repeats=args.repeats, warmup=args.warmup)
                    case "6":
                        _run_index_tuning_aggregation(restaurants, repeats=args.repeats, warmup=args.warmup)
            print("Done.")
        else:
            run_all(restaurants, repeats=args.repeats, warmup=args.warmup)
    else:
        # Show a quick header and reset indexes so the first run is clean.
        op_show_counts(restaurants)
        op_reset_indexes(restaurants)
        run_menu(restaurants, repeats=args.repeats, warmup=args.warmup)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

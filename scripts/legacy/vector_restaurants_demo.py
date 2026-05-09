import argparse
import json
import time
from pathlib import Path

from pymongo import MongoClient

from fake_embeddings import (
    FakeEmbeddingConfig,
    embedding_text_for_restaurant,
    embedding_text_for_restaurant_combined,
    fake_embed,
    tokenize,
)


KNOWN_CUISINES = {
    "italian",
    "chinese",
    "mexican",
    "indian",
    "japanese",
    "thai",
    "french",
    "greek",
    "american",
    "mediterranean",
}

KNOWN_BOROUGHS = {"manhattan", "brooklyn", "queens", "bronx", "staten", "island"}

KNOWN_CITIES = {
    "new york",
    "seattle",
    "austin",
    "chicago",
    "boston",
    "san francisco",
    "denver",
    "atlanta",
}


def build_query_embedding_text(query: str) -> str:
    """Normalize a free-form query into a structured text.

    Our vector docs embed a structured string like:
      "cuisine Italian borough Manhattan city New York zipcode 10001"

    This helper makes queries match that shape so results look intuitive.
    """

    raw = query.strip().lower()
    toks = tokenize(raw)

    parts: list[str] = []

    # Zipcode detection (5-digit token)
    for t in toks:
        if len(t) == 5 and t.isdigit():
            parts.append(f"zipcode {t}")
            break

    # Cuisine detection
    for t in toks:
        if t in KNOWN_CUISINES:
            parts.append(f"cuisine {t}")
            break

    # Borough detection
    for t in toks:
        if t in KNOWN_BOROUGHS:
            parts.append(f"borough {t}")
            break

    # City detection (simple substring match for multi-word cities)
    for city in KNOWN_CITIES:
        if city in raw:
            parts.append(f"city {city}")
            break

    # Fall back to raw query if we didn't recognize anything.
    if not parts:
        return query

    # Keep some of the raw words too for additional signal.
    parts.append(f"query {raw}")
    return " ".join(parts)


def cosine_similarity_unit_vectors(a: list[float], b: list[float]) -> float:
    """Cosine similarity for already-L2-normalized vectors.

    Our fake embeddings L2-normalize vectors, so cosine similarity is just the dot product.
    """

    if len(a) != len(b):
        raise ValueError("vector lengths must match")
    return float(sum(x * y for x, y in zip(a, b, strict=True)))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build a separate restaurants_vectors collection with deterministic fake embeddings, "
            "create a vector index, and run a sample $search query."
        )
    )
    parser.add_argument(
        "--uri",
        type=str,
        default="mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true",
    )
    parser.add_argument("--db", type=str, default="foodservice")
    parser.add_argument("--source", type=str, default="restaurants")
    parser.add_argument("--target", type=str, default="restaurants_vectors")
    parser.add_argument(
        "--source-file",
        type=str,
        default="",
        help=(
            "Optional path to a restaurants JSON file (array of documents). "
            "If provided, vector docs are built from this file instead of reading from --source."
        ),
    )
    parser.add_argument("--dimensions", type=int, default=256)
    parser.add_argument(
        "--drop",
        action="store_true",
        help="Drop the target collection before rebuilding.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Limit number of source docs processed (0 = all).",
    )
    parser.add_argument(
        "--query",
        type=str,
        default="cozy romantic date night pasta",
        help="Natural-language-ish query string for the vector search.",
    )
    parser.add_argument("--k", type=int, default=5, help="Top-k results")
    parser.add_argument(
        "--min-score",
        type=float,
        default=0.0,
        help="Filter results by minimum searchScore after $search.",
    )
    parser.add_argument(
        "--filter-on",
        choices=["searchScore", "cosine"],
        default="searchScore",
        help=(
            "Which score to use for --min-score filtering. "
            "searchScore uses the server-provided $meta score; cosine computes a true cosine similarity "
            "(dot product) client-side using the stored vectors."
        ),
    )
    parser.add_argument(
        "--mode",
        choices=["compact", "rich"],
        default="compact",
        help=(
            "Embedding style for the single vectorEmbedding field. "
            "compact is optimized for high cosine similarity (review-tags vocabulary); "
            "rich includes structured cuisine/location tokens."
        ),
    )

    args = parser.parse_args()

    cfg = FakeEmbeddingConfig(dimensions=args.dimensions)

    client = MongoClient(args.uri)
    client.admin.command("ping")

    db = client[args.db]
    source = db[args.source]
    target = db[args.target]

    if args.source_file:
        source_path = Path(args.source_file)
        print(f"Connected. Source file: {source_path}")
    else:
        source_count = source.estimated_document_count()
        print(f"Connected. Source {args.db}.{args.source} docs: ~{source_count}")

    if args.drop:
        target.drop()
        print(f"Dropped target collection {args.db}.{args.target}")

    # Rebuild the target collection if it's empty (or was dropped).
    target_count = target.estimated_document_count()
    if target_count == 0:
        print("Building vector documents...")
        if args.source_file:
            docs = json.loads(Path(args.source_file).read_text(encoding="utf-8"))
            if not isinstance(docs, list):
                raise ValueError("--source-file must contain a JSON array of documents")
            if args.limit and args.limit > 0:
                docs = docs[: args.limit]
            cursor = docs
        else:
            cursor = source.find({})
            if args.limit and args.limit > 0:
                cursor = cursor.limit(args.limit)

        vector_docs = []
        processed = 0
        for doc in cursor:
            if not isinstance(doc, dict):
                continue

            # Defensive: tolerate old sample shapes if present.
            doc.pop("reviewTags", None)
            doc.pop("grades", None)

            processed += 1
            embedding_text = embedding_text_for_restaurant_combined(doc, style=args.mode)
            vector = fake_embed(embedding_text, config=cfg)

            # Make a separate dataset: keep original fields, add embedding fields.
            doc_out = dict(doc)
            doc_out["embeddingText"] = embedding_text
            doc_out["vectorEmbedding"] = vector

            vector_docs.append(doc_out)

            if len(vector_docs) >= 1000:
                target.insert_many(vector_docs)
                vector_docs.clear()

        if vector_docs:
            target.insert_many(vector_docs)

        print(f"Built {processed} vector documents into {args.db}.{args.target}")
    else:
        print(
            f"Reusing existing target collection {args.db}.{args.target} docs: ~{target_count} "
            "(use --drop to rebuild)"
        )

    # Create vector index
    print("Creating vector index...")
    try:
        vector_path = "vectorEmbedding"
        db.command(
            {
                "createIndexes": args.target,
                "indexes": [
                    {
                        "key": {vector_path: "cosmosSearch"},
                        "name": f"{vector_path}_hnsw",
                        "cosmosSearchOptions": {
                            "kind": "vector-hnsw",
                            "similarity": "COS",
                            "dimensions": args.dimensions,
                            "m": 16,
                            "efConstruction": 64,
                        },
                    }
                ],
            }
        )
        print(f"Created vector index {vector_path}_hnsw")
        time.sleep(2)
    except Exception as exc:  # noqa: BLE001
        print("Vector index creation failed:")
        print(str(exc))
        # If the index already exists, some engines error; that's fine for demo re-runs.
        # Continue to query.

    if args.mode == "rich":
        query_embedding_text = build_query_embedding_text(args.query)
    else:
        # compact mode: keep query raw so it shares the small tag vocabulary.
        query_embedding_text = args.query.strip().lower()
    print(f"Query: {args.query}")
    print(f"Query embedding text: {query_embedding_text}")
    query_vector = fake_embed(query_embedding_text, config=cfg)

    query_path = "vectorEmbedding"

    pipeline = [
        {
            "$search": {
                "cosmosSearch": {
                    "path": query_path,
                    "vector": query_vector,
                    "k": args.k,
                }
            }
        },
        {
            "$project": {
                "name": 1,
                "cuisine": 1,
                "borough": 1,
                "address": 1,
                query_path: 1,
                "score": {"$meta": "searchScore"},
            }
        },
    ]

    if args.min_score > 0 and args.filter_on == "searchScore":
        pipeline.append({"$match": {"score": {"$gte": args.min_score}}})

    results = list(target.aggregate(pipeline))

    if args.filter_on == "cosine":
        filtered = []
        for r in results:
            doc_vec = r.get(query_path) or []
            if not isinstance(doc_vec, list):
                continue
            cos = cosine_similarity_unit_vectors(query_vector, doc_vec)
            r["cosine"] = cos
            if args.min_score <= 0 or cos >= args.min_score:
                filtered.append(r)
        results = sorted(filtered, key=lambda x: x.get("cosine", 0.0), reverse=True)

    print("\nVector search results:")
    if args.min_score > 0:
        print(f"(filtered on {args.filter_on} >= {args.min_score})")
    for r in results:
        addr = r.get("address") or {}
        extra = ""
        if args.filter_on == "cosine":
            extra = f" | cosine={r.get('cosine')}"
        print(
            f"- {r.get('name')} | {r.get('cuisine')} | {r.get('borough')} | "
            f"{addr.get('city')} {addr.get('zipcode')} | score={r.get('score')}{extra}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

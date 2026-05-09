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
)


def _load_json_array(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("Expected the JSON file to contain an array of documents")

    docs: list[dict] = []
    for item in data:
        if isinstance(item, dict):
            docs.append(item)
    return docs


def _vectorize_doc(doc: dict, *, cfg: FakeEmbeddingConfig, style: str, include_text: bool) -> dict:
    # Defensive: tolerate old sample shapes if present.
    doc = dict(doc)
    doc.pop("reviewTags", None)
    doc.pop("grades", None)

    # Keep backward-compatible function imports around; only one vector is produced.
    if style == "rich":
        embedding_text = embedding_text_for_restaurant(doc)
    else:
        embedding_text = embedding_text_for_restaurant_combined(doc, style="compact")

    if include_text:
        doc["embeddingText"] = embedding_text
    doc["vectorEmbedding"] = fake_embed(embedding_text, config=cfg)

    return doc


def _insert_many_batched(collection, docs: list[dict], *, batch_size: int = 1000) -> int:
    inserted = 0
    batch: list[dict] = []
    for doc in docs:
        batch.append(doc)
        if len(batch) >= batch_size:
            result = collection.insert_many(batch)
            inserted += len(result.inserted_ids)
            batch.clear()

    if batch:
        result = collection.insert_many(batch)
        inserted += len(result.inserted_ids)

    return inserted


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate deterministic fake embeddings for data/restaurants.json, write a new JSON file, "
            "and (optionally) load it into a new collection."
        )
    )
    parser.add_argument(
        "--in-file",
        type=str,
        default=str(Path("data") / "restaurants.json"),
        help="Input restaurants JSON file (array of documents).",
    )
    parser.add_argument(
        "--out-file",
        type=str,
        default=str(Path("data") / "restaurants_vectors.json"),
        help="Output JSON file to write vector-enriched documents.",
    )
    parser.add_argument(
        "--style",
        choices=["compact", "rich"],
        default="compact",
        help=(
            "Embedding style for the single vectorEmbedding field. "
            "compact is optimized for high cosine similarity; rich includes structured location tokens."
        ),
    )
    parser.add_argument(
        "--include-text",
        action="store_true",
        help="Include embeddingText* fields in output (in addition to vectors).",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="DEPRECATED: Use --format pretty. Pretty-print output JSON (larger file).",
    )
    parser.add_argument(
        "--format",
        choices=["compact", "lines", "pretty"],
        default="compact",
        help=(
            "Output JSON formatting. "
            "compact writes a single-line JSON array; lines writes one document per line; "
            "pretty writes indented JSON (largest file)."
        ),
    )
    parser.add_argument(
        "--no-write",
        action="store_true",
        help="Do not write the output JSON file; only load into the database.",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=1000,
        help="Print progress every N documents (0 = disable).",
    )
    parser.add_argument("--dimensions", type=int, default=256)
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Limit number of input docs processed (0 = all).",
    )

    parser.add_argument(
        "--uri",
        type=str,
        default="mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true",
        help="DocumentDB/MongoDB URI (only used when loading).",
    )
    parser.add_argument("--db", type=str, default="foodservice")
    parser.add_argument("--collection", type=str, default="restaurants_vectors")
    parser.add_argument(
        "--drop",
        action="store_true",
        help="Drop the target collection before inserting (only used when loading).",
    )
    parser.add_argument(
        "--no-load",
        action="store_true",
        help="Only write the output JSON file; do not load into the database.",
    )

    args = parser.parse_args()

    in_path = Path(args.in_file)
    out_path = Path(args.out_file)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    cfg = FakeEmbeddingConfig(dimensions=args.dimensions)

    docs = _load_json_array(in_path)
    if args.limit and args.limit > 0:
        docs = docs[: args.limit]

    client = None
    collection = None
    if not args.no_load:
        client = MongoClient(args.uri)
        client.admin.command("ping")
        db = client[args.db]
        collection = db[args.collection]
        if args.drop:
            collection.drop()
            print(f"Dropped {args.db}.{args.collection}")

    # Stream vectorization so we don't hold the full vector dataset in memory.
    inserted = 0
    written = 0
    processed = 0
    batch: list[dict] = []

    start = time.time()

    out_format = args.format
    if args.pretty and out_format == "compact":
        out_format = "pretty"

    ensure_ascii = False
    indent = 2 if out_format == "pretty" else None
    separators = None if out_format == "pretty" else (",", ":")

    # Control array framing/commas so we can do "one doc per line" without indentation.
    if out_format == "compact":
        array_start = "["
        comma = ","
        array_end = "]"
    else:
        array_start = "[\n"
        comma = ",\n"
        array_end = "\n]\n"

    out_f = None
    if not args.no_write:
        out_f = out_path.open("w", encoding="utf-8", newline="\n")
        out_f.write(array_start)

    try:
        first = True
        for doc in docs:
            processed += 1
            vdoc = _vectorize_doc(
                doc,
                cfg=cfg,
                style=args.style,
                include_text=bool(args.include_text),
            )

            if out_f is not None:
                if not first:
                    out_f.write(comma)
                out_f.write(
                    json.dumps(
                        vdoc,
                        ensure_ascii=ensure_ascii,
                        indent=indent,
                        separators=separators,
                    )
                )
                first = False
                written += 1

            if collection is not None:
                batch.append(vdoc)
                if len(batch) >= 1000:
                    result = collection.insert_many(batch)
                    inserted += len(result.inserted_ids)
                    batch.clear()

            if args.progress_every and processed % args.progress_every == 0:
                elapsed = max(0.001, time.time() - start)
                rate = processed / elapsed
                print(
                    f"Processed {processed}/{len(docs)} docs | "
                    f"wrote {written} | inserted {inserted} | {rate:.1f} docs/sec"
                )

        if collection is not None and batch:
            result = collection.insert_many(batch)
            inserted += len(result.inserted_ids)
            batch.clear()

    finally:
        if out_f is not None:
            out_f.write(array_end)
            out_f.close()

    if not args.no_write:
        print(f"Wrote {written} vector documents to {out_path}")

    if collection is not None:
        print(f"Inserted {inserted} documents into {args.db}.{args.collection}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

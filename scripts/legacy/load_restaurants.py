import argparse
import json
from pathlib import Path

from pymongo import MongoClient


def main() -> int:
    parser = argparse.ArgumentParser(description="Load restaurants JSON into DocumentDB.")
    parser.add_argument(
        "--uri",
        type=str,
        default="mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true",
    )
    parser.add_argument("--db", type=str, default="foodservice")
    parser.add_argument("--collection", type=str, default="restaurants")
    parser.add_argument("--file", type=str, default=str(Path("data") / "restaurants.json"))
    parser.add_argument("--drop", action="store_true", help="Drop the collection before inserting.")
    args = parser.parse_args()

    file_path = Path(args.file)
    docs = json.loads(file_path.read_text(encoding="utf-8"))
    if not isinstance(docs, list):
        raise ValueError("Expected the JSON file to contain an array of documents")

    for doc in docs:
        if isinstance(doc, dict):
            doc.pop("reviewTags", None)
            doc.pop("grades", None)

    client = MongoClient(args.uri)
    db = client[args.db]
    collection = db[args.collection]

    client.admin.command("ping")

    if args.drop:
        collection.drop()

    if docs:
        result = collection.insert_many(docs)
        print(f"Inserted {len(result.inserted_ids)} documents into {args.db}.{args.collection}")
    else:
        print("No documents to insert")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

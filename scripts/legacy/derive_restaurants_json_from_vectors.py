import argparse
import json
from pathlib import Path
from typing import Any, Iterator


def iter_json_array(path: Path) -> Iterator[dict[str, Any]]:
    """Stream a JSON array of objects from disk."""

    decoder = json.JSONDecoder()
    with path.open("r", encoding="utf-8") as f:
        buf = ""

        # Read until we find the opening '['
        while True:
            chunk = f.read(64 * 1024)
            if not chunk:
                raise ValueError("Unexpected end of file while looking for '['")
            buf += chunk
            i = 0
            while i < len(buf) and buf[i].isspace():
                i += 1
            if i < len(buf):
                if buf[i] != "[":
                    raise ValueError("Expected JSON array (file should start with '[')")
                buf = buf[i + 1 :]
                break

        # Parse items until we hit ']'
        while True:
            # Ensure buffer has non-whitespace content
            while True:
                j = 0
                while j < len(buf) and buf[j].isspace():
                    j += 1
                if j < len(buf):
                    buf = buf[j:]
                    break
                chunk = f.read(64 * 1024)
                if not chunk:
                    raise ValueError("Unexpected end of file while parsing JSON array")
                buf += chunk

            if buf.startswith("]"):
                return

            # Decode one object
            while True:
                try:
                    obj, idx = decoder.raw_decode(buf)
                    break
                except json.JSONDecodeError:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        raise
                    buf += chunk

            if not isinstance(obj, dict):
                raise ValueError("Expected array items to be JSON objects")
            yield obj
            buf = buf[idx:]

            # Consume trailing whitespace and comma
            while True:
                k = 0
                while k < len(buf) and buf[k].isspace():
                    k += 1
                if k < len(buf):
                    buf = buf[k:]
                    break
                chunk = f.read(64 * 1024)
                if not chunk:
                    raise ValueError("Unexpected end of file after JSON item")
                buf += chunk

            if buf.startswith(","):
                buf = buf[1:]
                continue
            if buf.startswith("]"):
                return


def indent_block(text: str, prefix: str) -> str:
    return "\n".join(prefix + line if line else prefix.rstrip() for line in text.splitlines())


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Derive a non-vectorized restaurants.json from restaurants_vectors.json by removing vector fields. "
            "This keeps the two datasets' schemas aligned for demos (compound index on restaurants, vector search on restaurants_vectors)."
        )
    )
    parser.add_argument(
        "--in",
        dest="in_path",
        default=str(Path("data") / "restaurants_vectors.json"),
        help="Input vectorized JSON file (default: data/restaurants_vectors.json)",
    )
    parser.add_argument(
        "--out",
        dest="out_path",
        default=str(Path("data") / "restaurants.json"),
        help="Output non-vectorized JSON file (default: data/restaurants.json)",
    )
    parser.add_argument(
        "--remove",
        nargs="+",
        default=["vectorEmbedding", "embeddingText"],
        help="Top-level fields to remove (default: vectorEmbedding embeddingText)",
    )
    args = parser.parse_args()

    in_path = Path(args.in_path)
    out_path = Path(args.out_path)

    if not in_path.exists():
        raise FileNotFoundError(in_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(out_path.suffix + ".tmp")

    removed = set(args.remove)
    count = 0

    with tmp_path.open("w", encoding="utf-8", newline="\n") as out:
        out.write("[\n")
        first = True
        for doc in iter_json_array(in_path):
            for k in removed:
                doc.pop(k, None)

            rendered = json.dumps(doc, indent=2, ensure_ascii=False)
            rendered = indent_block(rendered, "  ")

            if not first:
                out.write(",\n")
            out.write(rendered)
            first = False
            count += 1

        out.write("\n]\n")

    tmp_path.replace(out_path)
    print(f"Wrote {count} documents to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Deterministic, offline-friendly "fake embeddings" for demos.

Goal
----
Provide a repeatable way to convert text -> fixed-length float vector so we can
demo vector indexing + $search without requiring an external embedding model.

Approach
--------
Hashed bag-of-words:
- tokenize text into words
- map each token into a dimension via SHA-256 (stable across machines)
- accumulate counts
- L2-normalize so cosine similarity is meaningful

This is not semantically rich like real embeddings, but it is deterministic and
"good enough" to show vector index + similarity search mechanics.
"""

from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass


_WORD_RE = re.compile(r"[a-z0-9]+")


def _review_tags_from_reviews(reviews: object) -> list[str]:
    if not isinstance(reviews, list):
        return []

    tags: set[str] = set()
    for r in reviews:
        if not isinstance(r, dict):
            continue
        text = r.get("text")
        if not isinstance(text, str):
            continue
        low = text.lower()
        for candidate in (
            "cozy",
            "lively",
            "quiet",
            "romantic",
            "casual",
            "date night",
            "pasta",
            "pizza",
            "sushi",
            "ramen",
            "tacos",
            "curry",
            "great wine",
            "great cocktails",
            "friendly",
            "fast",
        ):
            if candidate in low:
                tags.add(candidate.replace(" ", "-"))
    return sorted(tags)


def _review_tags_for_doc(doc: dict) -> list[str]:
    # Back-compat: if the field exists, honor it. Otherwise derive from reviews.
    review_tags = doc.get("reviewTags")
    if isinstance(review_tags, list):
        return [str(t) for t in review_tags]
    return _review_tags_from_reviews(doc.get("reviews"))


@dataclass(frozen=True)
class FakeEmbeddingConfig:
    dimensions: int = 256
    lowercase: bool = True
    min_token_length: int = 2


def tokenize(text: str, *, lowercase: bool = True, min_token_length: int = 2) -> list[str]:
    if lowercase:
        text = text.lower()

    tokens = _WORD_RE.findall(text)
    return [t for t in tokens if len(t) >= min_token_length]


def _stable_hash_bytes(value: str) -> bytes:
    return hashlib.sha256(value.encode("utf-8")).digest()


def fake_embed(text: str, *, config: FakeEmbeddingConfig = FakeEmbeddingConfig()) -> list[float]:
    if config.dimensions <= 0:
        raise ValueError("dimensions must be > 0")

    tokens = tokenize(text, lowercase=config.lowercase, min_token_length=config.min_token_length)
    if not tokens:
        return [0.0] * config.dimensions

    vec = [0.0] * config.dimensions

    for token in tokens:
        digest = _stable_hash_bytes(token)

        # Use first 8 bytes as an index.
        idx = int.from_bytes(digest[:8], "big") % config.dimensions
        vec[idx] += 1.0

    # L2 normalize
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
        vec = [v / norm for v in vec]

    return vec


def embedding_text_for_restaurant(doc: dict) -> str:
    # Location-forward embedding text: good for queries that include city/borough/zip.
    name = str(doc.get("name", ""))
    cuisine = str(doc.get("cuisine", ""))
    borough = str(doc.get("borough", ""))
    address = doc.get("address") or {}
    city = str(address.get("city", ""))
    zipcode = str(address.get("zipcode", ""))

    tags = doc.get("tags") or []
    if not isinstance(tags, list):
        tags = []

    review_tags = _review_tags_for_doc(doc)

    # Add a tiny bit of structure to encourage token overlap.
    return " ".join(
        p
        for p in (
            f"name {name}",
            f"cuisine {cuisine}",
            f"borough {borough}",
            f"city {city}",
            f"zipcode {zipcode}",
            f"tags {' '.join(str(t) for t in tags)}" if tags else "",
            f"reviewtags {' '.join(str(t) for t in review_tags)}" if review_tags else "",
        )
        if p.strip()
    )


def embedding_text_for_restaurant_semantic(doc: dict) -> str:
    """Semantic-forward embedding text for high similarity scores.

    Uses a compact, tag-like representation so cosine similarity can get very high
    (e.g., 0.8-1.0) for strong matches. This is better for demos where you filter
    by minimum score.
    """

    cuisine = str(doc.get("cuisine", ""))
    tags = doc.get("tags") or []
    if not isinstance(tags, list):
        tags = []

    review_tags = _review_tags_for_doc(doc)

    # Keep the token set small to avoid diluting cosine similarity.
    parts = [f"cuisine {cuisine}"] if cuisine else []

    tag_tokens = [str(t) for t in tags][:12]
    review_tag_tokens = [str(t) for t in review_tags][:12]

    if tag_tokens:
        parts.append("tags " + " ".join(tag_tokens))
    if review_tag_tokens:
        parts.append("reviewtags " + " ".join(review_tag_tokens))

    return " ".join(parts)


def embedding_text_for_restaurant_reviewtags(doc: dict) -> str:
    """Embedding text from reviewTags only.

    This produces very high cosine similarities when the query uses the same
    small vocabulary (e.g., "cozy romantic date night pasta"). Useful for demos
    that filter on a minimum score.
    """

    review_tags = _review_tags_for_doc(doc)

    # Keep token set small and unstructured.
    return " ".join(str(t) for t in review_tags[:16])


def embedding_text_for_restaurant_combined(doc: dict, *, style: str = "compact") -> str:
    """Single embedding-text builder used when storing a single vectorEmbedding.

    Styles:
    - compact: optimized for very high cosine similarity when query uses the same small vocabulary.
      Uses only derived review-tag tokens.
    - rich: includes structured location/cuisine/tags tokens for more general queries.
    """

    style = (style or "compact").strip().lower()
    if style == "compact":
        return embedding_text_for_restaurant_reviewtags(doc)
    if style == "rich":
        return embedding_text_for_restaurant(doc)
    raise ValueError("style must be 'compact' or 'rich'")

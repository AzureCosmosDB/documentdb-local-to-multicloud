import argparse
import json
import random
from datetime import UTC, datetime, timedelta
from pathlib import Path


CUISINES = [
    "Italian",
    "Chinese",
    "Mexican",
    "Indian",
    "Japanese",
    "Thai",
    "French",
    "Greek",
    "American",
    "Mediterranean",
]

CITIES = [
    "New York",
    "Seattle",
    "Austin",
    "Chicago",
    "Boston",
    "San Francisco",
    "Denver",
    "Atlanta",
]


NEIGHBORHOODS_BY_CITY = {
    "Seattle": ["Capitol Hill", "Ballard", "Fremont", "Belltown", "Queen Anne"],
    "Austin": ["South Congress", "East Austin", "Downtown", "Zilker", "The Domain"],
    "Chicago": ["The Loop", "Wicker Park", "Lincoln Park", "River North", "West Loop"],
    "Boston": ["Back Bay", "Seaport", "North End", "South End", "Cambridge"],
    "San Francisco": ["Mission", "SoMa", "Nob Hill", "Marina", "Hayes Valley"],
    "Denver": ["LoDo", "Capitol Hill", "RiNo", "Cherry Creek", "Highlands"],
    "Atlanta": ["Midtown", "Buckhead", "Old Fourth Ward", "Decatur", "Inman Park"],
}

STREETS = [
    "Main St",
    "Broadway",
    "Pine Ave",
    "Maple Dr",
    "Cedar St",
    "1st Ave",
    "2nd Ave",
    "Market St",
]

BOROUGHS = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"]


NAME_ADJECTIVES = [
    "Golden",
    "Silver",
    "Red",
    "Blue",
    "Green",
    "Lucky",
    "Happy",
    "Cozy",
    "Rustic",
    "Modern",
    "Classic",
    "Bright",
    "Hidden",
    "Little",
    "Grand",
]

NAME_NOUNS = [
    "Fork",
    "Spoon",
    "Table",
    "Kitchen",
    "Bistro",
    "Cafe",
    "Canteen",
    "Pantry",
    "Oven",
    "Garden",
    "Harbor",
    "Corner",
    "Market",
    "House",
]

CUISINE_WORDS = {
    "Italian": ["Trattoria", "Osteria", "Tavola"],
    "Chinese": ["Noodle House", "Dumpling Bar", "Tea House"],
    "Mexican": ["Cantina", "Taqueria", "Cocina"],
    "Indian": ["Spice House", "Tandoor", "Curry Kitchen"],
    "Japanese": ["Sushi Bar", "Ramen House", "Izakaya"],
    "Thai": ["Thai Kitchen", "Street Wok", "Curry House"],
    "French": ["Brasserie", "Boulangerie", "Bistro"],
    "Greek": ["Taverna", "Olive House", "Gyro Bar"],
    "American": ["Smokehouse", "Diner", "Grill"],
    "Mediterranean": ["Mezze", "Olive & Lemon", "Mediterranean Kitchen"],
}


AMBIENCE_TAGS = [
    "cozy",
    "casual",
    "family-friendly",
    "date-night",
    "lively",
    "quiet",
    "romantic",
    "modern",
    "classic",
]

SERVICE_TAGS = [
    "fast-service",
    "friendly-staff",
    "great-value",
    "great-cocktails",
    "good-for-groups",
    "takeout",
    "delivery",
]

FOOD_BY_CUISINE = {
    "Italian": ["pasta", "pizza", "risotto", "tiramisu"],
    "Chinese": ["dumplings", "noodles", "hot pot", "fried rice"],
    "Mexican": ["tacos", "burrito", "guacamole", "mole"],
    "Indian": ["curry", "naan", "biryani", "tikka"],
    "Japanese": ["sushi", "ramen", "tempura", "udon"],
    "Thai": ["pad thai", "green curry", "tom yum", "sticky rice"],
    "French": ["bistro", "croissant", "steak frites", "creme brulee"],
    "Greek": ["gyro", "souvlaki", "feta", "baklava"],
    "American": ["burger", "bbq", "wings", "mac and cheese"],
    "Mediterranean": ["hummus", "falafel", "shawarma", "salad"],
}

SENTIMENT_OPENERS = [
    "We loved",
    "We enjoyed",
    "Great",
    "Solid",
    "Pleasant",
    "Not bad",
]

SENTIMENT_CLOSERS = [
    "We would come back.",
    "Will be back soon.",
    "Highly recommend.",
    "Worth a visit.",
    "Good for a quick bite.",
    "Perfect for a date night.",
]


def _pick_tags(rng: random.Random, cuisine: str) -> list[str]:
    tags = set()
    tags.add(cuisine.lower())
    tags.add(rng.choice(AMBIENCE_TAGS))
    tags.add(rng.choice(SERVICE_TAGS))
    if rng.random() < 0.4:
        tags.add(rng.choice(AMBIENCE_TAGS))
    if rng.random() < 0.4:
        tags.add(rng.choice(SERVICE_TAGS))
    return sorted(tags)


def _make_reviews(rng: random.Random, cuisine: str, city: str, area: str) -> list[dict]:
    food_terms = FOOD_BY_CUISINE.get(cuisine, ["food"])
    featured_food = rng.choice(food_terms)
    ambience = rng.choice(["cozy", "lively", "quiet", "romantic", "casual"])
    service = rng.choice(["friendly", "fast", "attentive", "helpful"]) 

    count = 1 + (1 if rng.random() < 0.6 else 0) + (1 if rng.random() < 0.25 else 0)
    reviews: list[dict] = []
    base_days_ago = rng.randint(3, 1200)
    for i in range(count):
        rating = rng.choice([3, 4, 4, 5])
        days_ago = base_days_ago + i * rng.randint(7, 120)
        when = (datetime.now(UTC) - timedelta(days=days_ago)).isoformat(timespec="seconds").replace(
            "+00:00", "Z"
        )
        text = (
            f"{rng.choice(SENTIMENT_OPENERS)} the {featured_food}. "
            f"The vibe was {ambience} and the staff was {service}. "
            f"In {area}, {city}. {rng.choice(SENTIMENT_CLOSERS)}"
        )
        reviews.append({"date": when, "rating": rating, "text": text})
    return reviews


def _review_tags_from_reviews(reviews: list[dict]) -> list[str]:
    tags: set[str] = set()
    for r in reviews:
        if not isinstance(r, dict):
            continue
        t = r.get("text")
        if not isinstance(t, str):
            continue
        low = t.lower()
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


def _make_restaurant_name(
    rng: random.Random,
    *,
    cuisine: str,
    city: str,
    area: str,
    used_names: set[str] | None = None,
) -> str:
    cuisine_words = CUISINE_WORDS.get(cuisine, ["Kitchen"])

    def _two_distinct_nouns() -> tuple[str, str]:
        first = rng.choice(NAME_NOUNS)
        second = rng.choice([n for n in NAME_NOUNS if n != first])
        return first, second

    def _and_name() -> str:
        first, second = _two_distinct_nouns()
        return f"{first} & {second}"

    patterns = [
        lambda: f"The {rng.choice(NAME_ADJECTIVES)} {rng.choice(NAME_NOUNS)}",
        lambda: f"{rng.choice(NAME_ADJECTIVES)} {rng.choice(cuisine_words)}",
        _and_name,
        lambda: f"{rng.choice(NAME_ADJECTIVES)} {rng.choice(NAME_NOUNS)} {rng.choice(cuisine_words)}",
        lambda: f"{area} {rng.choice(cuisine_words)}" if area else "",
        lambda: f"{city} {rng.choice(cuisine_words)}",
    ]

    for _ in range(20):
        name = rng.choice(patterns)().strip()
        if not name:
            continue
        # Occasionally add a short, natural differentiator.
        if rng.random() < 0.20:
            name = f"{name} {rng.choice(['East', 'West', 'North', 'South'])}"
        if used_names is None or name not in used_names:
            if used_names is not None:
                used_names.add(name)
            return name

    # Fallback: force uniqueness.
    suffix = rng.randint(2, 99)
    name = f"{rng.choice(patterns)()} {suffix}"
    if used_names is not None:
        used_names.add(name)
    return name


def make_restaurant(i: int, *, used_names: set[str] | None = None) -> dict:
    random.seed(i)
    rng = random.Random(i)

    cuisine = rng.choice(CUISINES)
    city = rng.choice(CITIES)
    zipcode = f"{random.randint(10000, 99999)}"

    borough = rng.choice(BOROUGHS) if city == "New York" else ""
    neighborhood = ""
    if city != "New York":
        neighborhood = rng.choice(NEIGHBORHOODS_BY_CITY.get(city, ["Downtown"]))

    area = borough or neighborhood or city
    tags = _pick_tags(rng, cuisine)
    reviews = _make_reviews(rng, cuisine, city, area)

    name = _make_restaurant_name(
        rng,
        cuisine=cuisine,
        city=city,
        area=area,
        used_names=used_names,
    )

    # Construct in the desired key order.
    # For non-NY cities: neighborhood should come before address.
    # For NY: borough should come before address.
    doc: dict = {
        "name": name,
        "cuisine": cuisine,
    }

    if borough:
        doc["borough"] = borough
    else:
        doc["neighborhood"] = neighborhood

    doc["address"] = {
        "street": f"{random.randint(1, 9999)} {random.choice(STREETS)}",
        "city": city,
        "zipcode": zipcode,
    }
    doc["tags"] = tags
    doc["reviews"] = reviews
    doc["createdAt"] = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")

    return doc


def _reorder_restaurant_doc(doc: dict) -> dict:
    """Normalize key order for nicer-looking JSON output."""

    ordered: dict = {}
    for key in (
        "name",
        "cuisine",
        "borough",
        "neighborhood",
        "address",
        "tags",
        "reviews",
        "createdAt",
    ):
        if key in doc:
            ordered[key] = doc[key]

    # Preserve any unexpected keys (shouldn't happen, but keep deterministic output).
    for key in doc:
        if key not in ordered:
            ordered[key] = doc[key]

    return ordered


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a synthetic restaurants dataset for demos.")
    parser.add_argument("--count", type=int, default=500)
    parser.add_argument("--out", type=str, default=str(Path("data") / "restaurants.json"))
    parser.add_argument(
        "--hot-count",
        type=int,
        default=0,
        help=(
            "Number of documents to force into a single (cuisine, zipcode) cluster to make "
            "index/sort benefits obvious. Uses the first N documents."
        ),
    )
    parser.add_argument(
        "--hot-cuisine",
        type=str,
        default="Italian",
        help="Cuisine value to use for the hot cluster (default: Italian).",
    )
    parser.add_argument(
        "--hot-zipcode",
        type=str,
        default="10001",
        help="Zipcode value to use for the hot cluster (default: 10001).",
    )
    parser.add_argument(
        "--hot-borough",
        type=str,
        default="Manhattan",
        help="Borough value to use for the hot cluster (default: Manhattan).",
    )
    parser.add_argument(
        "--hot-city",
        type=str,
        default="New York",
        help="City value to use for the hot cluster (default: New York).",
    )
    args = parser.parse_args()

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    hot_count = max(0, min(args.hot_count, args.count))
    docs: list[dict] = []
    used_names: set[str] = set()
    for i in range(args.count):
        doc = make_restaurant(i + 1, used_names=used_names)
        if i < hot_count:
            doc["cuisine"] = args.hot_cuisine
            doc["borough"] = args.hot_borough
            # If this doc started life as a non-NY city, remove neighborhood.
            doc.pop("neighborhood", None)
            doc.setdefault("address", {})
            doc["address"]["zipcode"] = args.hot_zipcode
            doc["address"]["city"] = args.hot_city
            # Give the hot cluster varied, realistic names too (deterministic).
            hot_rng = random.Random((i + 1) * 99991)
            doc["name"] = _make_restaurant_name(
                hot_rng,
                cuisine=args.hot_cuisine,
                city=args.hot_city,
                area=args.hot_borough,
                used_names=used_names,
            )

            # Make the hot cluster feel natural for semantic-ish queries.
            # Keep it small and consistent.
            doc["tags"] = sorted(
                {
                    args.hot_cuisine.lower(),
                    "cozy",
                    "romantic",
                    "date-night",
                    "pasta",
                    "great-wine",
                }
            )
            doc["reviews"] = [
                {
                    "date": datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
                    "rating": 5,
                    "text": (
                        "Cozy romantic Italian spot perfect for date night. "
                        "Amazing pasta and great wine list in Manhattan. "
                        "We would come back."
                    ),
                }
            ]
        docs.append(_reorder_restaurant_doc(doc))

    out_path.write_text(json.dumps(docs, indent=2), encoding="utf-8")
    print(f"Wrote {len(docs)} documents to {out_path}")
    if hot_count:
        print(
            "Hot cluster:",
            {
                "count": hot_count,
                "cuisine": args.hot_cuisine,
                "zipcode": args.hot_zipcode,
                "borough": args.hot_borough,
                "city": args.hot_city,
            },
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

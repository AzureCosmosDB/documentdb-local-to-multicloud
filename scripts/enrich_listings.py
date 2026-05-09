#!/usr/bin/env python3
"""Generate displayName + city + country for listings."""
from __future__ import annotations
import json, re, sys
from pathlib import Path
import reverse_geocoder as rg

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "data" / "booking-agents_vectors.json"
DST = ROOT / "data" / "listings_vectors.json"
OVR = ROOT / "data" / "_displayname_overrides.json"
MAX_LEN = 35

PRESERVE = {
    "LoHi", "LoDo", "RiNo", "DTC", "DIA", "DU", "BR", "BA", "BD", "BDR",
    "BBQ", "TV", "AC", "Wifi", "WiFi", "MTN", "USA", "BR", "B&B", "B+B",
    "1BR", "2BR", "3BR", "4BR", "5BR", "1BD", "2BD", "3BD", "4BD",
}
PRESERVE_LOWER = {p.lower(): p for p in PRESERVE}

# stopwords kept lowercase mid-phrase (TitleCase keeps first word capitalized)
STOPWORDS = {
    "a", "an", "the", "in", "on", "at", "of", "for", "to", "and", "or",
    "with", "by", "near", "from", "into", "via", "but", "as",
}

DECORATIVE = re.compile(
    r"[★☀░❤♥♡✨🌟⭐♪♫]+|"
    r"[\U0001F300-\U0001FAFF]+|"
    r"[\U00002600-\U000027BF]+|"
    r"[\uFE00-\uFE0F]+|"  # variation selectors
    r"[\u200D\u200B\u200C]+",  # ZWJ/ZWSP
    re.UNICODE,
)

FILLER_PATTERNS = [
    r"\s*[-—–]?\s*\(?\s*(?:min(?:imum)?\s+)?\d+\s*[-+]?\s*(?:day|month|night)s?\+?\s*(?:rental|stay|only|or\s+more|or\s+longer)?\s*\)?",
    r"\s*\*+\s*min\s*\d+\s*day[^*]*\*?",
    r"\s*long[\s-]term\s+only",
    r"\s*~\s*30\s+days?\s+or\s+more",
    r"\s*\bwith\s+off[\s-]street\s+parking",
    r"\s*\bw/?\s*free\s+laundry",
    r"\s*\bno\s+cleaning\s+fee\b",
    r"\s*\bsleeps\s+\d+",
    r"\s*\b\d{4}-\w+-\d+\b",
    r"\s*\bvia\s+airport\s+train",
    r"\s*\b95\s+walk\s+score",
    r"\s*[-—–]\s*free\s+parking",
    r"\s*\b30\s*%\s*off",
    r"!+",
    r"\*+",
]
FILLER_RE = [re.compile(p, re.IGNORECASE) for p in FILLER_PATTERNS]

HARD_SPLIT = re.compile(r"\s*[:|]\s*|\s+[-—–]\s+|\s*\(|\s*\bw/", re.UNICODE)
TRAILING_FLUFF = re.compile(r"[\s!.,;:*+\-_/]+$")


def smart_titlecase(text: str) -> str:
    words = text.split()
    out = []
    for i, word in enumerate(words):
        m = re.match(r"^(\W*)(.*?)(\W*)$", word, re.DOTALL)
        pre, core, post = (m.group(1), m.group(2), m.group(3)) if m else ("", word, "")
        if not core:
            out.append(word)
            continue
        if core in PRESERVE:
            out.append(pre + core + post); continue
        if core.lower() in PRESERVE_LOWER:
            out.append(pre + PRESERVE_LOWER[core.lower()] + post); continue
        if core.isupper() and 2 <= len(core) <= 4:
            out.append(pre + core + post); continue
        if core.isdigit():
            out.append(pre + core + post); continue
        if core[0].isdigit():
            # alphanum starting with digit (1bed, 2x2)
            out.append(pre + core + post); continue
        # stopwords lowercase except first word
        if i > 0 and core.lower() in STOPWORDS:
            out.append(pre + core.lower() + post); continue
        # default title-case (preserve internal apostrophes)
        cased = core[:1].upper() + core[1:].lower()
        out.append(pre + cased + post)
    return " ".join(out)


def shorten(name: str) -> str:
    s = name
    s = DECORATIVE.sub(" ", s)
    s = s.replace("\u2019", "'").replace("\u2014", "-").replace("\u2013", "-")
    s = re.sub(r"&", " and ", s)
    for r in FILLER_RE:
        s = r.sub("", s)
    s = re.sub(r"\s+", " ", s).strip()
    parts = re.split(HARD_SPLIT, s, maxsplit=1)
    head = parts[0].strip() if parts else s
    head = TRAILING_FLUFF.sub("", head)
    head = re.sub(r"\s+", " ", head).strip()
    if not head or len(head) < 3:
        head = re.sub(r"[!*]+", "", s).strip() or name.strip()
    if len(head) > MAX_LEN:
        cut = head[:MAX_LEN]
        if " " in cut:
            cut = cut.rsplit(" ", 1)[0]
        head = cut
    head = TRAILING_FLUFF.sub("", head)
    # collapse trailing stopwords ("In The", "Of", etc.)
    while True:
        toks = head.split()
        if len(toks) >= 2 and toks[-1].lower() in STOPWORDS:
            head = " ".join(toks[:-1])
            head = TRAILING_FLUFF.sub("", head)
            continue
        break
    return smart_titlecase(head) or name[:MAX_LEN]


def main() -> int:
    listings = json.loads(SRC.read_text(encoding="utf-8"))
    print(f"Loaded {len(listings)} listings")
    overrides = {}
    if OVR.exists():
        overrides = json.loads(OVR.read_text(encoding="utf-8"))
        print(f"Loaded {len(overrides)} overrides")
    coords = [(float(x["latitude"]), float(x["longitude"])) for x in listings]
    print("Reverse-geocoding...")
    geo = rg.search(coords, mode=1)
    for x, g in zip(listings, geo):
        idstr = str(x["id"])
        x["displayName"] = overrides.get(idstr) or shorten(x["name"])
        x["city"] = g.get("name", "")
        x["admin1"] = g.get("admin1", "")
        x["country"] = g.get("cc", "")
    DST.write_text(json.dumps(listings, ensure_ascii=False), encoding="utf-8")
    print(f"Wrote {DST.name} ({DST.stat().st_size/1024/1024:.1f} MB)")
    review_path = ROOT / "data" / "_displayname_review.txt"
    with review_path.open("w", encoding="utf-8") as f:
        for x in listings:
            tag = "OVR" if str(x["id"]) in overrides else "   "
            f.write(f"{tag} [{x['id']:>10}] {x['displayName']:<35} <- {x['name']}\n")
    print(f"Review: {review_path}")
    print(f"Unique: {len({x['displayName'] for x in listings})}/{len(listings)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

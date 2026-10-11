#!/usr/bin/env python3
"""Ingest Book of Mormon verses (bcbooks/scriptures-json flat edition) into Postgres.

Usage:
    python3 ingest_bom.py --corpus corpus/bom-flat.json --db "dbname=scriptures user=scripture"

Idempotent: re-running replaces the 'bofm' work's verses.
Expected verse count: 6604 (checksum against known total).
"""

import argparse
import json
import re
import sys

import psycopg

REF_RE = re.compile(r"^(?P<book>.+) (?P<chapter>\d+):(?P<verse>\d+)$")
EXPECTED_VERSES = 6604

SCHEMA_SQL = open("db/schema.sql").read() if __name__ == "__main__" else ""


def parse_verses(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    rows = []
    for v in data["verses"]:
        m = REF_RE.match(v["reference"])
        if not m:
            raise ValueError(f"unparseable reference: {v['reference']!r}")
        text = v["text"].strip()
        if not text:
            raise ValueError(f"empty text: {v['reference']!r}")
        rows.append(
            (
                m.group("book"),
                int(m.group("chapter")),
                int(m.group("verse")),
                v["reference"],
                text,
            )
        )
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--db", default="dbname=scriptures")
    ap.add_argument("--schema", default="db/schema.sql")
    args = ap.parse_args()

    rows = parse_verses(args.corpus)
    if len(rows) != EXPECTED_VERSES:
        sys.exit(
            f"ABORT: verse count {len(rows)} != expected {EXPECTED_VERSES}; "
            "corpus may be corrupt or a different edition."
        )
    print(f"parsed {len(rows)} verses OK")

    with open(args.schema, encoding="utf-8") as f:
        schema_sql = f.read()

    with psycopg.connect(args.db, autocommit=True) as conn:
        conn.execute(schema_sql)
        conn.execute(
            "INSERT INTO works (code, title) VALUES ('bofm', 'Book of Mormon') "
            "ON CONFLICT (code) DO NOTHING"
        )
        work_id = conn.execute(
            "SELECT id FROM works WHERE code = 'bofm'"
        ).fetchone()[0]
        conn.execute("DELETE FROM verses WHERE work_id = %s", (work_id,))
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO verses (work_id, book, chapter, verse, reference, text) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                [(work_id, b, c, v, r, t) for (b, c, v, r, t) in rows],
            )
        count = conn.execute(
            "SELECT count(*) FROM verses WHERE work_id = %s", (work_id,)
        ).fetchone()[0]
    assert count == EXPECTED_VERSES, f"loaded {count}, expected {EXPECTED_VERSES}"
    print(f"loaded {count} verses into work_id={work_id}")


if __name__ == "__main__":
    main()

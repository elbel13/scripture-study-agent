#!/usr/bin/env python3
"""Semantic search over ingested verses.

Usage:
    python3 search.py --db "dbname=scriptures user=scripture" "verses about faith" [--k 5]
"""

import argparse
import json
import urllib.request

import psycopg

MODEL = "nomic-embed-text"
OLLAMA_URL = "http://localhost:11434/api/embed"


def embed_query(q):
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps({"model": MODEL, "input": q}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)["embeddings"][0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("query")
    ap.add_argument("--db", default="dbname=scriptures")
    ap.add_argument("--k", type=int, default=5)
    args = ap.parse_args()

    qvec = embed_query(args.query)
    with psycopg.connect(args.db) as conn:
        rows = conn.execute(
            "SELECT reference, text, embedding <=> %s AS distance "
            "FROM verses WHERE embedding IS NOT NULL "
            "ORDER BY embedding <=> %s LIMIT %s",
            (json.dumps(qvec), json.dumps(qvec), args.k),
        ).fetchall()
    for ref, text, dist in rows:
        print(f"[{dist:.4f}] {ref}\n  {text[:220]}\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate embeddings for verses missing them, via Ollama (nomic-embed-text).

Usage:
    python3 embed.py --db "dbname=scriptures user=scripture" [--batch 32]

Embeds "reference: text" so the reference participates in retrieval.
"""

import argparse
import json
import urllib.request

import psycopg

MODEL = "nomic-embed-text"
OLLAMA_URL = "http://localhost:11434/api/embed"


def embed_batch(texts):
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps({"model": MODEL, "input": texts}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.load(resp)["embeddings"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="dbname=scriptures")
    ap.add_argument("--batch", type=int, default=32)
    args = ap.parse_args()

    with psycopg.connect(args.db, autocommit=True) as conn:
        rows = conn.execute(
            "SELECT id, reference, text FROM verses "
            "WHERE work_id = (SELECT id FROM works WHERE code='bofm') "
            "AND embedding IS NULL ORDER BY id"
        ).fetchall()
        total = len(rows)
        print(f"{total} verses need embeddings")
        for i in range(0, total, args.batch):
            chunk = rows[i : i + args.batch]
            texts = [f"{r}: {t}" for (_, r, t) in chunk]
            embs = embed_batch(texts)
            with conn.cursor() as cur:
                cur.executemany(
                    "UPDATE verses SET embedding = %s WHERE id = %s",
                    [(json.dumps(e), vid) for (_, _, _), e, (vid, _, _) in
                     zip(chunk, embs, chunk)],
                )
            done = min(i + args.batch, total)
            print(f"  embedded {done}/{total}", flush=True)

        remaining = conn.execute(
            "SELECT count(*) FROM verses WHERE embedding IS NULL"
        ).fetchone()[0]
    print(f"done, {remaining} verses still missing embeddings")


if __name__ == "__main__":
    main()

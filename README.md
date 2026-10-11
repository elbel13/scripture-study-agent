# Scripture Study Agent

Semantic search and study tooling over the LDS standard works, built on
Postgres + pgvector. An agent (not just a skill): scripture text is embedded
verse-by-verse, with study helps (footnotes, Topical Guide, Bible Dictionary,
Guide to the Scriptures) indexed alongside for cross-reference traversal.

**Code only — no corpus data is committed.** The setup script downloads
scripture text from churchofjesuschrist.org (via the public-domain
[bcbooks/scriptures-json](https://github.com/bcbooks/scriptures-json) corpus)
at install time, so every user builds their own private copy.

## Phase 1 (in progress): Book of Mormon semantic search spike

- `db/schema.sql` — works/verses tables, pgvector HNSW index, tsvector for hybrid search later
- `ingest/ingest_bom.py` — loads all 6,604 BoM verses (checksum-verified against known count)
- `ingest/embed.py` — verse embeddings via local Ollama (`nomic-embed-text`), reference-prefixed
- `search/search.py` — cosine-similarity search CLI

## Setup (Phase 1)

```bash
# Postgres 16 + pgvector, then:
createdb scriptures
psql scriptures < db/schema.sql   # as a superuser for CREATE EXTENSION vector
# download corpus (not committed):
curl -sL -o corpus/bom-flat.json \
  https://raw.githubusercontent.com/bcbooks/scriptures-json/master/flat/book-of-mormon-flat.json
python3 ingest/ingest_bom.py --corpus corpus/bom-flat.json --db "dbname=scriptures"
# embeddings (Ollama with nomic-embed-text):
python3 ingest/embed.py --db "dbname=scriptures"
# search:
python3 search/search.py --db "dbname=scriptures" "verses about faith"
```

## Roadmap

1. ✅/🔄 Phase 1 — BoM semantic search spike
2. Phase 2 — full corpus: KJV Bible, D&C, Pearl of Great Price
3. Phase 3 — study helps: footnotes/cross-references, Topical Guide, Bible Dictionary, Guide to the Scriptures
4. Phase 4 — agent skills: search, cross-references, topical study, guided study sessions

# Phase 1 Report: Book of Mormon Semantic Search Spike

**Date:** 2026-10-11
**Status:** Complete — retrieval quality verified
**Budget:** token usage went from 28% → 29% of weekly limit (ceiling was 35%)

## What was built

Postgres 16 + pgvector (0.6.0) with a verse-level embedding index over the
entire Book of Mormon. Schema: `works` / `verses` tables, 768-dim
`vector` column (nomic-embed-text), HNSW cosine index, plus a `tsvector`
column pre-built for hybrid lexical+semantic search later.

- **Corpus:** [bcbooks/scriptures-json](https://github.com/bcbooks/scriptures-json)
  flat edition (public domain, 2013 text). Chosen over two alternatives for
  cleanliness: every reference parses as `Book Chapter:Verse`, zero empty
  texts, all 15 books present.
- **Ingest:** `ingest/ingest_bom.py` — idempotent, aborts unless exactly
  **6,604** verses parse (checksum against known total). All 6,604 loaded.
- **Embeddings:** `ingest/embed.py` — local Ollama, `nomic-embed-text`
  (f16 GGUF from HuggingFace; `ollama pull` is blocked by this VM's egress
  proxy, so the model file was fetched directly and registered via
  `ollama create`). Each verse embedded as `"Reference: text"` so the
  citation participates in retrieval. 6,604/6,604 embedded, 0 missing.
- **Search:** `search/search.py` — cosine nearest-neighbor CLI.

Total wall clock: ~2.5 hours. Money spent: $0 (local embeddings, existing hardware).

## Verification: 5/5 queries hit the canonical verses

| Query | Top hit |
|---|---|
| verses about faith | Alma 32:21 (the faith definition) |
| spiritual rebirth being born again | Mosiah 27:24–25 (Alma the Younger) |
| what happens to the soul after death | Alma 40:21, 40:7 (spirit world) |
| enduring to the end pressing forward | 2 Nephi 31:20 (the endure-to-the-end verse) |
| Nephi vision of the tree of life | 1 Nephi 15:22, 11:25 |

## Key technical finding: pgvector HNSW recall

The default `hnsw.ef_search=40` **missed the true nearest neighbor** on one
query (returned Alma 34:41 at distance 0.3713 while 2 Nephi 31:20 sat at
0.3483 — confirmed against an exact sequential scan). Raising
`hnsw.ef_search` to 100+ finds the true nearest on every test query.
`search.py` now sets `hnsw.ef_search = 100` per session. Worth remembering
when the corpus grows to ~41k verses in Phase 2: verify recall against
exact scan whenever index parameters or scale change.

## Blockers hit and resolutions

- No Docker on the VM → native `apt` install of postgres + pgvector.
- A dead Ubuntu mirror (`mirror.cogentco.com`) hung `apt-get update` → removed it from sources.
- `ollama pull` blocked by egress proxy (redirect to non-public IP refused) →
  GGUF downloaded from HuggingFace over HTTPS, registered with `ollama create`.
- The Ollama systemd service lacked proxy env vars → running `ollama serve`
  directly (documented; systemd unit needs env fix for persistence).
- GitHub App cannot create repos (403) → repo created manually; code pushed
  via the integration's `push_files`.

## Recommendation

**Proceed.** The core thesis is proven: verse-level embeddings over scripture
give genuinely good semantic retrieval, the pipeline is idempotent and
checksum-guarded, and the whole spike cost 1 point of token budget and $0.
Phase 3 (footnote/topical-guide scraping) remains the highest-risk phase —
that's the next real unknown to de-risk.

#!/usr/bin/env python3
"""
CS528 HW7 — Apache Beam + Dataflow (or DirectRunner locally)

Reads JSON page files from GCS (same format as HW2: page_id + outgoing_links).
  - Top 5 files by outgoing link count
  - Top 5 files by incoming link count
  - Top 5 most frequent word bigrams in raw file text (alphanumeric tokens)

Usage (local, HW2 JSON under hw7/pages):
  python pipeline.py \\
    --runner DirectRunner \\
    --input_glob /path/to/cs528/hw7/pages/*.json

  Or: bash run_local.sh   # uses ./pages/*.json inside hw7/

Usage (Dataflow):
  python pipeline.py \\
    --runner DataflowRunner \\
    --project YOUR_PROJECT \\
    --region us-central1 \\
    --temp_location gs://BUCKET/tmp/beam \\
    --staging_location gs://BUCKET/staging \\
    --input_glob gs://BUCKET/pages/*.json \\
    --requirements_file requirements.txt

Environment:
  GOOGLE_APPLICATION_CREDENTIALS or gcloud auth application-default login
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from typing import Iterator, List, Tuple

import apache_beam as beam
from apache_beam.io import fileio
from apache_beam.options.pipeline_options import PipelineOptions, SetupOptions
from apache_beam.transforms import combiners


def read_file_utf8(readable_file: object) -> Tuple[str, str]:
    """Return (path, full_text) for each matched file."""
    path = readable_file.metadata.path
    try:
        text = readable_file.read_utf8()
    except Exception:
        return path, ""
    return path, text


def parse_page_json(kv: Tuple[str, str]) -> Iterator[Tuple[str, List[str], str]]:
    """Emit (page_id, outgoing_links, raw_text) — skip bad JSON."""
    _path, text = kv
    text = text.strip()
    if not text:
        return
    try:
        data = json.loads(text)
        page_id = data.get("page_id", "")
        links = data.get("outgoing_links") or []
        if isinstance(links, list):
            yield (page_id, [str(x) for x in links], text)
    except json.JSONDecodeError:
        return


def outgoing_count(el: Tuple[str, List[str], str]) -> Iterator[Tuple[str, int]]:
    page_id, links, _ = el
    if page_id:
        yield (page_id, len(links))


def incoming_links(el: Tuple[str, List[str], str]) -> Iterator[Tuple[str, int]]:
    """Each outgoing link increments incoming count for target."""
    _page_id, links, _ = el
    for target in links:
        if target:
            yield (target, 1)


def word_bigrams(el: Tuple[str, List[str], str]) -> Iterator[Tuple[str, int]]:
    """Word bigrams from raw file text (alphanumeric tokens, lowercased)."""
    _page_id, _links, text = el
    words = re.findall(r"[a-zA-Z0-9]+", text.lower())
    for i in range(len(words) - 1):
        pair = f"{words[i]} {words[i + 1]}"
        yield (pair, 1)


def format_top5_outgoing(rows: List[Tuple[str, int]]) -> str:
    lines = ["=== Top 5 files by OUTGOING link count ==="]
    for rank, (page_id, n) in enumerate(sorted(rows, key=lambda x: -x[1])[:5], 1):
        lines.append(f"  {rank}. {page_id}  ({n} outgoing)")
    return "\n".join(lines)


def format_top5_incoming(rows: List[Tuple[str, int]]) -> str:
    lines = ["=== Top 5 files by INCOMING link count ==="]
    for rank, (page_id, n) in enumerate(sorted(rows, key=lambda x: -x[1])[:5], 1):
        lines.append(f"  {rank}. {page_id}  ({n} incoming)")
    return "\n".join(lines)


def format_top5_bigrams(rows: List[Tuple[str, int]]) -> str:
    lines = ["=== Top 5 word bigrams (raw file text) ==="]
    for rank, (bigram, n) in enumerate(sorted(rows, key=lambda x: -x[1])[:5], 1):
        lines.append(f"  {rank}. \"{bigram}\"  ({n})")
    return "\n".join(lines)


def build_and_run(argv: List[str] | None = None) -> float:
    """Run pipeline and return elapsed wall seconds (driver)."""
    parser = argparse.ArgumentParser(description="HW7 Beam: links + bigrams")
    parser.add_argument(
        "--input_glob",
        required=True,
        help="GCS glob, e.g. gs://my-bucket/pages/*.json",
    )
    parser.add_argument(
        "--requirements_file",
        default=None,
        help="For Dataflow workers (path to requirements.txt)",
    )
    known_args, pipeline_args = parser.parse_known_args(argv)

    options = PipelineOptions(pipeline_args)
    setup_options = options.view_as(SetupOptions)
    if known_args.requirements_file:
        setup_options.requirements_file = known_args.requirements_file

    t0 = time.perf_counter()

    def fmt_out(rows: List[Tuple[str, int]]) -> str:
        return format_top5_outgoing(rows)

    def fmt_in(rows: List[Tuple[str, int]]) -> str:
        return format_top5_incoming(rows)

    def fmt_bi(rows: List[Tuple[str, int]]) -> str:
        return format_top5_bigrams(rows)

    with beam.Pipeline(options=options) as pipeline:
        files = pipeline | "MatchFiles" >> fileio.MatchFiles(known_args.input_glob)
        contents = files | "ReadMatches" >> fileio.ReadMatches()
        parsed = (
            contents
            | "ReadUTF8" >> beam.Map(read_file_utf8)
            | "ParseJSON" >> beam.FlatMap(parse_page_json)
        )

        out_counts = parsed | "OutgoingCounts" >> beam.FlatMap(outgoing_count)
        top_out = out_counts | "Top5Outgoing" >> combiners.Top.Largest(
            5, key=lambda x: x[1]
        )

        incoming = parsed | "IncomingEdges" >> beam.FlatMap(incoming_links)
        in_per_page = incoming | "SumIncoming" >> beam.CombinePerKey(sum)
        top_in = in_per_page | "Top5Incoming" >> combiners.Top.Largest(
            5, key=lambda x: x[1]
        )

        bi = parsed | "BigramPairs" >> beam.FlatMap(word_bigrams)
        bi_counts = bi | "CountBigrams" >> beam.CombinePerKey(sum)
        top_bi = bi_counts | "Top5Bigrams" >> combiners.Top.Largest(
            5, key=lambda x: x[1]
        )

        s1 = top_out | "Fmt_out" >> beam.Map(fmt_out)
        s2 = top_in | "Fmt_in" >> beam.Map(fmt_in)
        s3 = top_bi | "Fmt_bi" >> beam.Map(fmt_bi)

        merged = (s1, s2, s3) | beam.Flatten()
        merged | "PrintAll" >> beam.Map(lambda s: print(s, flush=True) or s)

    elapsed = time.perf_counter() - t0
    return elapsed


if __name__ == "__main__":
    sec = build_and_run(sys.argv[1:])
    print(f"\n=== Wall time (pipeline context exit): {sec:.3f} s ===", flush=True)

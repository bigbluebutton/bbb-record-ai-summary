# AI Summary Recording Format — Architecture & Code Audit

**Date:** 2026-07-07
**Scope:** All source under `src/` (process, publish, post-archive, post-publish, transcription providers, LLM client, templates), packaging (`debian/`, `deploy.sh`), and nginx config — ~5,100 lines reviewed in full.

---

## Executive Summary

The pipeline is well-structured overall: clean stage separation, a sensible provider abstraction for both transcription and LLMs, deep-merged operator overrides, and thoughtful accuracy work (talking-cue chunking, VAD hallucination filtering, quality metrics). The most serious problems are in three areas:

1. **Failure handling** — transcription and processing failures are silently converted into "success" states that permanently poison a recording (empty canonical transcript that is never retried; a `.done` status written for incomplete output). Provider error output is discarded, so these failures are also invisible.
2. **Output safety** — the published HTML report interpolates user-controlled content (attendee names, poll answers, LLM output) without escaping: a stored-XSS vector on the BBB domain. Meeting metadata — including a Docs access token when that flow is used — is copied verbatim into the publicly served `metadata.xml`.
3. **Accuracy ceilings** — real segment timestamps are discarded and re-interpolated, the detected language is thrown away, the Albert provider produces one coarse segment per chunk, and the LLM layer has no context budgeting, no truncation detection, and no retries.

**Top 5 actions:** (1) HTML-escape all template interpolations; (2) make transcription failures fail loudly and not write the canonical JSON; (3) fix the process-stage re-run `.done` bug; (4) ship `whisper_cpp.rb` in the Debian package (the fallback path is broken for package installs); (5) capture provider stderr into the logs.

---

## Prioritized Improvements

| # | Priority | Area | Finding |
|---|----------|------|---------|
| 1 | **P0** | Security | Stored XSS in published HTML report (unescaped ERB) |
| 2 | **P0** | Reliability | Failed/partial transcription writes canonical JSON and is never retried |
| 3 | **P0** | Reliability | Process re-run writes `.done` for incomplete output |
| 4 | **P1** | Packaging | Debian package omits `whisper_cpp.rb` — fallback backend broken |
| 5 | **P1** | Observability | Provider stdout/stderr discarded to `/dev/null` |
| 6 | **P1** | Transcription | `known_speaker_names[]` sent to `whisper-1` — likely rejected, silently |
| 7 | **P1** | Security | Meeting metadata (incl. Docs access token) published in public `metadata.xml` |
| 8 | **P1** | AI accuracy | No LLM input budgeting, truncation detection, or retry |
| 9 | **P1** | Transcription | Albert provider: one coarse segment per chunk, timestamps skewed by pull-back |
| 10 | **P2** | Transcription | Real segment timestamps discarded by char-ratio interpolation |
| 11 | **P2** | Transcription | Detected language discarded; summary language hint often missing |
| 12 | **P2** | Transcription | Whisper prompt used as instructions, not vocabulary priming; no rolling context |
| 13 | **P2** | Transcription | whisper.cpp fallback picks English-only model with `-l auto`; `whisper_threads` dead |
| 14 | **P2** | AI accuracy | Action-items call: conflicting prompts, injection-friendly ordering, fragile JSON parsing |
| 15 | **P2** | Security | LaTeX/raw-TeX injection into `pandoc --pdf-engine=xelatex`; shell-string command |
| 16 | **P2** | Architecture | VTT round-trip: cues serialized to text then re-parsed with a fragile parser |
| 17 | **P2** | Reliability | Meetings without transcript hard-fail the whole format |
| 18 | **P2** | Transcription | Chunks >25 MB skipped whole; `merge_nearby_cues` can shrink intervals; ÷0 in quality score |
| 19 | **P3** | Architecture | 1,487-line process monolith; zero automated tests |
| 20 | **P3** | Cleanup | Dead config, stale comments, doc drift, `rescue Exception`, default meeting-id placeholder |

---

## P0 — Critical

### 1. Stored XSS in the published HTML report

`ai-summary.html.erb` uses plain ERB, which does **not** HTML-escape `<%= %>`. These interpolations render user-controlled content raw:

- Attendee names (`<li><%= name %></li>`, line 134) — any participant's join name
- `@title` / `@subtitle` (lines 76–77; subtitle includes the attendee list)
- Poll questions and answers (lines 149, 152) — typed by users
- Action-item `owner`/`label` (line 208) and the plain `@summary` fallback (line 194) — LLM output derived from untrusted meeting content
- `@shared_notes` (line 122) — intentionally raw HTML, but "sanitization" in `NotesExtractor` (process/ai-summary.rb:346) only strips `html/body` CSS rules, not `<script>`/event handlers

A participant who joins as `<img src=x onerror=...>` gets persistent script execution on the BBB origin for every viewer of the report. The client-side JS renderer escapes correctly (`escHtml`, JSON `</`-escaping) — only the server-rendered ERB is exposed.

**Fix:** wrap every interpolation with `ERB::Util.html_escape` (or switch to `ERB.new(..., trim_mode: '-')` plus an `h()` helper convention). Sanitize `@shared_notes` with a real allowlist sanitizer (Nokogiri-based: drop `script/style/iframe/on*` attributes) rather than a CSS regex. The Markdown and BlockNote-JSON templates are lower risk (plain text nodes / escaped by `to_json`) but the md → pandoc path has its own issue (#15).

### 2. Transcription failures are silently permanent

Several layers conspire to turn transient API failures into a permanently empty transcript:

- `openai_whisper.rb` returns an **empty result per chunk** on any API error (line 119–122, 153–155) and still exits 0. A full API outage produces `"transcription": []` with exit 0.
- `transcribe_audio.rb` writes the canonical `transcription.json` regardless of track success (`run_provider_transcription`, line 356–375) — even when every track has `ok: false`.
- On the next run, the early-exit guard (line 450–453) sees `transcription.json` exists and skips. There is no automatic retry path; the operator must know to delete the file.
- `quality_metrics.coverage_ratio` is computed but nothing acts on it.

**Fix:**
- In providers: track chunk-level failures and exit non-zero when a meaningful fraction of chunks failed (this engages the existing retry loop in `attempt_transcription`).
- In `transcribe_audio.rb`: don't write the canonical file when `ok_count == 0` (or write `transcription.json.fail` instead), and exit non-zero so the failure is visible in the pipeline.
- Consider acting on `coverage_ratio` — e.g. warn below 0.9, fail below a configurable floor.

### 3. Process-stage re-run marks incomplete output as done

`process/ai-summary.rb:1276` — the whole stage is guarded by `unless FileTest.directory?(target_dir)`. `mkdir_p target_dir` happens at line 1281, *before* any extraction. If the script crashes mid-run (LLM error, template bug, OOM), `target_dir` exists with partial content; the next invocation takes the `else` branch (line 1486) and writes the `.done` status file without doing any work. The publish stage then publishes whatever half-finished artifacts exist.

**Fix:** treat an existing `target_dir` without a `.done` file as a stale crash — delete and reprocess. Alternatively, build in a temp dir and atomically rename to `target_dir` on success.

---

## P1 — High

### 4. Debian package breaks the whisper.cpp fallback

`resolve_active_backends` (transcribe_audio.rb:298–313) falls back to `/usr/local/bigbluebutton/core/lib/transcription/whisper_cpp.rb`, but `debian/rules` installs only `transcription_utils.rb`, `openai_whisper.rb`, and `albert_whisper.rb`. A package install with no `transcriber_path` configured logs "whisper_cpp.rb not found" and exits 0 → no transcription → process stage exits 1 → the format never publishes. The five `openai_whisper_*` scenario wrappers are also unpackaged, so `transcriber_path` pointing at them (as their headers suggest) fails on package installs. `deploy.sh` copies `*.rb` and doesn't have this problem — classic deploy/package drift.

**Fix:** install `whisper_cpp.rb` and the scenario wrappers in `debian/rules` (755). Add a CI check that the file sets in `deploy.sh` and `debian/rules` match.

### 5. Provider diagnostics are discarded

`CustomScriptBackend#transcribe` spawns providers with `[:out, :err] => '/dev/null'` (transcribe_audio.rb:156–157). `albert_whisper.rb` and `whisper_cpp.rb` write their own log files, but `openai_whisper.rb` logs **only to stderr** — every API error message, chunk count, and quality note vanishes in production. Combined with #2, an operator sees "transcription complete, 0 segments" with no way to learn why.

**Fix:** capture child output into the transcription log (spawn with a pipe or redirect to a per-provider log file), or give `openai_whisper.rb` the same file logger the other two providers have.

### 6. `known_speaker_names[]` with `whisper-1` — verify before trusting the scenario wrappers

`openai_whisper.rb` hardcodes `MODEL = 'whisper-1'` (line 46) but sends `known_speaker_names[]` form fields (lines 103–105). That parameter belongs to OpenAI's diarizing transcription models (`gpt-4o-transcribe-diarize`), not `whisper-1`, and the API typically rejects unknown parameters with a 400. All five scenario wrappers set `WHISPER_KNOWN_SPEAKER_NAMES` by default (e.g. `openai_whisper_main.rb`), so if the API rejects it, **every chunk of every scenario-wrapper run fails** — silently, because of #5. Even if accepted, `whisper-1` performs no diarization, so the parameter buys nothing; per-track speaker mapping already comes from events.xml.

**Fix:** test one request; either drop the parameter for `whisper-1`, or make the model configurable and only send diarization fields for models that support them.

### 7. Secrets and metadata leak into the published `metadata.xml`

`build_metadata_xml` (process/ai-summary.rb:1208–1212) copies **all** meeting metadata into `metadata.xml`, which is published under `/var/bigbluebutton/published/ai-summary/<id>/` and served by the nginx block with no access control. Two concrete leaks:

- `meta_la-suite-numerique-docs-access-token` (a bearer token, per `publish_to_docs.rb:193`) becomes world-readable.
- `meta_bbb-ai-summary-prompt-addition` exposes internal prompt instructions.

**Fix:** filter metadata keys before writing (`reject { |k,_| k.start_with?('la-suite') || k == 'bbb-ai-summary-prompt-addition' }` or an allowlist). Longer term, drop the pass-a-token-via-meeting-metadata pattern entirely — metadata is also visible via `getRecordings` to any API consumer.

### 8. LLM layer: no budgeting, no truncation detection, no retries

`llm_client.rb`:

- **Input:** the full notes + transcript + polls + chat blob is sent in one request (`SummaryExtractor`, process/ai-summary.rb:881–907). A 3-hour multi-speaker meeting can exceed model context (especially `gpt-4o-mini`'s 128k or smaller Albert models) → hard API error → summary silently `nil`.
- **Output:** `max_tokens` defaults to 1024 and `stop_reason`/`finish_reason` is never checked — long summaries truncate mid-sentence with no warning. Action-item JSON that truncates fails parsing and returns `[]`.
- **Transport:** no retry on 429/5xx/timeouts (a single rate-limit kills the summary); no explicit `read_timeout` (default 60 s is tight for big prompts); `rescue Net::HTTPError` catches a class that Net::HTTP rarely raises — non-2xx Claude/OpenAI responses are only caught by the JSON `error` key check, and an HTML error page would raise an unhandled `JSON::ParserError`.

**Fix (in order of value):** (a) check stop/finish reason and log/retry with higher `max_tokens` (raise the default — 1024 tokens is small for a meeting summary); (b) add bounded retries with backoff for 429/5xx; (c) estimate input size (chars/4) and switch to a map-reduce path — summarize transcript windows, then summarize the summaries — above the threshold; (d) set explicit timeouts and check `response.is_a?(Net::HTTPSuccess)` in Claude/OpenAI clients (Albert already does).

### 9. Albert provider: coarse, skewed timestamps

`albert_whisper.rb:312` emits **one segment per chunk** spanning `from_ms..to_ms`:

- `from_ms` includes the 1-second pull-back added in `prepare_audio_chunks` (transcription_utils.rb:310), so every Albert segment starts up to 1 s early. OpenAI/whisper.cpp are unaffected because they add within-chunk API offsets.
- With the floor-cue fallback (no talking events), the merged chunk can be the entire recording → a single segment covering the whole meeting; downstream cue-splitting then invents timestamps by character ratio (#10).

**Fix:** request `verbose_json` from Albert (it fronts `whisper-large-v3`; if segment timestamps are available, use them with `chunk_offset_ms` exactly like the OpenAI provider). At minimum, record `cue['from']` (pre-pull-back) as the segment start.

---

## P2 — Accuracy and robustness improvements

### 10. Real timestamps are discarded when long cues are split

`collect_cues` (process/ai-summary.rb:693–736) joins all texts of a same-speaker run, then re-splits at sentence boundaries and assigns timestamps by **character-ratio linear interpolation** — even though each contributing segment carried a real `abs_start`/`abs_end`. For slow/fast speech the interpolated times drift badly. **Fix:** split at original segment boundaries (accumulate segments into cue groups instead of concatenated text), only interpolating within a single oversized segment.

### 11. Detected language is thrown away

`openai_whisper.rb:364` writes `language` only when it was *configured*; the `verbose_json` response's detected `language` field is ignored. `whisper_cpp.rb` and `albert_whisper.rb` (auto mode) report none. Consequently `transcript[:language]` is usually `nil` and the summary prompt gets no language hint — for non-English meetings the summary language then depends on LLM guessing (mitigated only if `llm.language` is set). **Fix:** capture `data['language']` per chunk, take the majority across chunks/tracks, and propagate it. This also enables a useful cross-check: chunks whose detected language differs from the majority are frequently hallucinations.

### 12. Whisper prompt misuse; no rolling context

The scenario wrappers inject instruction-style prompts — `"Meeting participant Alice speaking. This is their individual microphone audio…"` (openai_whisper_main.rb, _contextual.rb:60–62). Whisper's `prompt` is decoder priming (treated as preceding transcript), not instructions: instruction text does not steer behavior, biases the decoder toward meta-language, and occasionally **leaks verbatim into the output** on silent-ish chunks. Meanwhile the one thing prompt priming is documented to do well — carrying context across chunks — isn't used: each chunk is transcribed cold, so terminology established early in the meeting doesn't help later chunks, and sentences split across chunk boundaries lose coherence.

**Fix:** prompt with vocabulary only (names + `context_prompt` terms, comma-separated, no sentences), and append the tail (~200 chars) of the previous chunk's transcription to the prompt for each subsequent chunk of the same track.

### 13. whisper.cpp fallback model/threads

`whisper_cpp.rb:82–83` prefers `ggml-base.en.bin`, else the **smallest** model found, and always passes `-l auto`. An English-only model with auto language detection produces garbage for non-English audio, and "smallest available" is the worst accuracy choice. There is also no `-t` flag even though `ai-summary.yml` documents a `whisper_threads: 4` setting (dead config). **Fix:** prefer multilingual models when a language other than English is configured/detected; pass `-l <lang>` from the same config chain the other providers use; wire `whisper_threads` through or delete the key.

### 14. Action-item extraction is fragile and injection-friendly

`ActionItemsExtractor` (process/ai-summary.rb:925–1022):

- The "respond with JSON only" hard override sits **before** the untrusted transcript/chat content (line 970 vs. 972), so meeting content gets the last word — the opposite of the stated design. Untrusted content is also un-delimited, so "ignore previous instructions" in a chat message lands directly in the prompt.
- The user prompt fights the summarization **system prompt** (both are applied — `llm_client.summarize` always prepends the summary system prompt, which instructs prose output).
- Parsing strips markdown fences with a regex that misses common shapes (leading text, `~~~` fences) and any failure returns `[]` indistinguishable from "no action items".
- Minor: `action_items.json` saves the raw LLM keys (`task` vs `label`), not the normalized structure the template uses.

**Fix:** give the action-items call its own system prompt; wrap untrusted content in explicit delimiters (`<meeting_content>…</meeting_content>`) with the JSON-only instruction after them; use the provider's structured-output mechanism where available (Claude tool-use / OpenAI `response_format: json_schema`) instead of string parsing; save the normalized array.

### 15. Pandoc/LaTeX injection and shell string

`publish/ai-summary.rb:76` builds a shell string (`pandoc '#{source_md}' …`) — fine for BBB-generated IDs today, but fragile; use the array form of `system`. More substantively, meeting content (notes, chat, transcript) flows into markdown rendered by `--pdf-engine=xelatex` with raw TeX enabled by default: `\input{/etc/passwd}` in shared notes embeds server files into the published PDF. **Fix:** `pandoc -f markdown-raw_tex` (or `-f gfm`) plus `--sandbox`.

### 16. VTT round-trip architecture

The process stage serializes cues to a WebVTT string, then immediately re-parses that string with a hand-rolled parser to get cues back (`WebVTTParser.parse(transcript_diarized)`, process/ai-summary.rb:1314). The parser splits speaker/text on the first `:` — a speaker display name containing a colon shifts text into the name, and the `rescue` at line 97 silently returns `[]` (transcript disappears from the report with no log). **Fix:** return the cue array from `TranscriptExtractor.extract` alongside the VTT string and delete the parser; it exists only to undo the serialization.

### 17. No graceful degradation without a transcript

If transcription produced nothing (silent meeting, all-failed provider, no audio), the process stage exits 1 (process/ai-summary.rb:1301–1304) and the recording gets **no ai-summary format at all**, even when notes, polls, and chat exist and would make a useful report. **Fix:** make the transcript optional — render the report with the sections that exist and a "no transcript available" notice; only fail when there is literally nothing to publish.

### 18. Chunking edge cases

- **Oversized chunks:** >25 MB (≈13 min of continuous speech at 16 kHz mono PCM) are skipped entirely (openai_whisper.rb:90–92) — that speech is simply absent from the transcript. Split into sub-chunks instead (or encode chunks as OGG/Opus, which cuts size ~10× and stays within API-supported formats).
- **`merge_nearby_cues`** (transcription_utils.rb:171–184): `merged.last['to'] = curr['to']` without `max()` — a cue contained inside the previous one *shrinks* the merged interval. Use `[merged.last['to'], curr['to']].max`.
- **Quality score ÷0:** `(1.0 / compression_ratio)` (openai_whisper.rb:139) is `Infinity` when the field is missing/0 → segment always passes. Guard the denominator.
- The 1-second pull-back overlaps consecutive chunks when the inter-cue gap is <1 s, occasionally duplicating a word across segments; clamp the pull-back to the previous cue's end.

---

## P3 — Architecture, hygiene, and drift

19. **Testability.** `process/ai-summary.rb` is a 1,487-line monolith mixing pure logic (cue merging, offset math, VTT/markdown conversion, poll reconstruction) with I/O. There are **no automated tests** anywhere, yet at least four bugs found in this audit (#10, #13, #16, #18) live in pure functions that would be trivial to unit-test. Extract `Extractors` and the converters into `lib/` files and add a minimal rspec/minitest suite; wire it into the existing GitHub Actions workflow. The dev harness covers end-to-end; unit tests would cover the math.

20. **Multi-provider potential unused.** Canonical = first-listed provider (transcribe_audio.rb:490) regardless of the quality metrics the pipeline itself computes. Opportunity: select the canonical transcript by `coverage_ratio`/`avg_logprob`, or at least log a comparison. (Also: `run_provider_transcription`'s `detected_language` takes the first track's language — fine, but it inherits problem #11.)

21. **Cleanup items:**
    - `rescue Exception` in process (line 1478) and publish (line 260) catches `SystemExit`/`SignalException`; use `StandardError`.
    - Optimist default meeting-id placeholder `'58f4a6b3-…'` in both process and publish — make `-m` required like `transcribe_audio.rb` does.
    - Dead/vestigial: `whisper_threads` config key; `@word_count` blocks in md/json templates and locale strings; `transcript.txt`, `summary.txt`, `action_items.json` are produced but never published (top-level README's file table implies otherwise).
    - Stale comments: `transcribe_audio.rb` header still describes `transcribe.rb`/`deploy_transcription.sh`; provider headers still say "Deploy as transcribe.rb"; LLM error strings reference `llm.yml` paths that no longer exist.
    - Config default mismatch: `transcript_group_gap_seconds` defaults to 5 in code (process/ai-summary.rb:1265) but ships as 1 in `ai-summary.yml` — pick one.
    - `TranscriptionUtils::VAD_NODE_PATH` runs `` `npm root -g` `` at require time for every provider run, VAD or not; make it lazy.
    - `audio_duration_seconds`/`audio_duration_ms` interpolate paths into backtick shells; use `IO.popen` array form.
    - Publish early-exit ("already published", publish/ai-summary.rb:187–190) exits without writing `.done` — harmless in the normal flow, confusing if the status file was cleaned.
    - `run_process_with_timeout` sends only SIGTERM and doesn't kill the provider's child processes (ffmpeg/curl survive in the provider's process group); spawn with `pgroup: true` and kill the group, escalating to SIGKILL.
    - Hand-rolled `MarkdownConverter` (~300 lines, no nested lists) exists alongside a pandoc dependency; consider kramdown or pandoc for summary HTML and delete it.

---

## Suggested sequencing

1. **Week 1 (safety + stop the bleeding):** #1 escape templates, #7 filter metadata, #3 fix `.done` re-run bug, #4 package `whisper_cpp.rb`, #5 capture provider logs.
2. **Week 2 (reliability):** #2 fail-loud transcription with canonical-write guard, #6 verify/drop `known_speaker_names`, #8a/b stop-reason check + retries, #17 degrade gracefully without transcript.
3. **Week 3+ (accuracy):** #11 propagate detected language, #12 vocabulary-style prompts + rolling context, #10 segment-boundary cue splitting, #9 Albert verbose_json, #14 structured action items, #8c map-reduce summarization for long meetings.
4. **Ongoing:** #19 extract + unit-test pure logic; fold the P3 cleanup into those refactors.

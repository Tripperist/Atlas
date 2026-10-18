# C# coding-quality evaluation: `planner`

A repeatable way to compare local coding models on one realistic task. The results
of the first comparison, Qwen3-Coder-30B-A3B against Qwen2.5-Coder-7B, are in
[RESULTS.md](RESULTS.md).

## What is here

| Path | What it is |
| --- | --- |
| [`prompt.txt`](prompt.txt) | The exact task text both models receive |
| [`oracle.py`](oracle.py) | An independent Python implementation of the spec; generates the 45 test cases and their expected outputs |
| [`reference/Program.cs`](reference/Program.cs) | A C# solution used only to prove the tests are passable |
| [`generate.py`](generate.py) | Ask each model for a solution, several seeds each |
| [`eval.py`](eval.py) | Build a `Program.cs` and run it against every test |
| [`repair.py`](repair.py) | One round of compiler feedback for programs that did not build |
| [`make_fixed.py`](make_fixed.py) | The recorded minimal edits that make each failing program compile |
| [`analyze.py`](analyze.py), [`summarize.py`](summarize.py) | Score stages, totals and critical paths separately; build the results table |
| [`probe_plumbing.py`](probe_plumbing.py) | Confirm a follow-up message in a multi-turn request reaches each model |
| [`runs/`](runs) | Every model reply (`raw.txt`), extracted program (`Program.cs`), settings (`meta.json`) and score (`result.json`) |

The saved programs are the models' own output. A directory named `s<N>` is the
first attempt, `s<N>-repair1` the reply to compiler feedback, and `s<N>-fixed` the
first attempt with the edits in its `FIXES.md` applied.

## Run it

Needs the .NET 10 SDK, Python 3, and for the models GenieX and Foundry Local with
the models already downloaded (see the [README](../../README.md)).

```powershell
python oracle.py selftest                          # answers worked out by hand
python oracle.py gen tests/generated               # build the 45 cases (about 4 MB, not committed)
python eval.py reference                           # must print 45/45

python generate.py --model all --samples 3         # about 15 minutes; REPLACES runs/<model>/s<seed>/ (see --out)
python generate.py --model all --samples 3 --out scratch/runs   # the same, keeping the committed samples
python eval.py --all runs                          # one-shot scores
python repair.py runs/<model>/s1 runs/<model>/s2   # one feedback round
python make_fixed.py                               # apply the recorded compile fixes
python eval.py runs/<model>/s1-fixed               # score the logic
# analyze every fixed program, and the reference, in ONE call: it rewrites runs/analysis.json each time,
# and summarize.py needs all of them in it
python analyze.py reference (Get-ChildItem runs -Directory -Recurse -Filter '*-fixed' | ForEach-Object { Resolve-Path -Relative $_.FullName })
python summarize.py                                # runs/summary.md
```

Scoring rewrites each `result.json` in place. The scores do not change, but `buildSeconds` does, so
`git status` shows them modified: `git checkout -- .` restores them. `generate.py` replaces the committed
sample of the same seed unless you give `--out DIR`; `analyze.py --runs DIR` and `summarize.py --runs DIR` then
read and write that directory. A seed does not reproduce across a stack change (see
[RESULTS](RESULTS.md#how-it-was-judged)): the committed samples are the ones the write-up scores.

The whole guide to this evaluation, with how to read the scores, is in
[RUNNING-BENCHMARKS.md](../../docs/RUNNING-BENCHMARKS.md#12-code-quality-how-well-do-the-models-write-code).

## See the generated source

Everything the models wrote is in [`runs/`](runs): `runs/<model>/s<N>/Program.cs` is the first attempt (with
`raw.txt`, the whole reply), `s<N>-repair1/` the reply to compiler feedback, and `s<N>-fixed/Program.cs` the first
attempt with only the compile fixes listed in its `FIXES.md`. For example
[`runs/qwen3-coder-30b-a3b/s1/Program.cs`](runs/qwen3-coder-30b-a3b/s1/Program.cs) does not compile, and
[`s1-fixed/Program.cs`](runs/qwen3-coder-30b-a3b/s1-fixed/Program.cs) differs from it by one line and scores 21/45.
[`runs/summary.md`](runs/summary.md) has one row per program.

## Adding a model

Add an entry to `MODELS` in `generate.py` and a branch in its `main` for how to
call it, then generate, score and summarize as above. For a fair comparison keep
the prompt, temperature, top-p, seeds and token limit the same, and note anything
that differs (quantization, chat template, runtime) in the write-up.

## Reading the scores

`eval.py` is all-or-nothing per test, and a program that does not compile scores
zero on all of them, so look at the stages in order: compiles, then passes after
the compile fix, then the separate stage and critical-path scores. The
hand-written compile edits are an intervention by whoever runs the evaluation;
their count is reported, and each edit is listed in `FIXES.md`.

Do not tune the tests to a model's output. The expected results come from the
oracle, and the tests were validated against the reference before any model ran.

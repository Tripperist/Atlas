# Coding quality: Qwen3-Coder-30B-A3B against Qwen2.5-Coder-7B

One task, written as a C# console program, given to two local coding models three
times each. 2026-10-16, on the Snapdragon X2 Elite laptop described in the
[README](../../README.md).

## What to take away

- **Neither model wrote a program that compiled on the first attempt.** 0 of 6.
  One round of compiler feedback did not fix that either: of the 6 "repaired"
  programs, four were byte-identical to the original and the other two changed a
  single line.
- **The 30B is far ahead of the 7B on this task, and still not good.** After the
  smallest edit that makes each program compile (1–2 edits for the 30B, 2–5 for the
  7B), the 30B passes 21–22 of 45 tests and the 7B passes 2–5.
- **The 30B's strength is parsing and validation**: it reads the input format
  (15 of 16 valid cases) and passes 18–20 of 20 error-handling tests. **Its
  weakness is the actual algorithm**: the critical path is right in 1–3 of 16 cases
  and the stage layering is right in only 1 of its 3 samples.
- **The 7B cannot parse the input format.** All three samples split lines on
  whitespace and treat `configure:` as a task name, so they fail on the task's own
  example. It also broke two rules outright: one sample used a NuGet package the
  task forbids, and its error exit codes do not follow the spec.
- Neither is usable one-shot for a program like this. Both would need an iterative
  loop with tests, and the 30B's bugs (wrong results, quadratic running time) are
  the kind a loop with tests would catch and a compile check would not.

This is one task and three samples per model. The models also differ in
generation, size, architecture, quantization and runtime at once, so it does not
say *why* the 30B did better. See [limits](#what-this-does-not-show).

## The task

[`prompt.txt`](prompt.txt) is the exact text both models received. It asks for
`planner`, a build-plan calculator: parse a task file (`name: dep, dep [duration]`
per line), reject bad input with five distinct exit codes and messages, group the
tasks into stages by dependency depth, find the critical path with a precise
tie-break rule, and print text or JSON. It also requires that 100,000-task inputs
finish in seconds, that a 100,000-task chain not crash, and that totals beyond 32
bits not overflow.

It is small enough to fit in one file (the reference is 191 lines) and has enough
traps to separate models: ordinal against culture string ordering, definite
assignment, recursion depth, integer overflow, a deterministic tie-break, and
error precedence.

## How it was judged

- **45 black-box tests** (21 functional, 20 error, 4 at scale), run against the
  built executable with a 30-second timeout each.
- **Expected outputs come from an independent oracle**, a second implementation of
  the spec in Python ([`oracle.py`](oracle.py)), not from either model.
- **The tests were validated before any model saw them.** The oracle passes a
  self-test of answers worked out by hand, and a separate C# reference
  ([`reference/Program.cs`](reference/Program.cs)), which computes the critical
  path by a different method, passes all 45 with no warnings and a slowest case of
  0.3 s. The reference is not a competitor and is not scored against the models.
- **Same prompt and settings for both**: temperature 0.2, top-p 0.95, seeds 1, 2
  and 3, at most 4,096 output tokens. On the stack they were generated on, a seed
  reproduced its run (the 30B's first sample came out as 2,323 tokens both times it
  was generated). **That did not hold later:** regenerated on 2026-10-17, on GenieX
  v0.9.0 for the 30B and Foundry 0.10.3 for the 7B, seed 1 gave different programs
  from the committed ones (the 30B 1,980 tokens against 2,323, the 7B 1,254 against
  1,506). The committed samples are the ones every score in this document is for.
- **Three stages**, because a compile failure scores zero on every test and hides
  everything else:
  1. *One shot*: build the model's program as written.
  2. *One feedback round*: show the model its own compiler errors once and ask for
     a fix ([`repair.py`](repair.py)). Both models get a real multi-turn
     conversation; a probe confirmed the follow-up reaches each
     ([`probe_plumbing.py`](probe_plumbing.py)).
  3. *Minimal compile fix*: apply the smallest edit that makes each program
     compile, record it, and score the logic ([`make_fixed.py`](make_fixed.py)).
     These edits were written by hand by Claude, not by either model, and are in a
     `FIXES.md` beside each fixed program. They keep the model's own intent.

## Results

| Model | Seed | Tokens | Time | Code lines | One code block | Compile errors | After one feedback round | Edits to compile | Tests after fix (functional, error, scale) | Stages right | Critical path right |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-Coder-30B-A3B | 1 | 2,323 | 132 s | 348 | yes | **1** | identical, 1 error | 1 | **21/45** (2/21, 19/20, 0/4) | 3/16 | 1/16 |
| Qwen3-Coder-30B-A3B | 2 | 2,490 | 139 s | 356 | yes | **2** | changed, 1 error | 2 | **22/45** (4/21, 18/20, 0/4) | 3/16 | 3/16 |
| Qwen3-Coder-30B-A3B | 3 | 2,297 | 128 s | 356 | yes | **1** | identical, 1 error | 1 | **22/45** (2/21, 20/20, 0/4) | 15/16 | 1/16 |
| Qwen2.5-Coder-7B | 1 | 1,506 | 168 s | 209 | yes | **2** | identical, 2 errors | 2 | **2/45** (0/21, 2/20, 0/4) | 2/16 | 0/16 |
| Qwen2.5-Coder-7B | 2 | 1,535 | 170 s | 214 | yes | **3** | identical, 3 errors | 4 | **4/45** (0/21, 4/20, 0/4) | 0/16 | 0/16 |
| Qwen2.5-Coder-7B | 3 | 1,380 | 151 s | 191 | yes | **15** | changed, 16 errors | 5 | **5/45** (0/21, 5/20, 0/4) | 2/16 | 0/16 |

"Stages right" and "Critical path right" are out of the 16 text-format functional
cases and score those lines separately ([`analyze.py`](analyze.py)); the
all-or-nothing test count hides that distinction. Generated by
[`summarize.py`](summarize.py).

### What each model got wrong

**Qwen3-Coder-30B-A3B**

- **A definite-assignment trap, in all three samples.** It writes
  `string[] lines; try { lines = File.ReadAllLines(path); } catch { ...;
  Environment.Exit(2); }` and then uses `lines`. The compiler cannot know `Exit`
  never returns, so it reports CS0165. Sample 2 also compared strings with `<`
  (CS0019). Each is a one-line fix, and each is an error a C# developer learns
  once.
- **Feedback did not help it.** Given the CS0165 error, two samples re-emitted the
  identical program and the third fixed the other error but not this one.
- **It parses and validates well.** After the compile fix it accepts valid input
  in 15 of 16 cases (the miss is the file with tabs, CRLF line endings and
  irregular spacing) and gets 18–20 of 20 error tests right, including the exact
  messages, line numbers, exit codes and error precedence. Its misses were the
  empty-dependency cases (a colon with nothing after it, or an empty item in the
  list), in two of the three samples.
- **The plan is wrong.** Sample 3 gets every stage right and still reports the
  critical path as a single task's duration (`Critical path (5): test` for the
  example, where the answer is 12). In sample 1, stage 1 is the *last* tasks (`package`,
  `test`), as if the dependency edges were reversed. Sample 2 prints only the first stage. The cause of the
  critical-path bug was not isolated.
- **Two of three samples are too slow.** Samples 1 and 3 time out at 30 s on the
  100,000-task inputs, so their algorithms are not linear.

**Qwen2.5-Coder-7B**

- **It cannot read the input format.** It splits each line on whitespace, so
  `configure: fetch [1]` yields a task named `configure:`. Every sample fails on
  the task's own example (`error: task 'test:' depends on unknown task 'compile'`).
- **Basic type-design errors.** One sample declares a data class and three
  exception classes `static`, which produced 15 compile errors from four root
  causes. Two samples pass a property as an `out` argument, and one assigns to a
  `foreach` variable.
- **It ignored a rule.** Sample 3 calls Newtonsoft's `JsonConvert`, a package the
  task forbids. It also treats `--format json` as a single argument.
- **Its errors do not follow the spec.** It exits with 1 for most failures and
  passes 2–5 of 20 error tests.
- **Feedback did not help it either.** Two samples re-emitted identical code, and
  the third changed one line and went from 15 errors to 16.

### Speed

Both took roughly two minutes per attempt. The 30B (GPU, through `geniex infer`,
including about 12 s to load) wrote 2,300–2,500 tokens in 128–139 s. The 7B (NPU,
through Foundry's HTTP endpoint) wrote 1,380–1,535 tokens in 151–170 s, because
its decode slows as the context grows (see
[BENCHMARKS](../../docs/BENCHMARKS.md)). The 30B wrote about 1.6 times as much
code in about 0.8 times the time.

## What this does not show

- **Why.** The two models differ in generation (Qwen3 against Qwen2.5), size
  (30B mixture-of-experts against 7B dense), quantization (a Q4_0 GGUF against a
  QNN int4 variant), runtime and chat template, all at once. Nothing here
  attributes the gap to size. Qwen2.5-Coder 14B (a GPU variant in Foundry) and the
  1.5B and 0.5B NPU variants would give a size ladder within one generation, and
  were not run.
- **A repeat of the draw.** The two regenerated samples above did not compile either
  (2 errors for the 30B, 1 for the 7B), which agrees with the 0 of 6 here, but it
  is two more samples, scored one-shot only.
- **Anything beyond this task.** One task, three samples per model at one
  temperature. The samples varied (the 30B's three programs fail in three
  different ways), so a different draw could move the numbers.
- **A multi-round agent.** One feedback round, and only compiler errors. A loop
  that runs the tests and feeds back failures might do much better, and is the
  obvious next experiment. Prompts that ask for tests first, or for a plan, were
  not tried.
- **A comparison with a strong model.** The reference solution passes 45 of 45 by
  construction and says nothing about how a frontier model would do.
- **Quantization effects.** Q4_0 is a basic 4-bit format. How much better these
  models are at higher precision was not measured.

## Models and stack

| | Qwen3-Coder-30B-A3B-Instruct | Qwen2.5-Coder-7B-Instruct |
| --- | --- | --- |
| Artifact | `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`, Q4_0, 17,379,990,688 bytes, SHA256 `cf9ea0572e8759348ef7f8cd899fbfecba5110929fc1aa620d18bb6d91e62700` | `qwen2.5-coder-7b-instruct-qnn-npu:1` from the Foundry Local catalogue |
| Runtime | GenieX v0.8.0, llama.cpp `9425611`, `geniex infer` and `geniex serve` | Foundry Local CLI 0.10.3, OpenAI HTTP endpoint |
| Compute | Adreno GPU (`--compute gpu`) | Hexagon NPU (QNN) |
| Licence | Apache-2.0 | Apache-2.0 |

Stack `44a1e6e37bc4` (Adreno 32.0.172.2, NPU driver 30.0.228.10000, Windows build
28120). .NET SDK 10.0.401, target `net10.0`. The 30B ran on the GPU so it could
not contend with the 7B for the NPU; the compute unit changes speed, not what the
weights compute.

## Reproduce

See the [README](README.md). The generated tests are not committed
(`tests/generated/`); `python oracle.py gen tests/generated` rebuilds them
deterministically.

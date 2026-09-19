# Atlas agent instructions

## Scope

Read README.md before implementation. Atlas is an experimental model-development repository; a trained model and pipeline do not yet exist.

Keep work within Atlas unless the user explicitly requests changes in sibling repositories. Preserve user changes. Do not commit, push, publish artifacts, or launch paid training jobs unless authorized.

## Experiment discipline

- Establish and retain an unchanged base-model baseline.
- Diagnose retrieval, tool, data, and prompt failures before proposing training.
- Train for demonstrated behavioral gaps; do not treat fresh travel facts as model knowledge to memorize.
- Prefer a small reproducible adapter experiment before larger training runs.
- Record base-model revision, dataset version, code revision, configuration, seeds, dependency versions, hardware, and artifact checksums.
- Clearly distinguish proposals, completed runs, and measured results.
- Check model and dataset licenses before adopting or distributing artifacts.

## Data handling

Track provenance and permitted use. Use approved sanitized data or synthetic fixtures; exclude credentials, personal itineraries, and raw private conversation exports from Git and external uploads.

Split and deduplicate data before training. Keep held-out evaluation answers out of training and calibration data. Evaluate generalization across trips or regions where practical.

Do not commit large datasets, weights, checkpoints, adapters, or compiled model binaries. Add suitable ignore rules before creating outputs; the initial ignore file may primarily target Visual Studio. Store reproducible manifests and compact summaries in Git.

Do not read or modify production databases as part of model preparation without explicit task scope. Tripperist owns its schema and migrations; Scout owns retrieval and experimental embeddings.

## Target runtime

The target is Windows ARM Snapdragon inference on a 32 GB Surface; exact hardware support must be confirmed. Do not assume its NPU is a general-purpose LLM training accelerator.

Validate the export path and Scout-compatible runtime before investing in fine-tuning. Pin tokenizer/chat-template versions. Test adapter loading or merging, quantization, context limits, structured output, and actual accelerator use.

Keep model locations configurable. Never assume a local D: drive path exists on a training host. Treat uploads to hosted conversion services as data transfers that must fit the user's authorized scope.

## Evaluation and delivery

Use task metrics and held-out evaluations, not training loss alone. Compare base, fine-tuned, and final quantized artifacts under the same conditions. Report regressions, memory, latency, hardware, and runtime limitations.

Version the Scout model manifest and document compatibility changes. Model-directed tool calls are proposals; Scout remains responsible for validation and execution.

Run meaningful checks for dataset schemas, split integrity, preprocessing, and artifact manifests as implemented. For documentation-only work, inspect the diff and links; do not invent runnable commands.

Update setup and reproduction instructions as pipelines are added. In the handoff, state what changed, what actually ran, the evidence for conclusions, and unfinished work.

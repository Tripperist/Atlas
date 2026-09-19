# Atlas

Atlas is the model development project for Tripperist's Scout travel assistant. It contains workflows for dataset preparation, fine-tuning, evaluation, and model optimization for local inference on Snapdragon ARM hardware.

## Status and purpose

This repository currently contains documentation, not a trained model or executable training pipeline. Atlas is a working model-family name; no base model, training framework, or deployment format has been selected.

Improve travel-assistant behavior only where measured evaluations establish a need: preference interpretation, structured responses, tool selection, and grounded explanations. Keep changing travel facts in Scout's retrieval sources rather than trying to memorize them through training.

## Repository boundaries

- **Tripperist** owns the production application and authoritative travel data/schema.
- **Scout** owns the experimental API, orchestration, tools, retrieval, embeddings, and inference integration.
- **Atlas** owns training-data preparation, model experiments, evaluation, adapters, export, quantization, and model documentation.

Atlas must not depend on changes to the production Tripperist repository. Scout can use an existing base model while Atlas is developed. Scout's embedding pipeline is separate; changes to an embedding model must be coordinated explicitly.

## Hardware strategy

The initial inference target is the owner's Windows ARM Snapdragon Surface with 32 GB RAM. Confirm the exact processor and benchmark the intended runtime on that machine.

Use the Surface for development, dataset review, evaluation where practical, and local inference. Plan substantial LoRA/QLoRA training on a separate supported GPU environment. GPU rental or paid jobs require an explicit user request or approval.

A working training checkpoint does not guarantee Windows ARM or NPU compatibility. Verify the base architecture's export path, tokenizer and chat template, adapter support or merge process, quantization, and target runtime before investing in training. ONNX Runtime/QNN is a candidate deployment route, not a guaranteed target for every model.

## Proposed repository layout

These directories are planned and should be created as workflows are implemented.

| Path | Purpose |
| --- | --- |
| configs/ | Versioned training, evaluation, and export configurations |
| scripts/ | Dataset preparation, training, evaluation, and export entry points |
| schemas/ | Dataset and model-manifest definitions |
| evaluations/ | Reviewed scenarios, metrics, and compact result summaries |
| docs/ | Decisions, reproducibility notes, and model cards |
| tests/ | Meaningful checks for data and pipeline behavior |

Choose and pin tooling when implementing the first reproducible experiment. Python is a practical candidate for training and export; Scout remains a C#/.NET application.

## Development workflow

1. Establish a base-model baseline using representative Scout scenarios.
2. Diagnose failures in data, retrieval, tools, prompts, and model behavior separately.
3. Prepare reviewed examples for failures that training can reasonably address.
4. Split training, validation, and held-out evaluation data before training.
5. Run a reproducible adapter-training experiment.
6. Compare with the unchanged base model on the same evaluation set.
7. Export or merge as required, quantize, and evaluate the actual deployment artifact.
8. Publish an identified artifact and compatibility manifest for Scout when authorized.

Begin with approximately 50-100 reviewed evaluation scenarios. This is an evaluation starting point, not a prescribed training-set size. Training-set size should follow measured quality and coverage.

## Dataset requirements

Examples may include user requests, relevant retrieved evidence, available tools, expected tool calls, constraints, and reviewed responses. Keep training inputs consistent with the evidence Scout can actually supply at inference time.

Track provenance, usage rights, preparation version, and review status. Deduplicate across splits and separate trips/regions where useful to detect memorization. Exclude held-out answers from training and calibration inputs.

Use synthetic or approved sanitized fixtures in Git. Keep private travel records, raw conversations, large datasets, checkpoints, adapters, and model weights in appropriate external storage. Document artifact identifiers and checksums instead of committing binaries.

## Evaluation

Measure structured-output validity, tool-call correctness, grounding, invented places, hard-constraint violations, and explanation quality. Use Scout integration evaluations for end-to-end routing and itinerary feasibility.

Compare both pre-export and deployed quantized artifacts. Record latency, peak memory, context length, hardware, runtime version, and actual acceleration. Do not claim improvement from training loss alone.

## Scout delivery contract

Maintain a versioned manifest with:

- Artifact identity, immutable version, location, and checksums.
- Base-model identity/revision and applicable licenses.
- Adapter identity and whether weights are merged.
- Tokenizer and chat-template identity.
- Quantization, context limits, input/output conventions, and tool-call format.
- Supported runtime versions and tested hardware.
- Evaluation dataset version, results, known limitations, and reproduction instructions.

Store large artifacts in a model registry or artifact store. Keep schema/examples in Git when implemented and coordinate compatibility changes with Scout.

## Development

See [Setup.MD](Setup.MD) for the Windows ARM Snapdragon development setup, 32 GB memory guidance, runtime validation, and separate training-host preparation.

No training, evaluation, or export commands exist yet. Add verified environment setup, dependency versions, and reproduction commands with the first pipeline.

See [AGENTS.md](AGENTS.md) for contributor and coding-agent instructions.

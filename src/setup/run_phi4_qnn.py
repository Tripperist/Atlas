import os
import onnxruntime_genai as og
import onnxruntime_qnn as qnn_ep

# 1. PATH TO DOWNLOADED MODEL FOOTPRINT
# Update this path to point exactly to the directory where uvx downloaded your Phi-4 footprint
MODEL_DIR = r"D:\repos\Atlas\models\Phi-4-Mini-Instruct"

print("Initializing GenAI Pipeline with QNN Acceleration...")

# =====================================================================
# STEP 1: EXPLICIT QNN ACCELERATION COUPLING
# =====================================================================
# Because onnxruntime-genai handles its own runtime engine wrapper, we must
# explicitly register your local QNN provider binaries so the tokenizer
# and generator loops know how to bind to the Hexagon HTP driver.
try:
    og.register_execution_provider_library(
        "QNNExecutionProvider",
        qnn_ep.get_library_path()  # Grabs the verified DLL path from your package
    )
    print("Successfully bound QNNExecutionProvider to the GenAI engine.")
except Exception as e:
    print(f"❌ Failed to bridge QNN provider library to GenAI: {e}")
    exit(1)

# =====================================================================
# STEP 2: LOAD PRE-COMPILED CONTEXT STRUCT
# =====================================================================
# The Model object will ingest the folder configuration assets, parse the
# embedded layout graphs, and safely handshake with the Snapdragon NPU.
if not os.path.exists(MODEL_DIR):
    print(f"❌ Error: Model directory not found at {MODEL_DIR}")
    print("Please double check the directory where your model asset footprint was fetched.")
    exit(1)

print(f"Loading pre-compiled model footprint from: {MODEL_DIR}")
try:
    model = og.Model(MODEL_DIR)
    tokenizer = og.Tokenizer(model)
    print("🎉 Model configuration and tokenizers instantiated successfully on the NPU!")
except Exception as e:
    print(f"❌ Failed to initialize model structure: {e}")
    exit(1)

# =====================================================================
# STEP 3: AUTOREGRESSIVE GENERATIVE PIPELINE LOOP
# =====================================================================
prompt = "Instruct: Write a fast Python sorting algorithm.\nOutput:"
input_tokens = tokenizer.encode(prompt)

# Bundle hardware constraints and configuration payload
params = og.GeneratorParams(model)
params.set_input_ids(input_tokens)
params.set_search_property("max_length", 512)
params.set_search_property("temperature", 0.7)

# Instantiate the active token generation loop across the HTP processing array
generator = og.Generator(model, params)

print(f"\n--- Prompt: {prompt} ---\nResponse: ", end="")

try:
    while not generator.is_done():
        generator.compute_logits()
        generator.generate_next_token()
        
        # Pull the newly minted token array from the hardware layer
        new_token = generator.get_next_tokens()
        
        # Decode and stream the response to the terminal in real time
        print(tokenizer.decode([new_token]), end="", flush=True)
except KeyboardInterrupt:
    print("\n\nGeneration paused by user.")

# Clean up memory allocations across the NPU registers
del generator
print("\n\nSession closed safely.")

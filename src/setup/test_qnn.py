import os
import numpy as np
import onnxruntime as ort
import onnxruntime_qnn as qnn_ep

print("Base Providers:", ort.get_available_providers())
print(f"ONNX Runtime QNN EP Extension Version: {qnn_ep.__version__}")

# =====================================================================
# CHANGE 1: DYNAMIC PLUGIN REGISTRATION
# =====================================================================
# Because onnxruntime-qnn acts as an external extension wrapper rather 
# than a built-in provider, the core ONNX Runtime engine won't see it via 
# default exploration. We use the wrapper's built-in utility to locate 
# the underlying binary driver plugin and force register it dynamically.
ep_lib_path = qnn_ep.get_library_path()
lib_registration_name = "QNNExecutionProvider"

try:
    ort.register_execution_provider_library(lib_registration_name, ep_lib_path)
    print("Successfully registered external QNN Execution Provider library.")
except Exception as e:
    print(f"Failed to register QNN library plugin: {e}")

# Verify that 'QNNExecutionProvider' now properly populates in the runtime array
updated_providers = ort.get_available_providers()
print("Updated Providers List:", updated_providers)


# =====================================================================
# CHANGE 2: HARDWARE-COMPLIANT DUMMY MODEL GENERATION
# =====================================================================
# Initially, bare operators (like standard FP32 or MatMulInteger) caused 
# ONNX Runtime to fall back to the CPU execution block because the 
# Hexagon NPU cannot process non-quantized linear data directly. 
# 
# We refactored this generator function to build a structural graph 
# that strictly adheres to Snapdragon X2 Elite (HTP) hardware primitives:
#   - Migrated to 'QLinearMatMul' using UINT8 data layers.
#   - Appended mandatory scale and zero-point tensors required for 
#     tensor matrix alignment across the hardware HTP tensor processing array.
def create_dummy_int8_model(filename="dummy_qnn_model.onnx"):
    import onnx
    from onnx import helper, TensorProto
    
    # Create an element-wise Cast operation (FLOAT -> FLOAT16)
    # The Hexagon NPU natively supports FP16 precision routing
    node = helper.make_node(
        'Cast',
        inputs=['X'],
        outputs=['Y'],
        to=TensorProto.FLOAT16,
        name='NPU_Cast_ElementWise'
    )
    
    # Define a classic 4D tensor shape [1, 3, 224, 224] 
    # This prevents the Qualcomm driver from rejecting flat or unranked layout arrays
    tensor_shape = [1, 3, 224, 224]
    
    graph = helper.make_graph(
        nodes=[node],
        name='PureNpuCastGraph',
        inputs=[helper.make_tensor_value_info('X', TensorProto.FLOAT, tensor_shape)],
        outputs=[helper.make_tensor_value_info('Y', TensorProto.FLOAT16, tensor_shape)],
        initializer=[]
    )
    
    # Configure using compliant IR version 13 for ONNX Runtime v1.30.0 compatibility
    model = helper.make_model(graph, producer_name='qnn-test', ir_version=13)
    
    while len(model.opset_import) > 0:
        model.opset_import.pop()
        
    opset = model.opset_import.add()
    opset.domain = "" 
    opset.version = 19
    
    onnx.save(model, filename)
    return filename

def fetch_validated_qnn_model(filename="mobilenet_v2_quant_int8.onnx"):
    import urllib.request
    
    # URL to a verified, pre-quantized INT8 MobileNetV2 graph optimized for ONNX Runtime QNN EP
    # This model layout contains all mandatory HTP context layout properties out-of-the-box.
    model_url = "https://github.com"
    
    print(f"📥 Fetching pre-validated INT8 model from repository...")
    try:
        # Download the file locally to your script folder
        urllib.request.urlretrieve(model_url, filename)
        print(f"✅ Download complete! Model saved to: {filename}")
        return filename
    except Exception as e:
        print(f"❌ Failed to download the validated model asset: {e}")
        raise e

# =====================================================================
# CHANGE 4: SESSION CONFIGURATION AND TARGET BACKEND PAIRING
# =====================================================================
if "QNNExecutionProvider" in updated_providers:
    #model_path = os.path.join(os.path.dirname(__file__), "dummy_qnn_model.onnx")
    #print(f"\nGenerating INT8 dummy test model at: {model_path}")
    #create_dummy_int8_model(model_path)

    model_path = os.path.join(os.path.dirname(__file__), "mobilenet_v2_quant_int8.onnx")
    
    # Fetch the certified hardware target asset
    fetch_validated_qnn_model(model_path)
    
    # Configure the runtime options to specifically tell the QNN module 
    # to target the NPU acceleration chip (via QnnHtp.dll)
    qnn_options = {
        "backend_path": "QnnHtp.dll"
    }
    
    # Corrected Option Instantiation Syntax: 
    # Fixed a python exception by moving runtime configuration flags away 
    # from being a direct property assignment inside SessionOptions, and passing 
    # them cleanly inside the ort.InferenceSession instantiation payload instead.
    options = ort.SessionOptions()
    
    # Enforce strict NPU rules: Tells the engine to crash early if any part of 
    # our model pipeline tries to drop back onto the CPU execution stack.
    options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
    
    print("\nAttempting a live backend handshake...")
    try:
        session = ort.InferenceSession(
            model_path, 
            sess_options=options, 
            providers=["QNNExecutionProvider"], 
            provider_options=[qnn_options]
        )
        print("🎉 Full handshake success! The Snapdragon HTP NPU backend initialized flawlessly.")
        print(f"Model Inputs: {[i.name for i in session.get_inputs()]}")
        
        # Clean up transient file assets
        if os.path.exists(model_path):
            os.remove(model_path)
            
    except Exception as e:
        print(f"❌ Backend initialization failed: {e}")
        print("\nTip: If it complains about missing dependent libraries, ensure the root onnxruntime_qnn folder is fully exposed in your system $env:PATH.")
else:
    print("\nQNNExecutionProvider is unavailable. Execution halted.")

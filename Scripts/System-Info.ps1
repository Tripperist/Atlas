Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemType, @{Name='RAM_GiB';Expression={[math]::Round($_.TotalPhysicalMemory / 1GB, 1)}}
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, Size, SizeRemaining 
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture

winget install --id Git.Git -e --architecture arm64 -silent --accept-package-agreements --accept-source-agreements
winget install --id Python.Python.3.14 --architecture arm64 -silent --accept-package-agreements --accept-source-agreements
winget install --id astral-sh.uv -e --architecture arm64 -silent --accept-package-agreements --accept-source-agreements
winget install Microsoft.FoundryLocal

python --version
python -c "import platform, struct; print(platform.machine()); print(struct.calcsize('P') * 8)"
uv --version
dotnet --info

$env:ATLAS_DATA_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\data'
$env:ATLAS_MODEL_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\models'
$env:ATLAS_RUN_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\runs'
$env:HF_HOME = Join-Path $env:LOCALAPPDATA 'Atlas\cache\huggingface'

cdd d:\repos\Atlas
uv venv
.venv\Scripts\activate

uv init
uv add onnxruntime-genai
uv add onnxruntime-qnn

uvx --from qai-hub-models-cli qai-hub-models fetch Phi-4-Mini-Instruct --runtime geniex_llamacpp --precision q4_0
uvx --from qai-hub-models-cli qai-hub-models fetch Phi-4-Mini-Instruct --runtime geniex_llamacpp --precision q4_0




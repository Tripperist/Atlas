Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemType, @{Name='RAM_GiB';Expression={[math]::Round($_.TotalPhysicalMemory / 1GB, 1)}}
Manufacturer          Model                                   SystemType     RAM_GiB
------------          -----                                   ----------     -------
Microsoft Corporation Surface Laptop 13.8in 8th Ed Snapdragon ARM64-based PC   63.50

Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Name                           NumberOfCores NumberOfLogicalProcessors
----                           ------------- -------------------------
Snapdragon X2 Elite @ 4.03 GHz            12                        12

 Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
Caption                                  Version    BuildNumber OSArchitecture
-------                                  -------    ----------- --------------
Microsoft Windows 11 Pro Insider Preview 10.0.28120 28120       ARM 64-bit Processor

Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, Size, SizeRemaining
DriveLetter         Size SizeRemaining
-----------         ---- -------------
          D 109924319232   93916835840
          C 912680546304  464068063232

[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
Arm64
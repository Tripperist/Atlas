| Model | Seed | Tokens | Time | Lines | One code block | Compile errors | After one feedback round | Edits to compile | Tests after fix (functional, error, scale) | Stages right | Critical path right |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-Coder-30B-A3B | 1 | 2323 | 132 s | 348 | yes | **1** | identical, 1 errors | 1 | **21/45** (2/21, 19/20, 0/4) | 3/16 | 1/16 |
| Qwen3-Coder-30B-A3B | 2 | 2490 | 139 s | 356 | yes | **2** | changed, 1 errors | 2 | **22/45** (4/21, 18/20, 0/4) | 3/16 | 3/16 |
| Qwen3-Coder-30B-A3B | 3 | 2297 | 128 s | 356 | yes | **1** | identical, 1 errors | 1 | **22/45** (2/21, 20/20, 0/4) | 15/16 | 1/16 |
| Qwen2.5-Coder-7B | 1 | 1506 | 168 s | 209 | yes | **2** | identical, 2 errors | 2 | **2/45** (0/21, 2/20, 0/4) | 2/16 | 0/16 |
| Qwen2.5-Coder-7B | 2 | 1535 | 170 s | 214 | yes | **3** | identical, 3 errors | 4 | **4/45** (0/21, 4/20, 0/4) | 0/16 | 0/16 |
| Qwen2.5-Coder-7B | 3 | 1380 | 151 s | 191 | yes | **15** | changed, 16 errors | 5 | **5/45** (0/21, 5/20, 0/4) | 2/16 | 0/16 |

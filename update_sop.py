import re

sop_path = "/Users/mansionlai/Documents/gemini/ops-knowledge-base/docs/kubevirt/guest-diagnostics-sop.md"
ps1_path = "/Users/mansionlai/Documents/gemini/ops-knowledge-base/scripts/guest-diag/windows-diag.ps1"

with open(ps1_path, "r", encoding="utf-8") as f:
    ps1_code = f.read()

with open(sop_path, "r", encoding="utf-8") as f:
    sop_content = f.read()

# find the section
header_idx = sop_content.find("## 腳本原始碼")
if header_idx != -1:
    block_start = sop_content.find("```powershell", header_idx)
    block_end = sop_content.find("```", block_start + 13)
    if block_start != -1 and block_end != -1:
        new_sop = sop_content[:block_start + 14] + ps1_code + "\n" + sop_content[block_end:]
        with open(sop_path, "w", encoding="utf-8") as f:
            f.write(new_sop)
        print("SOP updated successfully.")
    else:
        print("Could not find powershell block.")
else:
    print("Could not find header.")

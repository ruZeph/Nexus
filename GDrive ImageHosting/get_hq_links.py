import re
import os
import tkinter as tk
from tkinter import filedialog

# --- Library Check & Error Handling ---
try:
    import pandas as pd
except ImportError:
    print("\n❌ Error: The 'pandas' library is not installed.")
    print("👉 Run this command to fix: pip install pandas openpyxl\n")
    input("Press Enter to exit...")
    exit()

def extract_id(text):
    """Extracts Google Drive ID using robust regex patterns."""
    if not isinstance(text, str): return None
    patterns = [
        r"/d/([a-zA-Z0-9_-]{25,})", 
        r"id=([a-zA-Z0-9_-]{25,})",
        r"file/d/([a-zA-Z0-9_-]{25,})"
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match: return match.group(1)
    return None

def get_formats(file_id):
    """Generates various link formats including high-res thumbnails."""
    if not file_id: return None
    return {
        "File ID": file_id,
        "LH3 HQ Link": f"https://lh3.googleusercontent.com/d/{file_id}=s0",
        "Thumbnail (1000px)": f"https://drive.google.com/thumbnail?id={file_id}&sz=w1000",
        "Direct View": f"https://drive.google.com/uc?export=view&id={file_id}",
        "Embed Link": f"https://drive.google.com/file/d/{file_id}/preview",
        "Markdown HQ": f"![Image](https://lh3.googleusercontent.com/d/{file_id}=s0)"
    }

def process_batch():
    """Opens a visual file picker and processes the file into Excel."""
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True) 

    print("Opening file picker...")
    file_path = filedialog.askopenfilename(
        title="Select Input File",
        filetypes=[("All Supported", "*.txt *.csv *.xlsx *.xls"), 
                   ("Text Files", "*.txt"), 
                   ("CSV Files", "*.csv"), 
                   ("Excel Files", "*.xlsx *.xls")]
    )

    if not file_path:
        print("❌ No file selected.")
        return

    ext = os.path.splitext(file_path)[1].lower()
    links_found = []

    try:
        if ext == '.txt':
            with open(file_path, 'r', encoding='utf-8') as f:
                links_found = f.readlines()
        elif ext == '.csv':
            df_in = pd.read_csv(file_path, header=None)
            links_found = df_in.iloc[:, 0].astype(str).tolist()
        elif ext in ['.xlsx', '.xls']:
            # This is where openpyxl is required
            try:
                df_in = pd.read_excel(file_path, header=None)
                links_found = df_in.iloc[:, 0].astype(str).tolist()
            except ImportError:
                print("\n❌ Error: 'openpyxl' is required to read/write Excel files.")
                print("👉 Run: pip install openpyxl\n")
                return
    except Exception as e:
        print(f"❌ Error reading file: {e}")
        return

    results = []
    for line in links_found:
        fid = extract_id(line.strip())
        if fid:
            results.append(get_formats(fid))

    if results:
        try:
            df_out = pd.DataFrame(results)
            output_name = "processed_gdrive_links.xlsx"
            df_out.to_excel(output_name, index=False)
            print(f"\n✅ Success! Processed {len(results)} links.")
            print(f"📁 Output saved as: {os.path.abspath(output_name)}")
        except ImportError:
            print("\n❌ Error: Could not save Excel file because 'openpyxl' is missing.")
            print("👉 Run: pip install openpyxl\n")
    else:
        print("⚠️ No valid Google Drive links found.")

def main():
    print("="*50)
    print(" GDrive Image Hosting Batch Processor")
    print("="*50)
    print("1. Single Link (Manual)")
    print("2. Batch File (File Picker)")
    choice = input("\nSelect [1/2]: ").strip()

    if choice == '1':
        url = input("Paste Link: ").strip()
        fid = extract_id(url)
        if fid:
            data = get_formats(fid)
            for k, v in data.items(): print(f"{k}: {v}")
        else:
            print("Invalid Link.")
    elif choice == '2':
        process_batch()
    else:
        print("Invalid choice.")

if __name__ == "__main__":
    main()
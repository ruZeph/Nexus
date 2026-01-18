import os
import subprocess
import tkinter as tk
from tkinter import filedialog, messagebox

def copy_with_robocopy(source, dest, filename):
    """
    Uses Windows Robocopy to copy a single file.
    /NJH /NJS /NFL /NDL - Reduces noise in output
    /mt - Multi-threaded (faster)
    """
    # Robocopy expects folder paths, not full file paths for source/dest arguments
    # We pass the filename specifically as the 3rd argument
    cmd = [
        "robocopy",
        source,      # Source Directory
        dest,        # Destination Directory
        filename,    # Specific File
        "/mt",       # Multi-threading
        "/njh", "/njs", "/ndl", "/nc", "/ns" # Quiet mode
    ]
    
    # Run the command and suppress output to keep our progress bar clean
    result = subprocess.run(cmd, capture_output=True, text=True, shell=True)
    
    # Robocopy return codes: 0-7 are success/partial success (1 means file copied)
    return result.returncode < 8

def select_folder(title, initial_dir=None):
    return filedialog.askdirectory(title=title, initialdir=initial_dir)

def main():
    root = tk.Tk()
    root.withdraw() # Hide the main window

    print("--- Cyberpunk 2077 DLC Extractor (Robocopy Optimized) ---")
    
    # 1. Select Source
    print("Step 1: Select your Cyberpunk 2077 Root Folder.")
    source_root = select_folder("Select Cyberpunk 2077 Root Folder")
    if not source_root:
        print("No source selected. Exiting.")
        return

    # 2. Select Destination
    default_dest = os.path.join(source_root, "DLC Files")
    print(f"Step 2: Select Destination Folder.")
    print(f"(Press Cancel to use default: {default_dest})")
    
    dest_root_folder = select_folder("Select Destination Folder (Cancel for Default)", initial_dir=source_root)
    
    if not dest_root_folder:
        dest_root_folder = default_dest
        print(f"Using default destination: {dest_root_folder}")
    else:
        # Create a subfolder "DLC Files" in the chosen destination to keep it clean
        dest_root_folder = os.path.join(dest_root_folder, "DLC Files")
        print(f"Destination selected: {dest_root_folder}")

    # 3. Define Files
    file_manifest = {
        os.path.join("archive", "pc", "ep1"): [
            "audio_1_general.archive",
            "ep1.addcont_keystone",
            "ep1_1_nightcity.archive",
            "ep1_1_nightcity_gi.archive",
            "ep1_1_nightcity_terrain.archive",
            "ep1_2_gamedata.archive",
            "lang_en_voice.archive",
            "lang_ar_text.archive", "lang_cs_text.archive", "lang_de_text.archive",
            "lang_en_text.archive", "lang_es-es_text.archive", "lang_es-mx_text.archive",
            "lang_fr_text.archive", "lang_hu_text.archive", "lang_it_text.archive",
            "lang_ja_text.archive", "lang_ko_text.archive", "lang_pl_text.archive",
            "lang_pt_text.archive", "lang_ru_text.archive", "lang_th_text.archive",
            "lang_tr_text.archive", "lang_ua_text.archive", "lang_zh-cn_text.archive",
            "lang_zh-tw_text.archive"
        ],
        os.path.join("r6", "cache"): [
            "tweakdb_ep1.bin"
        ]
    }

    # 4. Calculate total for progress bar
    total_files = sum(len(files) for files in file_manifest.values())
    current_file_idx = 0
    success_count = 0

    print("\nStarting Copy Process...")
    print("-" * 50)

    for relative_path, files in file_manifest.items():
        source_dir = os.path.join(source_root, relative_path)
        dest_dir = os.path.join(dest_root_folder, relative_path)

        if not os.path.exists(source_dir):
            print(f"Skipping missing directory: {relative_path}")
            current_file_idx += len(files)
            continue

        for filename in files:
            current_file_idx += 1
            
            # Update Progress Bar
            progress = (current_file_idx / total_files) * 100
            print(f"\rProgress: [{('=' * int(progress // 2)).ljust(50)}] {progress:.1f}% | Copying: {filename}", end="", flush=True)

            source_file_check = os.path.join(source_dir, filename)
            
            if os.path.exists(source_file_check):
                # Ensure destination directory exists
                if not os.path.exists(dest_dir):
                    os.makedirs(dest_dir)
                
                # Execute Robocopy
                if copy_with_robocopy(source_dir, dest_dir, filename):
                    success_count += 1
            else:
                # File missing (e.g. uninstalled language), just skip silently to keep progress clean
                pass

    print("\n" + "-" * 50)
    print(f"Operation Complete. {success_count} files copied successfully.")
    
    # Open the folder for the user
    try:
        os.startfile(dest_root_folder)
    except:
        pass

if __name__ == "__main__":
    main()
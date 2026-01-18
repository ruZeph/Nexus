import os
import shutil
import sys
import datetime
from pathlib import Path

# --- Configuration: Combined Folder List ---
TARGET_FOLDERS = [
    r"%PUBLIC%\Documents\Steam\CODEX",
    r"%PUBLIC%\Documents\Steam\RUNE",
    r"%APPDATA%\Goldberg SteamEmu Saves",
    r"%APPDATA%\EMPRESS",
    r"%PUBLIC%\EMPRESS",
    r"%LOCALAPPDATA%\SKIDROW",
    r"%DOCUMENTS%\SkidRow",
    r"%APPDATA%\SmartSteamEmu",
    r"%APPDATA%\GSE Saves",
    r"%APPDATA%\CreamAPI",
    r"%APPDATA%\Steam\CODEX",
    r"%PROGRAMDATA%\Steam"
]

def expand_path(path_str):
    """Expands Windows environment variables, including a fix for %DOCUMENTS%."""
    if "%DOCUMENTS%" in path_str.upper():
        docs_path = Path(os.path.expanduser('~')) / 'Documents'
        path_str = path_str.replace("%DOCUMENTS%", str(docs_path)).replace("%documents%", str(docs_path))
    return os.path.expandvars(path_str)

def clean_folder(path, delete_subfolders_only, recreate_source, is_dry_run, log_file):
    """Core logic to delete or empty folders."""
    action_label = "[DRY RUN]" if is_dry_run else "[ACTION]"
    
    if not os.path.exists(path):
        msg = f"[NOT FOUND] {path}"
        print(f"  {msg}")
        log_file.write(msg + "\n")
        return

    try:
        if delete_subfolders_only:
            # Mode: Empty the folder but keep the root
            for item in os.listdir(path):
                item_path = os.path.join(path, item)
                if not is_dry_run:
                    if os.path.isdir(item_path):
                        shutil.rmtree(item_path, ignore_errors=True)
                    else:
                        os.remove(item_path)
                
                msg = f"{action_label} Deleted inside {path}: {item}"
                print(f"    - {msg}")
                log_file.write(msg + "\n")
        else:
            # Mode: Delete the entire folder
            if not is_dry_run:
                shutil.rmtree(path, ignore_errors=True)
                if recreate_source:
                    os.makedirs(path, exist_ok=True)
            
            msg = f"{action_label} Deleted Folder: {path} (Recreate: {recreate_source})"
            print(f"  {msg}")
            log_file.write(msg + "\n")

    except Exception as e:
        err = f"[ERROR] Failed to process {path}: {e}"
        print(f"  {err}")
        log_file.write(err + "\n")

def main():
    # 1. Determine Mode (Command line argument or Interactive)
    force_arg = "--force-delete" in sys.argv
    
    print("--- Folder Cleanup Tool ---")
    if not force_arg:
        confirm = input("Run in ACTUAL DELETE mode? (y/n - default is Dry Run): ").strip().lower()
        is_dry_run = False if confirm == 'y' else True
    else:
        is_dry_run = False

    # 2. Get User Options
    print("\nCleanup Options:")
    print("1. Delete entire folders")
    print("2. Delete only contents (keep main folder)")
    choice = input("Enter choice [1/2]: ").strip()
    DELETE_ONLY_CONTENTS = True if choice == "2" else False

    recreate = "n"
    if not DELETE_ONLY_CONTENTS:
        recreate = input("Recreate folders after deletion? (y/n): ").strip().lower()
    RECREATE_SOURCE = True if recreate == "y" else False

    # 3. Setup Logging
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_filename = f"cleanup_log_{timestamp}.txt"
    mode_text = "FORCE DELETE" if not is_dry_run else "DRY RUN"

    with open(log_filename, 'w', encoding='utf-8') as log_file:
        log_file.write(f"Cleanup Log - {datetime.datetime.now()}\n")
        log_file.write(f"Mode: {mode_text}\n\n")

        print(f"\nStarting {mode_text}...")
        
        for folder in TARGET_FOLDERS:
            full_path = expand_path(folder)
            clean_folder(full_path, DELETE_ONLY_CONTENTS, RECREATE_SOURCE, is_dry_run, log_file)

    print(f"\nFinished. Detailed log saved to: {log_filename}")
    if is_dry_run:
        print("NOTE: This was a DRY RUN. No files were actually removed.")

if __name__ == "__main__":
    main()
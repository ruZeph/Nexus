# GDrive Image Hosting Batch Processor

A specialized Python utility designed to convert standard Google Drive share links into direct-hosting URLs. It generates high-quality (HQ) direct links, uncompressed thumbnails, and ready-to-use Markdown code for web hosting and documentation.

## ✨ Features

* **Dual Mode Operation**: Switch between processing a single link manually or batch-processing entire files.
* **Visual File Picker**: Use a native OS file explorer to select your input files—no more manual path typing.
* **Smart ID Extraction**: Robust Regex patterns automatically find Drive IDs in `/d/`, `id=`, or `file/d/` formats.
* **Multi-Format Support**: Reads input from `.txt`, `.csv`, `.xlsx`, and `.xls` files.
* **Structured Output**: Generates a clean Excel report containing:
* **LH3 HQ Link**: Direct CDN link with `=s0` for original resolution.
* **Thumbnail (1000px)**: Resized preview via the `sz=w1000` parameter.
* **Direct View & Embed Links**: Standard web-compatible formats.
* **Markdown**: Pre-formatted syntax for instant copy-pasting.

## 🛠️ Installation

Ensure you have Python installed, then install the necessary dependencies for Excel and data processing:

```bash
pip install pandas openpyxl

```

## 🚀 How to Use

1. **Run the script**:

```bash
python get_hq_links.py

```

1. **Select Mode**:

* Choose `1` to paste a single link and see the results in your terminal.
* Choose `2` to trigger the **File Picker**.

1. **Pick your Input**: Select a text file or spreadsheet where your links are listed (one per row).
2. **Retrieve Output**: The script will generate a file named `processed_gdrive_links.xlsx` in the same folder.

## 📂 Example Input Formats

The script is flexible and can extract IDs from rows that look like this:

* `https://drive.google.com/file/d/1A2B3C4D5E6F7G8H9I0J/view?usp=sharing`
* `https://drive.google.com/open?id=1A2B3C4D5E6F7G8H9I0J`
* `1A2B3C4D5E6F7G8H9I0J` (Raw IDs are also accepted)

---

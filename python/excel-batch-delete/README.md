# Excel Batch Delete

Part of the **[Nexus](../../README.md)** toolkit — `python/excel-batch-delete/`.

> **Status: broken — do not use.** Kept for reference only, as noted in the main README.

GUI tool built on `openpyxl` for deleting large batches of rows from an `.xlsx`/`.xlsm`
workbook, written when Excel's own UI choked on row-by-row deletes.

## Intended behaviour

1. Pick the workbook with a file dialog.
2. Walk each sheet and delete the matching rows bottom-up, so indices stay valid.
3. Save to `"<name>_fixed.xlsx"` — the input file is never overwritten.

## Requirements

```bat
pip install openpyxl
```

## Notes

- Deleting rows in a big sheet is O(n²) in `openpyxl` (every delete shifts the rest), so a
  filter-plus-rebuild approach is usually the right answer instead.
- Formulas, merged cells, charts and styles in shifted rows are not preserved reliably — that
  is the known breakage behind the status warning.
- For a working replacement, filter rows with Power Query / `pandas` and rewrite the sheet.

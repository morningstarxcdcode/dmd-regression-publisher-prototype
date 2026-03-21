# Command Chart Index

This index ties the summary CSV to the generated SVG charts.

- Total commands: 11
- Pass: 11
- Fail: 0
- Timeout: 0

## Dataset
- Label: manual_smoke

## Chart Pipeline

```mermaid
flowchart TD
    A["DataAnalysisExpert/manual_smoke_summary.csv\ncommand summary rows"] --> B["generate_command_charts.py\nCSV reader + SVG renderer"]
    B --> C["manual_smoke_status_counts.svg\nstatus distribution"]
    B --> D["manual_smoke_duration_by_target.svg\nduration by entry"]
    B --> E["manual_smoke_chart_index.md\nchart index"]
    C --> E
    D --> E
```

## Generated Graph Files
- manual_smoke_status_counts.svg
- manual_smoke_duration_by_target.svg

## Source
- DataAnalysisExpert/manual_smoke_summary.csv

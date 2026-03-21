# Command Chart Index

This index ties the summary CSV to the generated SVG charts.

- Total commands: 11
- Pass: 11
- Fail: 0
- Timeout: 0

## Dataset
- Label: smoke

## Chart Pipeline

```mermaid
flowchart TD
    A["DataAnalysisExpert/smoke_command_summary.csv\ncommand summary rows"] --> B["generate_command_charts.py\nCSV reader + SVG renderer"]
    B --> C["smoke_status_counts.svg\nstatus distribution"]
    B --> D["smoke_duration_by_target.svg\nduration by entry"]
    B --> E["smoke_chart_index.md\nchart index"]
    C --> E
    D --> E
```

## Generated Graph Files
- smoke_status_counts.svg
- smoke_duration_by_target.svg

## Source
- DataAnalysisExpert/smoke_command_summary.csv

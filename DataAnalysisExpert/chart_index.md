# Command Chart Index

This index ties the summary CSV to the generated SVG charts.

- Total commands: 16
- Pass: 16
- Fail: 0
- Timeout: 0

## Dataset
- Label: command

## Chart Pipeline

```mermaid
flowchart TD
    A["DataAnalysisExpert/command_run_summary.csv\ncommand summary rows"] --> B["generate_command_charts.py\nCSV reader + SVG renderer"]
    B --> C["command_status_counts.svg\nstatus distribution"]
    B --> D["command_duration_by_target.svg\nduration by entry"]
    B --> E["chart_index.md\nchart index"]
    C --> E
    D --> E
```

## Generated Graph Files
- command_status_counts.svg
- command_duration_by_target.svg

## Source
- DataAnalysisExpert/command_run_summary.csv

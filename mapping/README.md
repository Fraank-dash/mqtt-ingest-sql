# Topic Mapping Workbook

`result_export.xlsx` is the project-specific mapping workbook used by
`scripts/import-topic-mapping-xlsx.sh`.

For future migrations, copy `result_export-template.xlsx` or
`result_export-template.csv` and fill worksheet `Tabelle2` with these columns:

| Column | Required | Meaning |
| --- | --- | --- |
| `<new-mqtt-device-name>` | yes | Device name used in the current target topic, without the leading `shellies/`. |
| `<old-mqtt-device-name>` | yes | Device name used in the legacy topic after the leading `shellies/`. |
| `<very-old-mqtt-device-name>` | no | Optional older alias. May intentionally include `shellies/` for legacy double-prefix topics such as `shellies/shellies/BV...`. |
| `<not-in-use>` | no | Any non-empty value marks the row as skipped unless the importer is run with `--include-not-in-use`. |
| `notes` | no | Human-only context. Ignored by the importer. |

The importer turns each device row into regex mappings like:

```text
^shellies/<old-mqtt-device-name>/(.*)$ -> shellies/<new-mqtt-device-name>/\1
```

It applies the same device mapping to all supported legacy MQTT source tables.

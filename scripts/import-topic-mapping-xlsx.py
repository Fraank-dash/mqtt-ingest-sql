#!/usr/bin/env python3
import argparse
import csv
import posixpath
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG_REL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"

SOURCE_TABLE_KINDS = (
    ("public.mqtt_power", "measurement"),
    ("public.mqtt_energy", "measurement"),
    ("public.mqtt_status", "status"),
    ("public.mqtt_switch", "measurement"),
    ("public.mqtt_online", "status"),
    ("public.mqtt_infos", "status"),
    ("public.mqtt_announcements", "status"),
    ("public.mqtt_dump", "status"),
    ("public.mqtt_topics", "topic_inventory"),
)

DEFAULT_RULES = (
    {
        "priority": 20,
        "source_table": "public.mqtt_topics",
        "rule_type": "prefix",
        "source_pattern": "$SYS/",
        "target_topic": "$SYS/",
        "target_kind": "topic_inventory",
        "notes": "Default broker topic inventory mapping",
    },
)


def column_number(cell_ref):
    match = re.match(r"([A-Z]+)", cell_ref)
    if not match:
        return 0
    number = 0
    for char in match.group(1):
        number = number * 26 + ord(char) - ord("A") + 1
    return number


def shared_strings(zip_file):
    try:
        root = ET.fromstring(zip_file.read("xl/sharedStrings.xml"))
    except KeyError:
        return []

    values = []
    for item in root.findall(f"{MAIN_NS}si"):
        parts = [text.text or "" for text in item.iter(f"{MAIN_NS}t")]
        values.append("".join(parts))
    return values


def sheet_path(zip_file, sheet_name):
    workbook = ET.fromstring(zip_file.read("xl/workbook.xml"))
    relationships = ET.fromstring(zip_file.read("xl/_rels/workbook.xml.rels"))
    targets = {
        rel.attrib["Id"]: rel.attrib["Target"]
        for rel in relationships.findall(f"{PKG_REL_NS}Relationship")
    }

    for sheet in workbook.find(f"{MAIN_NS}sheets"):
        if sheet.attrib.get("name") == sheet_name:
            relationship_id = sheet.attrib.get(f"{REL_NS}id")
            target = targets[relationship_id]
            return posixpath.normpath(posixpath.join("xl", target))

    raise ValueError(f"worksheet not found: {sheet_name}")


def worksheet_rows(workbook_path, sheet_name):
    with ZipFile(workbook_path) as zip_file:
        strings = shared_strings(zip_file)
        path = sheet_path(zip_file, sheet_name)
        root = ET.fromstring(zip_file.read(path))

    rows = []
    for row in root.iter(f"{MAIN_NS}row"):
        values = {}
        for cell in row.findall(f"{MAIN_NS}c"):
            value_node = cell.find(f"{MAIN_NS}v")
            if value_node is None:
                value = ""
            elif cell.attrib.get("t") == "s":
                value = strings[int(value_node.text)]
            else:
                value = value_node.text or ""
            values[column_number(cell.attrib.get("r", ""))] = value.strip()
        if values:
            rows.append([values.get(index, "") for index in range(1, max(values) + 1)])
    return rows


def normalized_old_device(value):
    return value.strip().strip("/")


def mapping_rows(workbook_path, sheet_name, include_not_in_use):
    rows = worksheet_rows(workbook_path, sheet_name)
    if not rows:
        return []

    header = [column.strip() for column in rows[0]]
    index = {name: offset for offset, name in enumerate(header)}
    required = ["<new-mqtt-device-name>", "<old-mqtt-device-name>"]
    missing = [name for name in required if name not in index]
    if missing:
        raise ValueError(f"missing required column(s): {', '.join(missing)}")

    not_in_use_index = index.get("<not-in-use>")
    very_old_index = index.get("<very-old-mqtt-device-name>")
    generated = [dict(row) for row in DEFAULT_RULES]
    seen = {
        (
            row["source_table"],
            row["source_pattern"],
            row["target_topic"],
            row["target_kind"],
        )
        for row in generated
    }

    for row_number, row in enumerate(rows[1:], start=2):
        def value(column_name):
            offset = index.get(column_name)
            if offset is None or offset >= len(row):
                return ""
            return row[offset].strip()

        marker = ""
        if not_in_use_index is not None and not_in_use_index < len(row):
            marker = row[not_in_use_index].strip()
        if marker and not include_not_in_use:
            continue

        new_device = value("<new-mqtt-device-name>").strip().strip("/")
        old_devices = [normalized_old_device(value("<old-mqtt-device-name>"))]
        if very_old_index is not None and very_old_index < len(row):
            old_devices.append(normalized_old_device(row[very_old_index]))

        for old_device in old_devices:
            if not old_device or not new_device:
                continue
            source_pattern = rf"^shellies/{re.escape(old_device)}/(.*)$"
            target_topic = rf"shellies/{new_device}/\1"
            for source_table, target_kind in SOURCE_TABLE_KINDS:
                key = (source_table, source_pattern, target_topic, target_kind)
                if key in seen:
                    continue
                seen.add(key)
                generated.append(
                    {
                        "priority": 100,
                        "source_table": source_table,
                        "rule_type": "regex",
                        "source_pattern": source_pattern,
                        "target_topic": target_topic,
                        "target_kind": target_kind,
                        "notes": f"Imported from {sheet_name} row {row_number}",
                    }
                )
    return generated


def add_device_alias_rules(rows, old_device, new_device, notes):
    source_pattern = rf"^shellies/{re.escape(normalized_old_device(old_device))}/(.*)$"
    target_topic = rf"shellies/{new_device.strip().strip('/')}/\1"
    existing = {
        (
            row["source_table"],
            row["source_pattern"],
            row["target_topic"],
            row["target_kind"],
        )
        for row in rows
    }
    for source_table, target_kind in SOURCE_TABLE_KINDS:
        key = (source_table, source_pattern, target_topic, target_kind)
        if key in existing:
            continue
        existing.add(key)
        rows.append(
            {
                "priority": 90,
                "source_table": source_table,
                "rule_type": "regex",
                "source_pattern": source_pattern,
                "target_topic": target_topic,
                "target_kind": target_kind,
                "notes": notes,
            }
        )


def write_csv(rows, path):
    fieldnames = [
        "priority",
        "source_table",
        "rule_type",
        "source_pattern",
        "target_topic",
        "target_kind",
        "notes",
    ]
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def apply_rows(database_url, rows):
    with tempfile.NamedTemporaryFile("w", newline="", encoding="utf-8", suffix=".csv") as temp_file:
        write_csv(rows, temp_file.name)
        temp_file.flush()
        csv_path = temp_file.name.replace("'", "''")
        sql = rf"""
CREATE TEMP TABLE mqtt_migration_topic_mapping_import (
    priority INTEGER,
    source_table TEXT,
    rule_type TEXT,
    source_pattern TEXT,
    target_topic TEXT,
    target_kind TEXT,
    notes TEXT
);
\copy mqtt_migration_topic_mapping_import FROM '{csv_path}' WITH (FORMAT csv, HEADER true)
INSERT INTO mqtt_migration.topic_mapping (
    priority,
    source_table,
    rule_type,
    source_pattern,
    target_topic,
    target_kind,
    notes
)
SELECT
    priority,
    source_table,
    rule_type,
    source_pattern,
    target_topic,
    target_kind,
    notes
FROM mqtt_migration_topic_mapping_import
WHERE NOT EXISTS (
    SELECT 1
    FROM mqtt_migration.topic_mapping existing
    WHERE existing.source_table = mqtt_migration_topic_mapping_import.source_table
      AND existing.rule_type = mqtt_migration_topic_mapping_import.rule_type
      AND existing.source_pattern = mqtt_migration_topic_mapping_import.source_pattern
      AND existing.target_topic = mqtt_migration_topic_mapping_import.target_topic
      AND existing.target_kind = mqtt_migration_topic_mapping_import.target_kind
);
"""
        subprocess.run(
            [
                "psql",
                database_url,
                "-v",
                "ON_ERROR_STOP=1",
            ],
            input=sql,
            text=True,
            check=True,
        )


def main():
    parser = argparse.ArgumentParser(
        description="Import topic mapping rules from result_export.xlsx Tabelle2."
    )
    parser.add_argument("workbook", help="Path to result_export.xlsx")
    parser.add_argument("--sheet", default="Tabelle2", help="Worksheet name")
    parser.add_argument("--database-url", help="Apply rules to this PostgreSQL database")
    parser.add_argument("--output-csv", help="Write generated mapping rows to CSV instead of applying")
    parser.add_argument(
        "--include-not-in-use",
        action="store_true",
        help="Also import rows marked Not in Use",
    )
    parser.add_argument(
        "--alias",
        action="append",
        default=[],
        metavar="OLD_DEVICE=NEW_DEVICE",
        help="Add an explicit historical device alias, for example BV.SR.SY.PLG.Server=shellyplug-F43A50",
    )
    args = parser.parse_args()

    rows = mapping_rows(Path(args.workbook), args.sheet, args.include_not_in_use)
    for alias in args.alias:
        if "=" not in alias:
            raise ValueError(f"invalid alias, expected OLD_DEVICE=NEW_DEVICE: {alias}")
        old_device, new_device = alias.split("=", 1)
        add_device_alias_rules(
            rows,
            old_device,
            new_device,
            f"Explicit historical alias imported from --alias {old_device}={new_device}",
        )
    if args.output_csv:
        write_csv(rows, args.output_csv)
    elif args.database_url:
        apply_rows(args.database_url, rows)
    else:
        writer = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()) if rows else [])
        if rows:
            writer.writeheader()
            writer.writerows(rows)

    print(f"Generated {len(rows)} topic mapping rows.", file=sys.stderr)


if __name__ == "__main__":
    main()

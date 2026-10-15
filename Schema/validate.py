"""Validates presentation.json files against the format schema.

Usage: python3 Schema/validate.py [path ...]
With no paths, validates every example under Schema/examples and the documents
embedded in the test vectors under Schema/vectors.
Needs the jsonschema package (pip install "jsonschema>=4.18").
"""
import glob
import json
import os
import sys

from jsonschema import Draft202012Validator

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "controlflow-1.0.schema.json")) as f:
    schema = json.load(f)
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)


def documents():
    """(label, document) for each file to check."""
    if sys.argv[1:]:
        for path in sys.argv[1:]:
            with open(path) as f:
                yield path, json.load(f)
        return
    for path in sorted(glob.glob(os.path.join(here, "examples", "*", "presentation.json"))):
        with open(path) as f:
            yield path, json.load(f)
    for path in sorted(glob.glob(os.path.join(here, "vectors", "*.json"))):
        with open(path) as f:
            vectors = json.load(f)
        # A vector names its document's file, or holds the document itself.
        if isinstance(vectors.get("document"), dict):
            yield path + " (document)", vectors["document"]


failed = False
count = 0
for label, document in documents():
    count += 1
    errors = sorted(validator.iter_errors(document), key=lambda e: list(e.path))
    for error in errors:
        location = "/".join(str(p) for p in error.path) or "(root)"
        print(f"{label}: {location}: {error.message}")
    failed = failed or bool(errors)
    if not errors:
        print(f"{label}: valid")
if count == 0:
    sys.exit("No files to validate")
sys.exit(1 if failed else 0)

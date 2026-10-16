"""Validates presentation.json files against the format schema, and math.json files
against the formula layouts' schema.

Usage: python3 Schema/validate.py [path ...]
With no paths, validates every example under Schema/examples (with its math.json, if
any), and the documents and formula layouts in the test vectors under Schema/vectors.
A path named math.json is checked as formula layouts.
Needs the jsonschema package (pip install "jsonschema>=4.18").
"""
import glob
import json
import os
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

here = os.path.dirname(os.path.abspath(__file__))


def load_schema(name):
    with open(os.path.join(here, name)) as f:
        schema = json.load(f)
    Draft202012Validator.check_schema(schema)
    return schema


presentation_schema = load_schema("controlflow-1.0.schema.json")
math_schema = load_schema("math-1.0.schema.json")
# math.json refers to the presentation schema's formula by its file name.
registry = Registry().with_resources(
    [(schema["$id"], Resource.from_contents(schema)) for schema in (presentation_schema, math_schema)]
)
validators = {
    "presentation": Draft202012Validator(presentation_schema, registry=registry),
    "math": Draft202012Validator(math_schema, registry=registry),
}


def documents():
    """(label, kind, document) for each file to check."""
    if sys.argv[1:]:
        for path in sys.argv[1:]:
            with open(path) as f:
                yield path, "math" if os.path.basename(path) == "math.json" else "presentation", json.load(f)
        return
    for path in sorted(glob.glob(os.path.join(here, "examples", "*", "presentation.json"))):
        with open(path) as f:
            yield path, "presentation", json.load(f)
        math = os.path.join(os.path.dirname(path), "math.json")
        if os.path.exists(math):
            with open(math) as f:
                yield math, "math", json.load(f)
    for path in sorted(glob.glob(os.path.join(here, "vectors", "*.json"))):
        with open(path) as f:
            vectors = json.load(f)
        # A vector names its document's file, or holds the document itself.
        if isinstance(vectors.get("document"), dict):
            yield path + " (document)", "presentation", vectors["document"]
        if isinstance(vectors.get("math"), dict):
            yield path + " (math)", "math", vectors["math"]


failed = False
count = 0
for label, kind, document in documents():
    count += 1
    errors = sorted(validators[kind].iter_errors(document), key=lambda e: list(e.path))
    for error in errors:
        location = "/".join(str(p) for p in error.path) or "(root)"
        print(f"{label}: {location}: {error.message}")
    failed = failed or bool(errors)
    if not errors:
        print(f"{label}: valid")
if count == 0:
    sys.exit("No files to validate")
sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""Print the ReadOnlyViewPolicy document of infra/iam-readonly.yaml as plain JSON.

Usage: python3 -I scripts/extract-policy.py [template] > build/readonly-policy.json
Fails (exit 1) if the document contains an intrinsic function (Ref or Fn::).
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from cfn_yaml import load_template  # noqa: E402


def has_intrinsic(node):
    if isinstance(node, dict):
        if any(k == "Ref" or str(k).startswith("Fn::") for k in node):
            return True
        return any(has_intrinsic(v) for v in node.values())
    if isinstance(node, list):
        return any(has_intrinsic(v) for v in node)
    return False


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "infra", "iam-readonly.yaml")
    template = load_template(path)
    doc = template["Resources"]["ReadOnlyViewPolicy"]["Properties"]["PolicyDocument"]
    if has_intrinsic(doc):
        print("error: policy document contains an intrinsic function", file=sys.stderr)
        return 1
    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

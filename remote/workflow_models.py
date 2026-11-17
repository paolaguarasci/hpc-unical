"""Run on the cluster by `hpc model template` and `hpc model comfy --workflow`: the models that a ComfyUI workflow
declares (directory, file name and download URL), which the "Missing models" panel of ComfyUI reads too.

The script text is passed with `python -c`, so that standard input stays free for a workflow.

usage: python -c SCRIPT MODE ARG
  models template NAME   print "URL<TAB>DIRECTORY<TAB>NAME" for each model of the ComfyUI template NAME
  models stdin -         the same for the workflow JSON read from standard input
  list TEXT              one line per template (whose name contains TEXT) that declares models: how many are present
"""
import glob
import importlib.util
import json
import os
import sys

HOME = os.path.expanduser("~")
MODELS = os.path.join(HOME, "comfy", "ComfyUI", "models")


def declared(workflow):
    """The models of a workflow, found anywhere in it (subgraphs included), once each."""
    found = {}

    def walk(node):
        if isinstance(node, dict):
            if {"name", "url", "directory"} <= node.keys():
                found.setdefault((node["directory"], node["name"]), node)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(workflow)
    return list(found.values())


def templates_dir():
    spec = importlib.util.find_spec("comfyui_workflow_templates_json")
    if spec is None:
        sys.exit("FAIL - the ComfyUI templates are not installed: run hpc setup comfy")
    return os.path.join(list(spec.submodule_search_locations)[0], "templates")


def present(model):
    return os.path.isfile(os.path.join(MODELS, model["directory"], model["name"]))


def models(source, name):
    if source == "stdin":
        workflow = json.load(sys.stdin)
    else:
        path = os.path.join(templates_dir(), name + ".json")
        if os.path.basename(name) != name or not os.path.isfile(path):
            sys.exit(f"FAIL - no template named '{name}': see hpc model template list")
        with open(path) as f:
            workflow = json.load(f)
    for model in declared(workflow):
        print(f"{model['url']}\t{model['directory']}\t{model['name']}")


def listing(text):
    rows = []
    for path in sorted(glob.glob(os.path.join(templates_dir(), "*.json"))):
        name = os.path.basename(path)[:-5]
        if text not in name.lower():
            continue
        with open(path) as f:
            found = declared(json.load(f))
        if not found:  # the templates of the cloud APIs declare no files
            continue
        count = sum(present(m) for m in found)
        mark = "[x]" if count == len(found) else "[ ]" if count == 0 else "[~]"
        rows.append([mark, f"{count}/{len(found)}", name])
    widths = [max(len(r[i]) for r in rows + [["", "present", "template"]]) for i in range(3)]
    for row in [["", "present", "template"]] + rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
    print(f"{len(rows)} templates with models")


if __name__ == "__main__":
    if sys.argv[1] == "models":
        models(sys.argv[2], sys.argv[3])
    else:
        listing(sys.argv[2].lower())

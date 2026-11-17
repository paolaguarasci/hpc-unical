"""Run on the cluster by `hpc model list`: ComfyUI models of the ComfyUI-Manager catalogue and the Ollama models
installed, each marked present or not.

usage: python model_list.py TARGET TYPE TEXT URLS
  TARGET  all, comfy or ollama
  TYPE    only the ComfyUI models of this catalogue type ("" for all)
  TEXT    only the models whose name, file, base or folder contains this text ("" for all)
  URLS    1 to add the download URL of each ComfyUI model
"""
import importlib.util
import json
import os
import sys

HOME = os.path.expanduser("~")
# Folder of a catalogue entry whose save_path is "default": the one ComfyUI-Manager chooses by type.
DEFAULT_FOLDER = {"VAE": "vae", "clip": "text_encoders", "diffusion_model": "diffusion_models", "upscale": "upscale_models"}


def human(size):
    return f"{size / 1024 ** 3:.1f} GB"


def table(header, rows):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    for r in [header] + rows:
        print("  ".join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip())


def comfy(model_type, text, urls):
    print("== ComfyUI models (catalogue of ComfyUI-Manager; target folder under ~/comfy/ComfyUI/models)")
    spec = importlib.util.find_spec("comfyui_manager")
    if spec is None:
        print("FAIL - ComfyUI-Manager is not installed: run hpc setup comfy")
        return 1
    with open(os.path.join(os.path.dirname(spec.origin), "model-list.json")) as f:
        models = json.load(f)["models"]
    root = os.path.join(HOME, "comfy", "ComfyUI", "models")
    rows = []
    for m in models:
        folder = DEFAULT_FOLDER.get(m["type"], "?") if m["save_path"] == "default" else m["save_path"]
        haystack = " ".join([m["name"], m["filename"], m["base"], folder]).lower()
        if (model_type and m["type"].lower() != model_type.lower()) or text not in haystack:
            continue
        present = os.path.isfile(os.path.join(root, folder, m["filename"]))
        row = ["[x]" if present else "[ ]", m["type"], folder, m["size"], m["name"], m["filename"]]
        rows.append(row + [m["url"]] if urls else row)
    rows.sort(key=lambda r: (r[1].lower(), r[2], r[4]))
    header = ["", "type", "folder", "size", "name", "file"] + (["url"] if urls else [])
    table(header, rows)
    print(f"{len(rows)} models, {sum(r[0] == '[x]' for r in rows)} present")
    return 0


def ollama(text):
    print("== Ollama models (installed only; the catalogue is https://ollama.com/library, download with: hpc model ollama NAME)")
    store = os.path.join(HOME, ".ollama", "models", "manifests")
    rows = []
    for folder, _, tags in os.walk(store):
        for tag in tags:
            host, namespace, *model = os.path.relpath(folder, store).split(os.sep)
            name = ("" if namespace == "library" else namespace + "/") + "/".join(model) + ":" + tag
            with open(os.path.join(folder, tag)) as f:
                manifest = json.load(f)
            size = sum(layer["size"] for layer in manifest["layers"] + [manifest["config"]])
            if text in name.lower():
                rows.append(["[x]", human(size), name])
    if rows:
        table(["", "size", "name"], sorted(rows, key=lambda r: r[2]))
    print(f"{len(rows)} models installed")
    return 0


def main(target, model_type, text, urls):
    status = 0
    if target in ("all", "comfy"):
        status |= comfy(model_type, text.lower(), urls)
    if target == "all":
        print()
    if target in ("all", "ollama"):
        status |= ollama(text.lower())
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"))

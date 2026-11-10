"""Shared plumbing for the face-restoration model conversions
(make_face_restoration.py, make_face_gfpgan.py, make_face_codeformer.py).

Each conversion fetches an upstream PyTorch checkpoint (pinned by URL and
SHA-256) and the upstream source that defines its network (pinned by commit),
exports it to ONNX with the TorchScript exporter at a fixed opset and IR
version, and checks the ONNX model against PyTorch on the same inputs.

Opset 17 / IR 8 keeps every model loadable by the oldest ONNX Runtime the
ai-runtime add-on pins (1.23.2, the last with an Intel macOS wheel).

Run in the conversion venv (docs/ADDONS.md). The work directory caches the
downloads; it defaults to addon-staging/face-work at the repo root
(FACE_MODELS_WORK overrides it, VAPOURBOX_ADDON_STAGING the staging directory).
"""

import hashlib
import io
import json
import os
import sys
import tarfile
import time
import types
import urllib.request

import numpy as np

OPSET = 17
IR_VERSION = 8

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STAGING = os.environ.get("VAPOURBOX_ADDON_STAGING") or os.path.join(REPO_ROOT, "addon-staging")


def work_dir():
    d = os.environ.get("FACE_MODELS_WORK") or os.path.join(STAGING, "face-work")
    os.makedirs(d, exist_ok=True)
    return d


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, sha256):
    """Download `url` into the work directory's ckpt/ (once) and check its hash."""
    dest_dir = os.path.join(work_dir(), "ckpt")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, url.rsplit("/", 1)[1])
    if not os.path.exists(dest):
        print(f"downloading {url}")
        tmp = dest + ".partial"
        urllib.request.urlretrieve(url, tmp)
        os.replace(tmp, dest)
    got = sha256_of(dest)
    if got != sha256:
        raise SystemExit(f"{dest}: SHA-256 {got}, expected {sha256}")
    return dest


def upstream_source(repo, commit):
    """Unpack github.com/<repo> at `commit` into the work directory's src/ and
    return its path. Only the Python files are needed (the network classes)."""
    name = repo.split("/")[1]
    dest = os.path.join(work_dir(), "src", f"{name}-{commit[:12]}")
    if not os.path.isdir(dest):
        url = f"https://codeload.github.com/{repo}/tar.gz/{commit}"
        print(f"downloading {url}")
        data = urllib.request.urlopen(url).read()
        os.makedirs(dest + ".partial", exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            for m in tar.getmembers():
                parts = m.name.split("/", 1)
                if len(parts) < 2 or not m.isfile() or not m.name.endswith(".py"):
                    continue
                m.name = parts[1]
                tar.extract(m, dest + ".partial", filter="data")
        os.replace(dest + ".partial", dest)
    return dest


def stub_module(name, **attrs):
    """Insert an empty module (and its parents) into sys.modules, so upstream
    code that imports training-only helpers can be imported for its network
    classes alone."""
    parts = name.split(".")
    for i in range(1, len(parts) + 1):
        sub = ".".join(parts[:i])
        if sub not in sys.modules:
            mod = types.ModuleType(sub)
            mod.__path__ = []
            sys.modules[sub] = mod
            if i > 1:
                setattr(sys.modules[".".join(parts[: i - 1])], parts[i - 1], mod)
    for k, v in attrs.items():
        setattr(sys.modules[name], k, v)
    return sys.modules[name]


class Registry:
    """Stand-in for basicsr's ARCH_REGISTRY: register() is a no-op decorator."""

    def register(self, *args, **kwargs):
        if args and callable(args[0]):
            return args[0]
        return lambda cls: cls


def load_checkpoint(path):
    import torch

    return torch.load(path, map_location="cpu", weights_only=True)


def export(model, inputs, input_names, output_names, out_path, dynamic_axes=None):
    """Export `model` (in eval mode) with the TorchScript exporter at OPSET,
    stamp IR_VERSION, check it, and return the file's size and SHA-256."""
    import onnx
    import torch

    model.eval()
    tmp = out_path + ".tmp"
    with torch.no_grad():
        torch.onnx.export(
            model,
            tuple(inputs),
            tmp,
            input_names=input_names,
            output_names=output_names,
            opset_version=OPSET,
            dynamic_axes=dynamic_axes,
            do_constant_folding=True,
            dynamo=False,
        )
    m = onnx.load(tmp)
    m.ir_version = IR_VERSION
    m.producer_name = "vapourbox"
    onnx.checker.check_model(m)
    onnx.save(m, out_path)
    os.remove(tmp)
    return {"file": os.path.basename(out_path), "size": os.path.getsize(out_path), "sha256": sha256_of(out_path)}


def parity(model, onnx_path, feeds, providers=("CPUExecutionProvider",)):
    """Max and mean absolute difference between PyTorch and ONNX Runtime on
    the same inputs, per output, and the time ONNX Runtime took."""
    import onnxruntime as ort
    import torch

    with torch.no_grad():
        ref = model(*[torch.from_numpy(v) for v in feeds.values()])
    if not isinstance(ref, (tuple, list)):
        ref = [ref]
    ref = [r.numpy() for r in ref if isinstance(r, torch.Tensor)]
    sess = ort.InferenceSession(onnx_path, providers=list(providers))
    t0 = time.perf_counter()
    got = sess.run(None, feeds)
    dt = time.perf_counter() - t0
    out = []
    for name, a, b in zip([o.name for o in sess.get_outputs()], ref, got):
        d = np.abs(a.astype(np.float64) - b.astype(np.float64))
        out.append({"output": name, "max": float(d.max()), "mean": float(d.mean())})
    return {"providers": list(providers), "seconds": dt, "outputs": out}


def write_record(name, record):
    """Write the conversion record (sizes, hashes, parity) beside the models."""
    path = os.path.join(STAGING, f"{name}.conversion.json")
    with open(path, "w") as f:
        json.dump(record, f, indent=2)
    print(json.dumps(record, indent=2))
    return path


def face_test_input(seed=0):
    """A deterministic face-like 512x512 test input in [-1, 1]: smooth blobs
    plus noise, so the networks see structure rather than pure noise."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:512, 0:512].astype(np.float32) / 512.0
    img = np.stack(
        [
            0.6 * np.exp(-((x - 0.5) ** 2 + (y - 0.5) ** 2) / 0.08) - 0.2,
            0.5 * np.exp(-((x - 0.5) ** 2 + (y - 0.45) ** 2) / 0.06) - 0.3,
            0.4 * np.exp(-((x - 0.5) ** 2 + (y - 0.55) ** 2) / 0.1) - 0.35,
        ]
    )
    img += rng.normal(0, 0.05, img.shape).astype(np.float32)
    return np.clip(img, -1, 1)[None].astype(np.float32)

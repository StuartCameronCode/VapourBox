"""
ONNX Runtime for VapourSynth scripts, from the ai-runtime add-on.

The ai-runtime add-on (app/assets/addons/ai-runtime.json) unpacks ONNX Runtime
and NumPy wheels into <addons>/ai-runtime/site-packages/. Passes that run a
model the VSNCNN plugin can't (per-crop inference, models with more than one
input, anything needing NumPy around the network) use them through this
module, which ships beside pipe_source.py in the templates directory.

    import ai_runtime
    ai_runtime.setup(r"<addons>/ai-runtime")          # the {{#AI_RUNTIME}} block
    sess = ai_runtime.session(r"<addons>/my-model/model.onnx")
    clip = ai_runtime.map_frames(clip, lambda x: sess.run(None, {"input": x})[0],
                                 width=clip.width * 2, height=clip.height * 2)

setup() puts the add-on's packages on sys.path itself rather than relying on
PYTHONPATH, because Windows' embeddable Python ignores PYTHONPATH (its ._pth
file fixes sys.path), and registers onnxruntime's DLL directory there.

Execution providers are chosen in this order, from those the installed wheel
offers: TensorRT, CUDA (neither is in today's wheels; a future NVIDIA add-on
can add them by passing its own directory to setup() first), DirectML
(Windows), Core ML (macOS), then the CPU. VAPOURBOX_AI_FORCE_CPU=1, or
force_cpu=True, uses the CPU only. A session that fails to create on a GPU
provider is retried on the CPU, and the reason is kept in last_fallback.

`vapourbox-worker --probe-ai-runtime` calls self_test() through vspipe.
"""

import base64
import os
import sys
import threading

ADDON_ID = "ai-runtime"
FORCE_CPU_ENV = "VAPOURBOX_AI_FORCE_CPU"

# Most-preferred first. Only those the installed onnxruntime reports as
# available are used; the CPU is always last.
GPU_PROVIDERS = [
    "TensorrtExecutionProvider",
    "CUDAExecutionProvider",
    "DmlExecutionProvider",
    "CoreMLExecutionProvider",
]
CPU_PROVIDER = "CPUExecutionProvider"

# Options per provider. Core ML's MLProgram format supports more operators
# than the older NeuralNetwork format and runs on the GPU and Neural Engine.
PROVIDER_OPTIONS = {
    "CoreMLExecutionProvider": {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"},
}

# y = x * 2 + 1 over a float32 (1, 3, h, w) tensor, IR 8 / opset 13. Built by
# Scripts/models/make_ai_runtime_selftest.py; the same bytes are committed as
# Tests/TestResources/ai_runtime_selftest.onnx (a test asserts they agree).
_SELFTEST_MODEL_B64 = (
    "CAgSCXZhcG91cmJveDqWAQoRCgF4CgN0d28SAngyIgNNdWwKEQoCeDIKA29uZRIBeSIDQWRkEhJ2YXBvdXJib3hfc2VsZnRlc3Qq"
    "DRABIgQAAABAQgN0d28qDRABIgQAAIA/QgNvbmVaHQoBeBIYChYIARISCgIIAQoCCAMKAxIBaAoDEgF3Yh0KAXkSGAoWCAESEgoC"
    "CAEKAggDCgMSAWgKAxIBd0IECgAQDQ=="
)

_lock = threading.Lock()
_sessions = {}
_dll_dirs = []
_ort = None

# Why the last session() call fell back to the CPU, or None.
last_fallback = None


def setup(*addon_dirs):
    """Make the add-on's packages importable. Pass the ai-runtime add-on's
    directory (and, first, any add-on that should take precedence). Safe to
    call more than once."""
    for addon_dir in reversed(addon_dirs):
        site = os.path.join(addon_dir, "site-packages")
        if not os.path.isdir(site):
            raise RuntimeError(
                "The AI runtime add-on is not installed (no %s). Install it in "
                "Settings -> Add-ons." % site
            )
        if site not in sys.path:
            sys.path.insert(0, site)
        capi = os.path.join(site, "onnxruntime", "capi")
        if os.name == "nt" and os.path.isdir(capi) and hasattr(os, "add_dll_directory"):
            # onnxruntime_pybind11_state.pyd links onnxruntime.dll and
            # DirectML.dll beside it. Keep the handle: closing it removes the
            # directory from the search path again.
            _dll_dirs.append(os.add_dll_directory(capi))


def ort():
    """The onnxruntime module (after setup())."""
    global _ort
    if _ort is None:
        import onnxruntime  # noqa: deferred until setup() has run

        _ort = onnxruntime
    return _ort


def force_cpu_requested():
    return os.environ.get(FORCE_CPU_ENV, "").strip().lower() in ("1", "true", "yes")


def available_providers():
    return list(ort().get_available_providers())


def preferred_providers(force_cpu=False):
    """The providers a session should try, most preferred first."""
    if force_cpu or force_cpu_requested():
        return [CPU_PROVIDER]
    available = set(available_providers())
    return [p for p in GPU_PROVIDERS if p in available] + [CPU_PROVIDER]


def _session_options(providers):
    rt = ort()
    opts = rt.SessionOptions()
    opts.log_severity_level = 3  # errors only: Core ML warns per unsupported node
    if "DmlExecutionProvider" in providers:
        # DirectML requires both (onnxruntime's DirectML documentation).
        opts.enable_mem_pattern = False
        opts.execution_mode = rt.ExecutionMode.ORT_SEQUENTIAL
    return opts


def _create(model, providers):
    rt = ort()
    with_options = [(p, PROVIDER_OPTIONS[p]) if p in PROVIDER_OPTIONS else p for p in providers]
    try:
        return rt.InferenceSession(model, sess_options=_session_options(providers), providers=with_options)
    except Exception:
        if with_options == providers:
            raise
        # An older runtime that doesn't know an option: the provider's defaults.
        return rt.InferenceSession(model, sess_options=_session_options(providers), providers=providers)


def session(model, force_cpu=False, providers=None):
    """An InferenceSession for `model` (a path, or the model's bytes), on the
    preferred providers unless `providers` is given. Cached per model and
    provider list, so a pass calling this from a frame callback creates it
    once. Falls back to the CPU if a GPU provider can't create it."""
    global last_fallback
    chosen = list(providers) if providers else preferred_providers(force_cpu)
    key = (model if isinstance(model, str) else hash(bytes(model)), tuple(chosen))
    with _lock:
        cached = _sessions.get(key)
        if cached is not None:
            return cached
        try:
            sess = _create(model, chosen)
            last_fallback = None
        except Exception as e:
            if chosen == [CPU_PROVIDER]:
                raise
            last_fallback = "%s: %s" % (chosen[0], e)
            sess = _create(model, [CPU_PROVIDER])
        _sessions[key] = sess
        return sess


def session_provider(sess):
    """The provider a session prefers (its first registered one)."""
    return sess.get_providers()[0]


def frame_to_nchw(frame):
    """A planar RGBS VideoFrame as a float32 (1, 3, height, width) array."""
    import numpy as np

    return np.stack([np.asarray(frame[p]) for p in range(3)])[None].astype(np.float32, copy=False)


def nchw_to_frame(array, frame):
    """Write a (1, 3, height, width) array into a writable copy of `frame`
    (planar RGBS, of the array's size) and return the copy."""
    import numpy as np

    out = frame.copy()
    data = np.asarray(array, dtype=np.float32)
    if data.ndim == 4:
        data = data[0]
    for p in range(3):
        np.copyto(np.asarray(out[p]), data[p])
    return out


def map_frames(clip, fn, width=None, height=None):
    """Apply `fn` (a float32 (1, 3, h, w) array -> a (1, 3, height, width)
    array) to every frame of a planar RGBS clip. The output is `width` x
    `height` (default: the input's) and keeps each source frame's properties."""
    import vapoursynth as vs

    core = vs.core
    if clip.format is None or clip.format.id != vs.RGBS:
        raise ValueError("ai_runtime.map_frames needs a constant-format RGBS clip")
    width = width or clip.width
    height = height or clip.height
    template = clip
    if (width, height) != (clip.width, clip.height):
        template = core.std.BlankClip(clip, width=width, height=height, keep=True)

    def _apply(n, f):
        src, dst = f[0], f[1]
        out = nchw_to_frame(fn(frame_to_nchw(src)), dst)
        for k in list(out.props.keys()):
            del out.props[k]
        out.props.update(src.props)
        return out

    return core.std.ModifyFrame(template, [clip, template], _apply)


def selftest_model():
    """The self-test model's bytes."""
    return base64.b64decode(_SELFTEST_MODEL_B64)


def frame_test(force_cpu=False):
    """Run the self-test model over a VapourSynth frame through map_frames
    (the path a pass takes: RGBS frame -> NumPy -> session -> frame) and check
    the pixels. Returns the three output plane values."""
    import numpy as np
    import vapoursynth as vs

    sess = session(selftest_model(), force_cpu=force_cpu)
    name = sess.get_inputs()[0].name
    clip = vs.core.std.BlankClip(width=24, height=16, format=vs.RGBS, color=[0.25, 0.5, 0.75], length=1)
    clip = map_frames(clip, lambda x: sess.run(None, {name: x})[0], width=24, height=16)
    frame = clip.get_frame(0)
    got = [float(np.asarray(frame[p]).mean()) for p in range(3)]
    want = [1.5, 2.0, 2.5]
    if max(abs(a - b) for a, b in zip(got, want)) > 1e-2:
        raise RuntimeError("the self-test model gave the wrong pixels through VapourSynth: %r" % got)
    return got


def self_test(force_cpu=False):
    """Create a session for the self-test model on the preferred provider,
    run it, and check the answer. Returns a dict for the probe:
    {version, providers (available), requested, provider, fallback, maxError}.
    Raises if the session can't be created or the answer is wrong."""
    import numpy as np

    rt = ort()
    requested = preferred_providers(force_cpu)
    sess = session(selftest_model(), force_cpu=force_cpu)
    x = np.linspace(0.0, 1.0, 3 * 16 * 16, dtype=np.float32).reshape(1, 3, 16, 16)
    y = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    err = float(np.abs(y - (x * 2.0 + 1.0)).max())
    if not err < 1e-2:
        raise RuntimeError("the self-test model computed the wrong answer (max error %g)" % err)
    return {
        "version": rt.__version__,
        "providers": available_providers(),
        "requested": requested,
        "provider": session_provider(sess),
        "sessionProviders": list(sess.get_providers()),
        "fallback": last_fallback,
        "maxError": err,
    }


# ----------------------------------------------------------------------------
# Helpers for passes that run a model on part of a frame (face restoration,
# and anything else that crops, warps or masks around a network). They keep a
# pass a pure function of its input frames, which VapourSynth needs: it asks
# for frames in parallel and out of order, so nothing may depend on the order
# frames were computed in.
# ----------------------------------------------------------------------------


def to_rgbs(clip, matrix, range_):
    """`clip` (YUV, GRAY or RGB, any depth) as planar float RGB, using the
    source's matrix and range (zimg names, e.g. "709" / "limited") for YUV."""
    import vapoursynth as vs

    core = vs.core
    family = clip.format.color_family
    if family == vs.YUV:
        return core.resize.Spline36(clip, format=vs.RGBS, matrix_in_s=matrix, range_in_s=range_)
    if family == vs.GRAY:
        gray = core.resize.Point(clip, format=vs.GRAYS, range_in_s=range_)
        return core.std.ShufflePlanes(gray, [0, 0, 0], vs.RGB)
    return core.resize.Point(clip, format=vs.RGBS)


def from_rgbs(rgbs, fmt, matrix, range_):
    """The inverse of to_rgbs: back to `fmt` (a VideoFormat), dithered. A GRAY
    source takes the green plane, as the AI upscaling block does."""
    import vapoursynth as vs

    core = vs.core
    if fmt.color_family == vs.YUV:
        return core.resize.Spline36(rgbs, format=fmt.id, matrix_s=matrix, range_s=range_,
                                    dither_type="error_diffusion")
    if fmt.color_family == vs.GRAY:
        return core.resize.Point(core.std.ShufflePlanes(rgbs, 1, vs.GRAY), format=fmt.id, range_s=range_,
                                 dither_type="error_diffusion")
    return core.resize.Point(rgbs, format=fmt.id, dither_type="error_diffusion")


def shifted(clip, offset):
    """`clip` moved by `offset` frames, clamped at both ends: frame n of the
    result is frame clamp(n + offset) of `clip`. Passing these to
    std.ModifyFrame alongside the clip gives a callback its neighbours'
    frames without calling get_frame() from inside a frame request."""
    n = clip.num_frames
    if offset == 0 or n < 2:
        return clip
    offset = max(-(n - 1), min(n - 1, offset))
    if offset > 0:
        return clip[offset:] + clip[-1] * offset
    return clip[0] * (-offset) + clip[: n + offset]


class FrameMemo:
    """A bounded cache of a pure per-frame computation, computed once even
    when several frame requests (several nodes reading the same result, or
    neighbours sharing a detection) ask for the same key at the same time.
    Losing an entry only costs recomputing it, which gives the same answer."""

    def __init__(self, capacity=64):
        import collections

        self._capacity = capacity
        self._lock = threading.Lock()
        self._done = collections.OrderedDict()
        self._pending = {}

    def get(self, key, compute):
        with self._lock:
            if key in self._done:
                self._done.move_to_end(key)
                return self._done[key]
            event = self._pending.get(key)
            owner = event is None
            if owner:
                event = self._pending[key] = threading.Event()
        if not owner:
            event.wait()
            with self._lock:
                if key in self._done:
                    return self._done[key]
            return compute()  # evicted already (or the owner failed): recompute
        try:
            value = compute()
            with self._lock:
                self._done[key] = value
                while len(self._done) > self._capacity:
                    self._done.popitem(last=False)
            return value
        finally:
            with self._lock:
                self._pending.pop(key, None)
            event.set()


class Runner:
    """One model's session for a pass that calls it from frame requests.

    Runs are serialised: VapourSynth asks for several frames at once, and on
    a GPU provider concurrent runs each allocate their own working memory
    without running any faster (Core ML ran out of GPU memory on a 16 GB Mac
    with two jobs' worth). A run that fails on a GPU provider (out of memory,
    an unsupported shape at run time) is retried on the CPU, which this
    runner then keeps using; `fallback` says why. It runs like an
    InferenceSession (`run(output_names, feeds)`, `get_inputs()`), so code
    written against a session takes either."""

    def __init__(self, model, force_cpu=False, lock=None):
        """`lock`: share one between the runners of a pass to serialise all
        of its models' runs, not just each model's."""
        self.model = model
        self.session = session(model, force_cpu=force_cpu)
        self.fallback = last_fallback
        self._lock = lock or threading.Lock()

    @property
    def provider(self):
        return session_provider(self.session)

    def get_inputs(self):
        return self.session.get_inputs()

    def run(self, output_names, feeds):
        with self._lock:
            try:
                return self.session.run(output_names, feeds)
            except Exception as e:
                if self.provider == CPU_PROVIDER:
                    raise
                self.fallback = "%s failed at run time: %s" % (self.provider, e)
                self.session = session(self.model, force_cpu=True)
                return self.session.run(output_names, feeds)

// When Windows' own AVI readers say each audio packet plays, for task #41
// (../../index.html). Windows only; built by the probe workflow with MSVC:
//
//   cl /nologo /EHsc /O2 /DUNICODE /D_UNICODE avi_timing.cpp
//   avi_timing.exe <reader> <in.avi>
//
// <reader>:
//   dshow    DirectShow: File Source (Async) -> AVI Splitter -> Sample Grabber
//            (accepting the compressed type as offered) -> Null Renderer, no
//            clock. Each sample's IMediaSample::GetTime start.
//   mf       Media Foundation's Source Reader on the native (compressed) type:
//            each sample's timestamp.
//   mf_pcm   The same, decoded to PCM by Media Foundation's AAC decoder.
//   vfw      Video for Windows (avifil32): one AVIStreamRead per stream sample,
//            its AVIStreamSampleToTime.
//
// Prints one JSON line: whether the stream was read, the format offered, and
// "times": [[start in 100 ns units, bytes], ...] in delivery order. Built on
// the probe of docs/reports/2026-11-intermediate-pcm-depth (task #25).
#include <windows.h>
#include <mmsystem.h>
#include <mmreg.h>
#include <vfw.h>
#include <dshow.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
#include <string>
#include <vector>

#pragma comment(lib, "vfw32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "uuid.lib")

// qedit.h left the Windows SDK; the Sample Grabber itself still ships (qedit.dll).
MIDL_INTERFACE("0579154A-2B53-4994-B0D0-E773148EFF85")
ISampleGrabberCB : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE SampleCB(double t, IMediaSample *s) = 0;
    virtual HRESULT STDMETHODCALLTYPE BufferCB(double t, BYTE *buf, long len) = 0;
};
MIDL_INTERFACE("6B652FFF-11FE-4fce-92AD-0266B5D7C78F")
ISampleGrabber : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE SetOneShot(BOOL) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetMediaType(const AM_MEDIA_TYPE *) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetConnectedMediaType(AM_MEDIA_TYPE *) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetBufferSamples(BOOL) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCurrentBuffer(long *, long *) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCurrentSample(IMediaSample **) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetCallback(ISampleGrabberCB *, long) = 0;
};
static const CLSID CLSID_SampleGrabberQ = {0xC1F400A0, 0x3F08, 0x11d3, {0x9F, 0x0B, 0x00, 0x60, 0x08, 0x03, 0x9E, 0x37}};
static const CLSID CLSID_NullRendererQ = {0xC1F400A4, 0x3F08, 0x11d3, {0x9F, 0x0B, 0x00, 0x60, 0x08, 0x03, 0x9E, 0x37}};

static std::string g_note;
static std::vector<std::pair<long long, long>> g_times;
static CRITICAL_SECTION g_lock;

static std::string guid_str(const GUID &g) {
    char b[64];
    snprintf(b, sizeof b, "%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", g.Data1, g.Data2, g.Data3,
             g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
    return b;
}

static std::string hex(long v) {
    char b[32];
    snprintf(b, sizeof b, "0x%08lX", (unsigned long)v);
    return b;
}

static std::string wfx_json(const BYTE *p, size_t n) {
    if (!p || n < 16) return "null";
    const WAVEFORMATEX *w = (const WAVEFORMATEX *)p;
    char b[256];
    snprintf(b, sizeof b, "{\"wFormatTag\":\"0x%04X\",\"nChannels\":%u,\"nSamplesPerSec\":%lu,\"nBlockAlign\":%u}",
             w->wFormatTag, w->nChannels, w->nSamplesPerSec, w->nBlockAlign);
    return b;
}

static int emit(const char *reader, const wchar_t *in, bool ok, const std::string &format) {
    std::string note;
    for (char c : g_note) note += (c == '"' || c == '\\') ? '\'' : c;
    char file[512];
    WideCharToMultiByte(CP_UTF8, 0, in, -1, file, sizeof file, nullptr, nullptr);
    std::string f;
    for (char c : std::string(file)) f += (c == '\\') ? '/' : c;
    printf("{\"reader\":\"%s\",\"file\":\"%s\",\"ok\":%s,\"format\":%s,\"note\":\"%s\",\"times\":[", reader, f.c_str(),
           ok ? "true" : "false", format.c_str(), note.c_str());
    for (size_t i = 0; i < g_times.size(); i++)
        printf("%s[%lld,%ld]", i ? "," : "", g_times[i].first, g_times[i].second);
    printf("]}\n");
    return 0;
}

// ---------------------------------------------------------------- VfW

static int run_vfw(const wchar_t *in) {
    AVIFileInit();
    PAVIFILE pf = nullptr;
    HRESULT hr = AVIFileOpenW(&pf, in, OF_READ | OF_SHARE_DENY_WRITE, nullptr);
    if (FAILED(hr)) { g_note = "AVIFileOpen " + hex(hr); return emit("vfw", in, false, "null"); }
    PAVISTREAM ps = nullptr;
    hr = AVIFileGetStream(pf, &ps, streamtypeAUDIO, 0);
    if (FAILED(hr)) { g_note = "AVIFileGetStream(audio) " + hex(hr); return emit("vfw", in, false, "null"); }
    LONG start = AVIStreamStart(ps), len = AVIStreamLength(ps), fsize = 0;
    AVIStreamReadFormat(ps, start, nullptr, &fsize);
    std::vector<BYTE> fmt(fsize);
    AVIStreamReadFormat(ps, start, fmt.data(), &fsize);
    AVISTREAMINFOW info = {};
    AVIStreamInfoW(ps, &info, sizeof info);
    g_note = "length " + std::to_string(len) + ", dwSampleSize " + std::to_string(info.dwSampleSize) + ", scale/rate " +
             std::to_string(info.dwScale) + "/" + std::to_string(info.dwRate);
    std::vector<BYTE> buf(1 << 16);
    for (LONG pos = start; pos < start + len;) {
        LONG bytes = 0, samples = 0;
        hr = AVIStreamRead(ps, pos, 1, buf.data(), (LONG)buf.size(), &bytes, &samples);
        if (FAILED(hr)) { g_note += "; AVIStreamRead " + hex(hr) + " at " + std::to_string(pos); break; }
        if (samples <= 0) break;
        LONG ms = AVIStreamSampleToTime(ps, pos);
        g_times.push_back({(long long)ms * 10000, bytes});
        pos += samples;
    }
    AVIStreamRelease(ps);
    AVIFileRelease(pf);
    AVIFileExit();
    return emit("vfw", in, true, wfx_json(fmt.data(), fmt.size()));
}

// ---------------------------------------------------------------- DirectShow

struct Grabber : ISampleGrabberCB {
    STDMETHODIMP QueryInterface(REFIID riid, void **pv) override {
        if (riid == IID_IUnknown || riid == __uuidof(ISampleGrabberCB)) { *pv = this; return S_OK; }
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return 2; }
    STDMETHODIMP_(ULONG) Release() override { return 1; }
    STDMETHODIMP SampleCB(double, IMediaSample *s) override {
        REFERENCE_TIME a = -1, b = -1;
        HRESULT hr = s->GetTime(&a, &b);
        EnterCriticalSection(&g_lock);
        g_times.push_back({SUCCEEDED(hr) ? (long long)a : -1LL, s->GetActualDataLength()});
        LeaveCriticalSection(&g_lock);
        return S_OK;
    }
    STDMETHODIMP BufferCB(double, BYTE *, long) override { return S_OK; }
};

static IPin *pin(IBaseFilter *f, PIN_DIRECTION want, int index = 0) {
    IEnumPins *e = nullptr;
    if (FAILED(f->EnumPins(&e))) return nullptr;
    IPin *p = nullptr;
    int i = 0;
    while (e->Next(1, &p, nullptr) == S_OK) {
        PIN_DIRECTION d;
        p->QueryDirection(&d);
        if (d == want && i++ == index) { e->Release(); return p; }
        p->Release();
    }
    e->Release();
    return nullptr;
}

static int run_dshow(const wchar_t *in) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IGraphBuilder *g = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FilterGraph, nullptr, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, (void **)&g);
    if (FAILED(hr)) { g_note = "FilterGraph " + hex(hr); return emit("dshow", in, false, "null"); }
    IBaseFilter *src = nullptr, *split = nullptr, *sg = nullptr, *nul = nullptr;
    hr = g->AddSourceFilter(in, L"src", &src);
    if (FAILED(hr)) { g_note = "AddSourceFilter " + hex(hr); return emit("dshow", in, false, "null"); }
    CoCreateInstance(CLSID_AviSplitter, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&split);
    g->AddFilter(split, L"AVI Splitter");
    hr = g->ConnectDirect(pin(src, PINDIR_OUTPUT), pin(split, PINDIR_INPUT), nullptr);
    if (FAILED(hr)) { g_note = "connect source to AVI Splitter " + hex(hr); return emit("dshow", in, false, "null"); }
    IPin *audio = nullptr;
    std::string offered = "null";
    for (int i = 0; IPin *p = pin(split, PINDIR_OUTPUT, i); i++) {
        IEnumMediaTypes *e = nullptr;
        AM_MEDIA_TYPE *mt = nullptr;
        if (SUCCEEDED(p->EnumMediaTypes(&e)) && e->Next(1, &mt, nullptr) == S_OK) {
            if (mt->majortype == MEDIATYPE_Audio && !audio) {
                audio = p;
                std::string w = mt->formattype == FORMAT_WaveFormatEx ? wfx_json(mt->pbFormat, mt->cbFormat) : "null";
                offered = "{\"subtype\":\"" + guid_str(mt->subtype) + "\",\"wfx\":" + w + "}";
            }
        }
        if (e) e->Release();
        if (audio != p) p->Release();
    }
    if (!audio) { g_note = "AVI Splitter exposes no audio pin"; return emit("dshow", in, false, "null"); }
    hr = CoCreateInstance(CLSID_SampleGrabberQ, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&sg);
    if (FAILED(hr)) { g_note = "Sample Grabber unavailable " + hex(hr); return emit("dshow", in, false, offered); }
    CoCreateInstance(CLSID_NullRendererQ, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&nul);
    g->AddFilter(sg, L"grabber");
    g->AddFilter(nul, L"null");
    hr = g->ConnectDirect(audio, pin(sg, PINDIR_INPUT), nullptr);
    if (FAILED(hr)) { g_note = "connect audio pin " + hex(hr); return emit("dshow", in, false, offered); }
    g->ConnectDirect(pin(sg, PINDIR_OUTPUT), pin(nul, PINDIR_INPUT), nullptr);
    ISampleGrabber *grab = nullptr;
    sg->QueryInterface(__uuidof(ISampleGrabber), (void **)&grab);
    static Grabber cb;
    grab->SetBufferSamples(FALSE);
    grab->SetCallback(&cb, 0);
    IMediaFilter *mf = nullptr;
    g->QueryInterface(IID_IMediaFilter, (void **)&mf);
    mf->SetSyncSource(nullptr);
    IMediaControl *mc = nullptr;
    IMediaEvent *me = nullptr;
    g->QueryInterface(IID_IMediaControl, (void **)&mc);
    g->QueryInterface(IID_IMediaEvent, (void **)&me);
    hr = mc->Run();
    long code = 0;
    if (SUCCEEDED(hr)) hr = me->WaitForCompletion(30000, &code);
    mc->Stop();
    if (FAILED(hr)) { g_note = "run " + hex(hr); return emit("dshow", in, false, offered); }
    g_note = "event " + std::to_string(code);
    return emit("dshow", in, true, offered);
}

// ---------------------------------------------------------------- Media Foundation

static int run_mf(const wchar_t *in, bool pcm) {
    const char *name = pcm ? "mf_pcm" : "mf";
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HRESULT hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) { g_note = "MFStartup " + hex(hr); return emit(name, in, false, "null"); }
    IMFSourceReader *r = nullptr;
    hr = MFCreateSourceReaderFromURL(in, nullptr, &r);
    if (FAILED(hr)) { g_note = "MFCreateSourceReaderFromURL " + hex(hr); return emit(name, in, false, "null"); }
    const DWORD A = (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM;
    IMFMediaType *native = nullptr;
    hr = r->GetNativeMediaType(A, 0, &native);
    if (FAILED(hr)) { g_note = "GetNativeMediaType " + hex(hr); return emit(name, in, false, "null"); }
    GUID sub = {};
    native->GetGUID(MF_MT_SUBTYPE, &sub);
    std::string format = "{\"nativeSubtype\":\"" + guid_str(sub) + "\"}";
    r->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    r->SetStreamSelection(A, TRUE);
    if (pcm) {
        IMFMediaType *t = nullptr;
        MFCreateMediaType(&t);
        t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        t->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        hr = r->SetCurrentMediaType(A, nullptr, t);
    } else {
        hr = r->SetCurrentMediaType(A, nullptr, native);
    }
    if (FAILED(hr)) { g_note = "SetCurrentMediaType " + hex(hr); return emit(name, in, false, format); }
    for (;;) {
        DWORD flags = 0;
        LONGLONG ts = 0;
        IMFSample *s = nullptr;
        hr = r->ReadSample(A, 0, nullptr, &flags, &ts, &s);
        if (FAILED(hr)) { g_note = "ReadSample " + hex(hr); return emit(name, in, false, format); }
        if (s) {
            DWORD n = 0;
            s->GetTotalLength(&n);
            g_times.push_back({(long long)ts, (long)n});
            s->Release();
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    return emit(name, in, true, format);
}

int wmain(int argc, wchar_t **argv) {
    InitializeCriticalSection(&g_lock);
    if (argc < 3) {
        fprintf(stderr, "usage: avi_timing <dshow|mf|mf_pcm|vfw> <in.avi>\n");
        return 2;
    }
    std::wstring m = argv[1];
    if (m == L"vfw") return run_vfw(argv[2]);
    if (m == L"dshow") return run_dshow(argv[2]);
    if (m == L"mf") return run_mf(argv[2], false);
    if (m == L"mf_pcm") return run_mf(argv[2], true);
    fprintf(stderr, "unknown reader\n");
    return 2;
}

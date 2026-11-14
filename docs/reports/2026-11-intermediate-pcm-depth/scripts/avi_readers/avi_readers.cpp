// Reads an AVI's first audio stream the ways Windows programs do, for F6 of
// ../../index.html. Windows only; built by the probe workflow with MSVC:
//
//   cl /nologo /EHsc /O2 /DUNICODE /D_UNICODE avi_readers.cpp
//   avi_readers.exe <reader> <in.avi> <out.raw>
//
// <reader>:
//   vfw          Video for Windows' AVIFile API (avifil32): AVIStreamReadFormat
//                + AVIStreamRead. What VirtualDub 1.x, Vegas's old AVI path and
//                most older Windows tools read through.
//   acm          The audio stream (read through VfW), converted by the Audio
//                Compression Manager to 16-bit PCM, its format exactly as
//                stored. The old conversion layer.
//   acm_plain24  The same, but the source format restated as plain
//                WAVE_FORMAT_PCM, 24 bits (a diagnostic: is it the extensible
//                header ACM refuses, or 24 bits at all?).
//   dshow        DirectShow: File Source (Async) -> AVI Splitter -> Sample
//                Grabber (accepting anything) -> Null Renderer, no clock.
//   mf           Media Foundation's Source Reader, asked for PCM.
//
// Prints one JSON line: whether the stream was read, the format the reader
// reported, and the number of bytes written to <out.raw>. The workflow's
// compare.py checks those bytes against ffmpeg's.

#include <windows.h>
#include <mmsystem.h>
#include <mmreg.h>
#include <msacm.h>
#include <vfw.h>
#include <dshow.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <ks.h>
#include <ksmedia.h>
#include <stdio.h>
#include <string>
#include <vector>

#pragma comment(lib, "vfw32.lib")
#pragma comment(lib, "msacm32.lib")
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
static std::vector<BYTE> g_out;

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

// A WAVEFORMATEX[TENSIBLE] as JSON.
static std::string wfx_json(const BYTE *p, size_t n) {
    if (!p || n < 16) return "null";
    const WAVEFORMATEX *w = (const WAVEFORMATEX *)p;
    char b[512];
    int k = snprintf(b, sizeof b,
                     "{\"wFormatTag\":\"0x%04X\",\"nChannels\":%u,\"nSamplesPerSec\":%lu,\"wBitsPerSample\":%u,"
                     "\"nBlockAlign\":%u",
                     w->wFormatTag, w->nChannels, w->nSamplesPerSec, w->wBitsPerSample, w->nBlockAlign);
    if (w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && n >= sizeof(WAVEFORMATEXTENSIBLE)) {
        const WAVEFORMATEXTENSIBLE *x = (const WAVEFORMATEXTENSIBLE *)p;
        k += snprintf(b + k, sizeof b - k, ",\"wValidBitsPerSample\":%u,\"dwChannelMask\":\"0x%lX\",\"SubFormat\":\"%s\"",
                      x->Samples.wValidBitsPerSample, x->dwChannelMask, guid_str(x->SubFormat).c_str());
    }
    snprintf(b + k, sizeof b - k, "}");
    return b;
}

static void emit(const char *reader, bool ok, const std::string &format, const wchar_t *out) {
    if (ok && out) {
        FILE *f = _wfopen(out, L"wb");
        if (f) {
            if (!g_out.empty()) fwrite(g_out.data(), 1, g_out.size(), f);
            fclose(f);
        }
    }
    std::string note;
    for (char c : g_note) note += (c == '"' || c == '\\') ? '\'' : c;
    printf("{\"reader\":\"%s\",\"ok\":%s,\"format\":%s,\"bytes\":%zu,\"note\":\"%s\"}\n", reader,
           ok ? "true" : "false", format.c_str(), g_out.size(), note.c_str());
}

// ---------------------------------------------------------------- VfW / ACM

static bool vfw_read(const wchar_t *path, std::vector<BYTE> &fmt, std::vector<BYTE> &data) {
    AVIFileInit();
    PAVIFILE pf = nullptr;
    HRESULT hr = AVIFileOpenW(&pf, path, OF_READ | OF_SHARE_DENY_WRITE, nullptr);
    if (FAILED(hr)) { g_note = "AVIFileOpen " + hex(hr); return false; }
    PAVISTREAM ps = nullptr;
    hr = AVIFileGetStream(pf, &ps, streamtypeAUDIO, 0);
    if (FAILED(hr)) { g_note = "AVIFileGetStream(audio) " + hex(hr); AVIFileRelease(pf); return false; }
    LONG start = AVIStreamStart(ps), len = AVIStreamLength(ps), fsize = 0;
    AVIStreamReadFormat(ps, start, nullptr, &fsize);
    fmt.resize(fsize);
    hr = AVIStreamReadFormat(ps, start, fmt.data(), &fsize);
    if (FAILED(hr)) { g_note = "AVIStreamReadFormat " + hex(hr); return false; }
    std::vector<BYTE> buf(1 << 20);
    for (LONG pos = start; pos < start + len;) {
        LONG bytes = 0, samples = 0;
        hr = AVIStreamRead(ps, pos, AVISTREAMREAD_CONVENIENT, buf.data(), (LONG)buf.size(), &bytes, &samples);
        if (FAILED(hr)) { g_note = "AVIStreamRead " + hex(hr) + " at " + std::to_string(pos); return false; }
        if (samples <= 0) break;
        data.insert(data.end(), buf.begin(), buf.begin() + bytes);
        pos += samples;
    }
    AVIStreamRelease(ps);
    AVIFileRelease(pf);
    AVIFileExit();
    return true;
}

static int run_vfw(const wchar_t *in, const wchar_t *out) {
    std::vector<BYTE> fmt;
    bool ok = vfw_read(in, fmt, g_out);
    emit("vfw", ok, wfx_json(fmt.data(), fmt.size()), out);
    return 0;
}

static int run_acm(const wchar_t *in, const wchar_t *out, bool plain) {
    const char *name = plain ? "acm_plain24" : "acm";
    std::vector<BYTE> fmt, data;
    if (!vfw_read(in, fmt, data)) { emit(name, false, "null", out); return 0; }
    WAVEFORMATEX src = *(WAVEFORMATEX *)fmt.data();
    const WAVEFORMATEX *srcp = (const WAVEFORMATEX *)fmt.data();
    if (plain) {
        src.wFormatTag = WAVE_FORMAT_PCM;
        src.cbSize = 0;
        srcp = &src;
    }
    WAVEFORMATEX dst = {};
    dst.wFormatTag = WAVE_FORMAT_PCM;
    dst.nChannels = srcp->nChannels;
    dst.nSamplesPerSec = srcp->nSamplesPerSec;
    dst.wBitsPerSample = 16;
    dst.nBlockAlign = dst.nChannels * 2;
    dst.nAvgBytesPerSec = dst.nBlockAlign * dst.nSamplesPerSec;
    HACMSTREAM has = nullptr;
    MMRESULT r = acmStreamOpen(&has, nullptr, (LPWAVEFORMATEX)srcp, &dst, nullptr, 0, 0, ACM_STREAMOPENF_NONREALTIME);
    std::string format = wfx_json((const BYTE *)srcp, plain ? sizeof src : fmt.size());
    if (r != MMSYSERR_NOERROR) {
        g_note = "acmStreamOpen " + std::to_string(r) + (r == ACMERR_NOTPOSSIBLE ? " (ACMERR_NOTPOSSIBLE)" : "");
        emit(name, false, format, out);
        return 0;
    }
    DWORD dsize = 0;
    acmStreamSize(has, (DWORD)data.size(), &dsize, ACM_STREAMSIZEF_SOURCE);
    g_out.resize(dsize);
    ACMSTREAMHEADER h = {};
    h.cbStruct = sizeof h;
    h.pbSrc = data.data();
    h.cbSrcLength = (DWORD)data.size();
    h.pbDst = g_out.data();
    h.cbDstLength = dsize;
    r = acmStreamPrepareHeader(has, &h, 0);
    if (r == MMSYSERR_NOERROR) r = acmStreamConvert(has, &h, ACM_STREAMCONVERTF_START | ACM_STREAMCONVERTF_END);
    if (r != MMSYSERR_NOERROR) {
        g_note = "acmStreamConvert " + std::to_string(r);
        g_out.clear();
        emit(name, false, format, out);
        return 0;
    }
    g_out.resize(h.cbDstLengthUsed);
    g_note = "converted to 16-bit PCM";
    acmStreamUnprepareHeader(has, &h, 0);
    acmStreamClose(has, 0);
    emit(name, true, format, out);
    return 0;
}

// ---------------------------------------------------------------- DirectShow

struct Grabber : ISampleGrabberCB {
    STDMETHODIMP QueryInterface(REFIID riid, void **pv) override {
        if (riid == IID_IUnknown || riid == __uuidof(ISampleGrabberCB)) { *pv = this; return S_OK; }
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return 2; }
    STDMETHODIMP_(ULONG) Release() override { return 1; }
    STDMETHODIMP SampleCB(double, IMediaSample *) override { return S_OK; }
    STDMETHODIMP BufferCB(double, BYTE *buf, long len) override {
        g_out.insert(g_out.end(), buf, buf + len);
        return S_OK;
    }
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

static std::string media_type_json(const AM_MEDIA_TYPE &mt) {
    std::string fmt = (mt.formattype == FORMAT_WaveFormatEx) ? wfx_json(mt.pbFormat, mt.cbFormat) : "null";
    std::string sub = mt.subtype == MEDIASUBTYPE_PCM ? "MEDIASUBTYPE_PCM" : guid_str(mt.subtype);
    return "{\"subtype\":\"" + sub + "\",\"wfx\":" + fmt + "}";
}

static int run_dshow(const wchar_t *in, const wchar_t *out) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IGraphBuilder *g = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FilterGraph, nullptr, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, (void **)&g);
    if (FAILED(hr)) { g_note = "FilterGraph " + hex(hr); emit("dshow", false, "null", out); return 0; }
    IBaseFilter *src = nullptr, *split = nullptr, *sg = nullptr, *nul = nullptr;
    hr = g->AddSourceFilter(in, L"src", &src);
    if (FAILED(hr)) { g_note = "AddSourceFilter " + hex(hr); emit("dshow", false, "null", out); return 0; }
    CoCreateInstance(CLSID_AviSplitter, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&split);
    g->AddFilter(split, L"AVI Splitter");
    hr = g->ConnectDirect(pin(src, PINDIR_OUTPUT), pin(split, PINDIR_INPUT), nullptr);
    if (FAILED(hr)) { g_note = "connect source to AVI Splitter " + hex(hr); emit("dshow", false, "null", out); return 0; }
    // The splitter's audio pin and the type it offers.
    IPin *audio = nullptr;
    std::string offered = "null";
    for (int i = 0; IPin *p = pin(split, PINDIR_OUTPUT, i); i++) {
        IEnumMediaTypes *e = nullptr;
        AM_MEDIA_TYPE *mt = nullptr;
        if (SUCCEEDED(p->EnumMediaTypes(&e)) && e->Next(1, &mt, nullptr) == S_OK) {
            if (mt->majortype == MEDIATYPE_Audio && !audio) { audio = p; offered = media_type_json(*mt); }
        }
        if (e) e->Release();
        if (audio != p) p->Release();
    }
    if (!audio) { g_note = "AVI Splitter exposes no audio pin"; emit("dshow", false, "null", out); return 0; }
    hr = CoCreateInstance(CLSID_SampleGrabberQ, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&sg);
    if (FAILED(hr)) { g_note = "Sample Grabber unavailable " + hex(hr); emit("dshow", false, offered, out); return 0; }
    CoCreateInstance(CLSID_NullRendererQ, nullptr, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&nul);
    g->AddFilter(sg, L"grabber");
    g->AddFilter(nul, L"null");
    hr = g->ConnectDirect(audio, pin(sg, PINDIR_INPUT), nullptr);
    if (FAILED(hr)) { g_note = "connect audio pin " + hex(hr); emit("dshow", false, offered, out); return 0; }
    g->ConnectDirect(pin(sg, PINDIR_OUTPUT), pin(nul, PINDIR_INPUT), nullptr);
    ISampleGrabber *grab = nullptr;
    sg->QueryInterface(__uuidof(ISampleGrabber), (void **)&grab);
    static Grabber cb;
    grab->SetBufferSamples(FALSE);
    grab->SetCallback(&cb, 1);
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
    if (FAILED(hr)) { g_note = "run " + hex(hr); emit("dshow", false, offered, out); return 0; }
    g_note = "event " + std::to_string(code);
    emit("dshow", true, offered, out);
    return 0;
}

// ---------------------------------------------------------------- Media Foundation

static std::string mf_type_json(IMFMediaType *t) {
    GUID sub = {};
    UINT32 bits = 0, ch = 0, rate = 0, valid = 0;
    t->GetGUID(MF_MT_SUBTYPE, &sub);
    t->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits);
    t->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
    t->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    t->GetUINT32(MF_MT_AUDIO_VALID_BITS_PER_SAMPLE, &valid);
    std::string s = sub == MFAudioFormat_PCM ? "MFAudioFormat_PCM" : sub == MFAudioFormat_Float ? "MFAudioFormat_Float" : guid_str(sub);
    char b[256];
    snprintf(b, sizeof b, "{\"subtype\":\"%s\",\"bits\":%u,\"validBits\":%u,\"channels\":%u,\"rate\":%u}", s.c_str(), bits, valid, ch, rate);
    return b;
}

static int run_mf(const wchar_t *in, const wchar_t *out) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HRESULT hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) { g_note = "MFStartup " + hex(hr); emit("mf", false, "null", out); return 0; }
    IMFSourceReader *r = nullptr;
    hr = MFCreateSourceReaderFromURL(in, nullptr, &r);
    if (FAILED(hr)) { g_note = "MFCreateSourceReaderFromURL " + hex(hr); emit("mf", false, "null", out); return 0; }
    const DWORD A = (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM;
    IMFMediaType *native = nullptr;
    hr = r->GetNativeMediaType(A, 0, &native);
    if (FAILED(hr)) { g_note = "no audio stream (GetNativeMediaType " + hex(hr) + ")"; emit("mf", false, "null", out); return 0; }
    std::string nat = mf_type_json(native);
    r->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    r->SetStreamSelection(A, TRUE);
    IMFMediaType *pcm = nullptr;
    MFCreateMediaType(&pcm);
    pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    hr = r->SetCurrentMediaType(A, nullptr, pcm);
    if (FAILED(hr)) { g_note = "SetCurrentMediaType(PCM) " + hex(hr); emit("mf", false, "{\"native\":" + nat + "}", out); return 0; }
    IMFMediaType *cur = nullptr;
    r->GetCurrentMediaType(A, &cur);
    std::string format = "{\"native\":" + nat + ",\"delivered\":" + mf_type_json(cur) + "}";
    for (;;) {
        DWORD flags = 0;
        IMFSample *s = nullptr;
        hr = r->ReadSample(A, 0, nullptr, &flags, nullptr, &s);
        if (FAILED(hr)) { g_note = "ReadSample " + hex(hr); emit("mf", false, format, out); return 0; }
        if (s) {
            IMFMediaBuffer *b = nullptr;
            s->ConvertToContiguousBuffer(&b);
            BYTE *p = nullptr;
            DWORD n = 0;
            b->Lock(&p, nullptr, &n);
            g_out.insert(g_out.end(), p, p + n);
            b->Unlock();
            b->Release();
            s->Release();
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    emit("mf", true, format, out);
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: avi_readers <vfw|acm|acm_plain24|dshow|mf> <in.avi> <out.raw>\n");
        return 2;
    }
    std::wstring m = argv[1];
    if (m == L"vfw") return run_vfw(argv[2], argv[3]);
    if (m == L"acm") return run_acm(argv[2], argv[3], false);
    if (m == L"acm_plain24") return run_acm(argv[2], argv[3], true);
    if (m == L"dshow") return run_dshow(argv[2], argv[3]);
    if (m == L"mf") return run_mf(argv[2], argv[3]);
    fprintf(stderr, "unknown reader\n");
    return 2;
}

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/dependency_manager.dart';

class AboutDialog extends StatefulWidget {
  const AboutDialog({super.key});

  @override
  State<AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<AboutDialog> {
  String _version = '';
  String _depsVersion = '';
  String _githubUrl = 'https://github.com/StuartCameronCode/VapourBox';
  static const String _authorUrl = 'https://stuart-cameron.com';

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  Future<void> _loadVersionInfo() async {
    // Get app version from package info
    final packageInfo = await PackageInfo.fromPlatform();

    // Get deps version from dependency manager
    final depsInfo = await DependencyManager.instance.getExpectedVersion();

    setState(() {
      _version = packageInfo.version;
      _depsVersion = depsInfo.version;
      _githubUrl = 'https://github.com/${depsInfo.githubRepo}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Center(
                child: Column(
                  children: [
                    Text(
                      'VapourBox',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _version.isEmpty ? 'Loading...' : 'Version $_version',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                    if (_depsVersion.isNotEmpty)
                      Text(
                        'Dependencies: $_depsVersion',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.4),
                            ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Video processing and cleanup powered by VapourSynth',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => _launchUrl(_authorUrl),
                      child: Text(
                        'by Stuart Cameron',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // License notice
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'License',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This program is free software: you can redistribute it and/or modify '
                      'it under the terms of the GNU General Public License as published by '
                      'the Free Software Foundation, either version 3 of the License, or '
                      '(at your option) any later version.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Third-party components header
              Text(
                'Third-Party Components',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),

              // Scrollable component list
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.2),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(8),
                    children: const [
                      // Every entry here is taken from the upstream project's
                      // own LICENSE file or source headers, and must match
                      // licenses/NOTICES.txt. Do not guess a name: if a project
                      // states no copyright holder, say so or name the project.
                      _ComponentTile(
                        name: 'VapourSynth',
                        license: 'LGPL 2.1+',
                        copyright: 'Fredrik Mellbin',
                        url: 'https://github.com/vapoursynth/vapoursynth',
                      ),
                      _ComponentTile(
                        name: 'zimg',
                        license: 'WTFPL',
                        copyright: 'sekrit-twc',
                        url: 'https://github.com/sekrit-twc/zimg',
                      ),
                      _ComponentTile(
                        name: 'havsfunc',
                        license: 'Unlicense',
                        copyright: 'Public domain; maintained by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/havsfunc',
                      ),
                      _ComponentTile(
                        name: 'mvsfunc',
                        license: 'No licence stated',
                        copyright: 'mawen1250',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/mvsfunc',
                      ),
                      _ComponentTile(
                        name: 'srestore 2.7e (ported code)',
                        license: 'Unlicense',
                        copyright: 'From havsfunc; ported into VapourBox\'s '
                            'templates for the Unblend pass',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/havsfunc',
                      ),
                      _ComponentTile(
                        name: 'vs-jetpack (ported code)',
                        license: 'MIT',
                        copyright: 'Jaded-Encoding-Thaumaturgy; '
                            'FixInterlacedFades, vine_dehalo and mpeg2stinx '
                            'ported into VapourBox\'s templates',
                        url: 'https://github.com/Jaded-Encoding-Thaumaturgy/vs-jetpack',
                      ),
                      _ComponentTile(
                        name: 'adjust',
                        license: 'WTFPL',
                        copyright: 'dubhater',
                        url: 'https://github.com/dubhater/vapoursynth-adjust',
                      ),
                      _ComponentTile(
                        name: 'VIVTC',
                        license: 'LGPL 2.1',
                        copyright: 'Fredrik Mellbin',
                        url: 'https://github.com/vapoursynth/vivtc',
                      ),
                      _ComponentTile(
                        name: 'MiscFilters',
                        license: 'LGPL 2.1',
                        copyright: 'Fredrik Mellbin and contributors',
                        url: 'https://github.com/vapoursynth/vs-miscfilters-obsolete',
                      ),
                      _ComponentTile(
                        name: 'RemoveGrain / Repair',
                        license: 'WTFPL, with one MIT component',
                        copyright: 'Laurent de Soras, Fredrik Mellbin; '
                            'Clense by Victor Efimov (MIT)',
                        url: 'https://github.com/vapoursynth/vs-removegrain',
                      ),
                      _ComponentTile(
                        name: 'MVTools',
                        license: 'GPL 2.0',
                        copyright: 'Port by dubhater, from Manao\'s AviSynth '
                            'plugin with work by Fizick and Pinterf',
                        url: 'https://github.com/dubhater/vapoursynth-mvtools',
                      ),
                      _ComponentTile(
                        name: 'nnedi3',
                        license: 'GPL 2.0',
                        copyright: 'Kevin Stone (tritical); port by dubhater',
                        url: 'https://github.com/dubhater/vapoursynth-nnedi3',
                      ),
                      _ComponentTile(
                        name: 'znedi3',
                        license: 'GPL 2.0',
                        copyright: 'sekrit-twc, after Kevin Stone, dubhater '
                            'and Loren Merritt',
                        url: 'https://github.com/sekrit-twc/znedi3',
                      ),
                      _ComponentTile(
                        name: 'NNEDI3CL',
                        license: 'GPL 2.0',
                        copyright: 'Kevin Stone (tritical); port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL',
                      ),
                      _ComponentTile(
                        name: 'EEDI3',
                        license: 'GPL 2.0',
                        copyright: 'Kevin Stone (tritical); port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3',
                      ),
                      _ComponentTile(
                        name: 'akarin',
                        license: 'LGPL 3.0',
                        copyright: 'Akarin; maintained by Jaded Encoding '
                            'Thaumaturgy. Statically links LLVM',
                        url: 'https://github.com/Jaded-Encoding-Thaumaturgy/akarin-vapoursynth-plugin',
                      ),
                      _ComponentTile(
                        name: 'fmtconv',
                        license: 'WTFPL',
                        copyright: 'Firesledge (Laurent de Soras)',
                        url: 'https://gitlab.com/EleonoreMizo/fmtconv',
                      ),
                      _ComponentTile(
                        name: 'zsmooth',
                        license: 'MIT',
                        copyright: 'Austin Dworaczyk Wiltshire; CCD originally '
                            'by Sergey Stolyarevsky',
                        url: 'https://github.com/adworacz/zsmooth',
                      ),
                      _ComponentTile(
                        name: 'vszip',
                        license: 'MIT',
                        copyright: 'Julek; includes zigimg (MIT) and '
                            'vapoursynth-zig (LGPL 2.1)',
                        url: 'https://github.com/dnjulek/vapoursynth-zip',
                      ),
                      _ComponentTile(
                        name: 'SangNom',
                        license: 'MIT source; binaries GPL 2.0',
                        copyright: 'james1201; Victor Efimov',
                        url: 'https://github.com/dubhatervapoursynth/vapoursynth-sangnom',
                      ),
                      _ComponentTile(
                        name: 'RIFE (VapourSynth-RIFE-ncnn-Vulkan)',
                        license: 'MIT',
                        copyright: 'HolyWu; based on rife-ncnn-vulkan by '
                            'nihui; includes ncnn (Tencent, BSD 3-Clause) '
                            'and glslang',
                        url: 'https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan',
                      ),
                      _ComponentTile(
                        name: 'RIFE 4.26 model (optional download, frame rate add-on)',
                        license: 'MIT',
                        copyright: 'hzwer; architecture by Megvii Inc.',
                        url: 'https://github.com/hzwer/Practical-RIFE',
                      ),
                      _ComponentTile(
                        name: 'MoltenVK',
                        license: 'Apache 2.0',
                        copyright: 'The Brenwill Workshop Ltd. (macOS only)',
                        url: 'https://github.com/KhronosGroup/MoltenVK',
                      ),
                      _ComponentTile(
                        name: 'VSNCNN (vs-mlrt)',
                        license: 'GPL-3.0',
                        copyright: 'AmusementClub (no copyright notice upstream); '
                            'includes ncnn (Tencent), Protocol Buffers (Google, '
                            'BSD 3-Clause), ONNX (Apache 2.0) and, on macOS, the '
                            'LLVM OpenMP runtime (Apache 2.0 with LLVM exception)',
                        url: 'https://github.com/AmusementClub/vs-mlrt',
                      ),
                      _ComponentTile(
                        name: 'Real-ESRGAN anime video model (optional download, upscaling add-on)',
                        license: 'BSD-3-Clause',
                        copyright: 'Xintao Wang',
                        url: 'https://github.com/xinntao/Real-ESRGAN',
                      ),
                      _ComponentTile(
                        name: 'AnimeJaNai models (optional download)',
                        license: 'CC BY-NC-SA 4.0 (non-commercial use only)',
                        copyright: 'the-database',
                        url: 'https://github.com/the-database/mpv-upscale-2x_animejanai',
                      ),
                      _ComponentTile(
                        name: 'RestoreFormer++ model (optional download, face restoration add-on)',
                        license: 'Apache-2.0',
                        copyright: 'Zhouxia Wang, Jiawei Zhang, Tianshui Chen, Wenping Wang and Ping Luo',
                        url: 'https://github.com/wzhouxiff/RestoreFormerPlusPlus',
                      ),
                      _ComponentTile(
                        name: 'RetinaFace face detector (optional download, face restoration add-on)',
                        license: 'MIT',
                        copyright: 'biubug6 (Pytorch_Retinaface)',
                        url: 'https://github.com/biubug6/Pytorch_Retinaface',
                      ),
                      _ComponentTile(
                        name: 'BiSeNet face parser (optional download, face restoration add-on)',
                        license: 'MIT',
                        copyright: 'zll (face-parsing.PyTorch)',
                        url: 'https://github.com/zllrunning/face-parsing.PyTorch',
                      ),
                      _ComponentTile(
                        name: 'facexlib (optional download, face restoration add-on)',
                        license: 'MIT',
                        copyright: 'Xintao Wang',
                        url: 'https://github.com/xinntao/facexlib',
                      ),
                      _ComponentTile(
                        name: 'GFPGAN v1.4 model (optional download, non-commercial use only)',
                        license: 'Apache-2.0 + NVIDIA Source Code License (NC)',
                        copyright: 'THL A29 Limited, a Tencent company',
                        url: 'https://github.com/TencentARC/GFPGAN',
                      ),
                      _ComponentTile(
                        name: 'CodeFormer model (optional download, non-commercial use only)',
                        license: 'S-Lab License 1.0 (NC)',
                        copyright: 'S-Lab',
                        url: 'https://github.com/sczhou/CodeFormer',
                      ),
                      _ComponentTile(
                        name: 'DDColor model (optional download, colourisation add-on)',
                        license: 'Apache-2.0',
                        copyright: 'Xiaoyang Kang, Tao Yang, Wenqi Ouyang, Peiran Ren, Lingzhi Li and Xuansong Xie',
                        url: 'https://github.com/piddnad/DDColor',
                      ),
                      _ComponentTile(
                        name: 'DeOldify Video model (optional download, colourisation add-on)',
                        license: 'MIT',
                        copyright: 'Jason Antic',
                        url: 'https://github.com/jantic/DeOldify',
                      ),
                      _ComponentTile(
                        name: 'Real-ESRGAN general model (optional download, upscaling add-on)',
                        license: 'BSD-3-Clause',
                        copyright: 'Xintao Wang',
                        url: 'https://github.com/xinntao/Real-ESRGAN',
                      ),
                      _ComponentTile(
                        name: '2xLiveActionV1_SPAN model (optional download, upscaling add-on)',
                        license: 'Apache-2.0',
                        copyright: 'Copyright 2025 jcj83429',
                        url: 'https://github.com/jcj83429/upscaling/tree/main/2xLiveActionV1_SPAN',
                      ),
                      _ComponentTile(
                        name: 'Real-ESRGAN x4plus / x2plus models (optional download, upscaling add-on)',
                        license: 'BSD-3-Clause',
                        copyright: 'Xintao Wang',
                        url: 'https://github.com/xinntao/Real-ESRGAN',
                      ),
                      _ComponentTile(
                        name: 'Real-CUGAN models (optional download, upscaling add-on)',
                        license: 'MIT',
                        copyright: 'bilibili',
                        url: 'https://github.com/bilibili/ailab/tree/main/Real-CUGAN',
                      ),
                      _ComponentTile(
                        name: 'DFTTest',
                        license: 'GPL 3.0',
                        copyright: 'Kevin Stone (tritical); port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest',
                      ),
                      _ComponentTile(
                        name: 'FFT3DFilter',
                        license: 'GPL 2.0',
                        copyright: 'Fizick (A.G. Balakhnin); port by '
                            'Yusuke Nakamura',
                        url: 'https://github.com/myrsloik/VapourSynth-FFT3DFilter',
                      ),
                      _ComponentTile(
                        name: 'TTempSmooth',
                        license: 'GPL 3.0',
                        copyright: 'Kevin Stone (tritical); port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TTempSmooth',
                      ),
                      _ComponentTile(
                        name: 'TCanny',
                        license: 'GPL 3.0',
                        copyright: 'Kevin Stone (tritical); port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny',
                      ),
                      _ComponentTile(
                        name: 'CTMF',
                        license: 'GPL 3.0',
                        copyright: 'Simon Perreault; port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF',
                      ),
                      _ComponentTile(
                        name: 'CAS',
                        license: 'MIT',
                        copyright: 'Holy Wu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CAS',
                      ),
                      _ComponentTile(
                        name: 'DCTFilter',
                        license: 'MIT',
                        copyright: 'HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter',
                      ),
                      _ComponentTile(
                        name: 'Deblock',
                        license: 'GPL 2.0',
                        copyright: 'Manao and Fizick; port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Deblock',
                      ),
                      _ComponentTile(
                        name: 'AddGrain',
                        license: 'GPL 3.0',
                        copyright: 'Tom Barry; port by HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-AddGrain',
                      ),
                      _ComponentTile(
                        name: 'neo_f3kdb',
                        license: 'GPL 3.0',
                        copyright: 'Xinyue Lu, from flash3kyuu_deband by '
                            'SAPikachu',
                        url: 'https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb',
                      ),
                      _ComponentTile(
                        name: 'Retinex',
                        license: 'GPL 3.0',
                        copyright: 'mawen1250',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Retinex',
                      ),
                      _ComponentTile(
                        name: 'BM3D',
                        license: 'MIT',
                        copyright: 'mawen1250',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-BM3D',
                      ),
                      _ComponentTile(
                        name: 'descale',
                        license: 'MIT',
                        copyright: 'Frechdachs; maintained by Jaded Encoding Thaumaturgy',
                        url: 'https://github.com/Jaded-Encoding-Thaumaturgy/vapoursynth-descale',
                      ),
                      _ComponentTile(
                        name: 'KNLMeansCL',
                        license: 'GPL 3.0',
                        copyright:
                            'Edoardo Brunetti; maintained by Jaded Encoding Thaumaturgy',
                        url:
                            'https://github.com/Jaded-Encoding-Thaumaturgy/vapoursynth-knlmeanscl',
                      ),
                      _ComponentTile(
                        name: 'DeScratch',
                        license: 'GPL 2.0',
                        copyright: 'Fizick (Alexander G. Balakhnin)',
                        url: 'https://github.com/vapoursynth/descratch',
                      ),
                      _ComponentTile(
                        name: 'AWarpSharp2',
                        license: 'ISC',
                        copyright: 'dubhater, after the AviSynth filter by SEt',
                        url: 'https://github.com/dubhater/vapoursynth-awarpsharp2',
                      ),
                      _ComponentTile(
                        name: 'TemporalMedian',
                        license: 'ISC',
                        copyright: 'dubhater',
                        url: 'https://github.com/dubhater/vapoursynth-temporalmedian',
                      ),
                      _ComponentTile(
                        name: 'FluxSmooth',
                        license: 'No copyright asserted',
                        copyright: 'Port by dubhater',
                        url: 'https://github.com/dubhater/vapoursynth-fluxsmooth',
                      ),
                      _ComponentTile(
                        name: 'Bifrost',
                        license: 'WTFPL',
                        copyright: 'Port by dubhater; original by '
                            'Fredrik Mellbin',
                        url: 'https://github.com/dubhater/vapoursynth-bifrost',
                      ),
                      _ComponentTile(
                        name: 'Bwdif',
                        license: 'LGPL 3.0+',
                        copyright: 'Thomas Mundt and HolyWu, based on YADIF by '
                            'Michael Niedermayer and James Darnley, using the '
                            'BBC Weston 3-field algorithm',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Bwdif',
                      ),
                      _ComponentTile(
                        name: 'FillBorders',
                        license: 'WTFPL',
                        copyright: 'dubhater — no copyright asserted upstream',
                        url: 'https://github.com/dubhater/vapoursynth-fillborders',
                      ),
                      _ComponentTile(
                        name: 'RemoveDirt',
                        license: 'GPL 2.0+',
                        copyright: 'Rainer Wittmann; additional work by '
                            'Ferenc Pintér',
                        url: 'https://github.com/pinterf/RemoveDirt',
                      ),
                      _ComponentTile(
                        name: 'DeDot',
                        license: 'GPL 2.0',
                        copyright: 'Fredrik Mellbin, after the AviSynth DeDot '
                            'filter',
                        url: 'https://github.com/dubhatervapoursynth/vapoursynth-dedot',
                      ),
                      _ComponentTile(
                        name: 'LGhost',
                        license: 'GPL 3.0+',
                        copyright: 'Port by HolyWu; original AviSynth plugin by '
                            'minamina',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-LGhost',
                      ),
                      _ComponentTile(
                        name: 'Vector Class Library',
                        license: 'Apache 2.0',
                        copyright: 'Agner Fog — SIMD code inside several '
                            'plugins above',
                        url: 'https://github.com/vectorclass/version2',
                      ),
                      _ComponentTile(
                        name: 'FFmpeg',
                        license: 'GPL 3.0+',
                        copyright: 'The FFmpeg developers — built with '
                            '--enable-gpl --enable-version3',
                        url: 'https://ffmpeg.org',
                      ),
                      _ComponentTile(
                        name: 'whisper.cpp (optional download)',
                        license: 'MIT',
                        copyright: 'The ggml authors (project started by Georgi Gerganov)',
                        url: 'https://github.com/ggml-org/whisper.cpp',
                      ),
                      _ComponentTile(
                        name: 'Whisper models (optional download)',
                        license: 'MIT',
                        copyright: 'OpenAI',
                        url: 'https://github.com/openai/whisper',
                      ),
                      _ComponentTile(
                        name: 'ONNX Runtime (optional download, AI runtime add-on)',
                        license: 'MIT',
                        copyright: 'Microsoft Corporation',
                        url: 'https://github.com/microsoft/onnxruntime',
                      ),
                      _ComponentTile(
                        name: 'NumPy (optional download, AI runtime add-on)',
                        license: 'BSD-3-Clause',
                        copyright: 'NumPy Developers',
                        url: 'https://github.com/numpy/numpy',
                      ),
                      _ComponentTile(
                        name: 'DirectML (optional download, AI runtime add-on, Windows)',
                        license: 'Microsoft Software License Terms',
                        copyright: 'Microsoft Corporation',
                        url: 'https://github.com/microsoft/DirectML',
                      ),
                      _ComponentTile(
                        name: 'DeepFilterNet (optional download, speech enhancement add-on)',
                        license: 'MIT OR Apache-2.0',
                        copyright: 'Hendrik Schröter',
                        url: 'https://github.com/Rikorose/DeepFilterNet',
                      ),
                      _ComponentTile(
                        name: 'libdvdread',
                        license: 'GPL 2.0+',
                        copyright: 'VideoLAN and contributors',
                        url: 'https://code.videolan.org/videolan/libdvdread',
                      ),
                      _ComponentTile(
                        name: 'FFTW',
                        license: 'GPL 2.0+',
                        copyright: 'Matteo Frigo and MIT',
                        url: 'https://www.fftw.org',
                      ),
                      _ComponentTile(
                        name: 'Boost',
                        license: 'BSL 1.0',
                        copyright: 'The Boost authors',
                        url: 'https://www.boost.org',
                      ),
                      _ComponentTile(
                        name: 'zlib',
                        license: 'zlib',
                        copyright: 'Jean-loup Gailly and Mark Adler',
                        url: 'https://zlib.net',
                      ),
                      _ComponentTile(
                        name: 'Zstandard',
                        license: 'BSD 3-Clause',
                        copyright: 'Meta Platforms, Inc. and affiliates',
                        url: 'https://github.com/facebook/zstd',
                      ),
                      _ComponentTile(
                        name: 'Flutter',
                        license: 'BSD 3-Clause',
                        copyright: 'The Flutter Authors',
                        url: 'https://github.com/flutter/flutter',
                      ),
                      _ComponentTile(
                        name: 'Python',
                        license: 'PSF License',
                        copyright: 'Python Software Foundation',
                        url: 'https://github.com/python/cpython',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Credits that are not bundled components: QTGMC is an algorithm
              // (shipped as part of havsfunc above), Hybrid is inspiration only.
              // Both are acknowledged in README.md, so neither gets a licence
              // badge here.
              Text(
                'QTGMC deinterlacing algorithm by Vit, originally based on '
                'TempGaussMC_beta2 by Didée. Inspired by Hybrid by Selur. '
                'If any attribution here is wrong, please open an issue.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
              ),

              const SizedBox(height: 16),

              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('View on GitHub'),
                    onPressed: () => _launchUrl(_githubUrl),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

class _ComponentTile extends StatelessWidget {
  final String name;
  final String license;
  final String copyright;
  final String url;

  const _ComponentTile({
    required this.name,
    required this.license,
    required this.copyright,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _launchUrl(url),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  Text(
                    copyright,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                license,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.open_in_new,
              size: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

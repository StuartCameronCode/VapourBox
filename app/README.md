# VapourBox — Flutter app

The Flutter (Dart) half of VapourBox: the UI, job configuration and preview. The
video processing itself runs in the Rust worker (`../worker`), which this app
spawns and talks to over JSON.

- Build instructions and project layout: [`../docs/BUILDING.md`](../docs/BUILDING.md)
- What VapourBox is: [`../README.md`](../README.md)

Quick reference:

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # after model changes
flutter test --exclude-tags heavy                          # what CI runs
flutter run                                                # needs the worker built
```

`flutter run` expects a worker binary alongside the app bundle and a populated
`deps/` directory — see BUILDING.md for the per-platform debug scripts that set
both up.

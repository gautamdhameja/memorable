# Memorable

Memorable is an iOS app that searches your photos and videos by description,
such as `my dog playing in the snow`. Search runs on your iPhone with the
[SigLIP2](https://arxiv.org/abs/2502.14786) model.

## Privacy

Your photos, videos, and searches stay on your device. Memorable has no server
and no analytics. It uses Apple services only to look up place names from photo
coordinates and to process purchases.

## Build

You need:

- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An iPhone with an A14 chip or later, running iOS 17 or later

To build:

1. Copy the compiled SigLIP2 Core ML bundles to `Memorable/Models/`. The build
   verifies them against `scripts/model_manifest.json`.
1. Generate and open the project:

   ```bash
   xcodegen generate
   open Memorable.xcodeproj
   ```

1. To run on a device, copy `Config/Local.xcconfig.example` to
   `Config/Local.xcconfig` and set your team ID.

## Test

```bash
python3 scripts/premerge.py
```

## License

Memorable is licensed under the [Apache License 2.0](LICENSE).

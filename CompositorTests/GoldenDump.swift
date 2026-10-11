import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Compositor

/// Writes golden-corpus artifacts for the Windows port instead of asserting.
///
/// This lives inside `CompositorTests` on purpose. That target's sources come from a
/// `PBXFileSystemSynchronizedRootGroup`, so dropping this file into `CompositorTests/` adds it
/// to the build with **no `project.pbxproj` edit** — which matters because this work is being
/// driven from a machine with no Swift toolchain, so every avoided pbxproj change is avoided
/// risk. Nothing else in the suite runs it: it is invoked only by the "Golden corpus" workflow,
/// which selects it with `-only-testing:CompositorTests/GoldenDump`.
///
/// The first increment has one job: settle the three byte-level questions that Foundation, not
/// this repository, decides — JSON indentation, the spacing around `:`, and how `/` and
/// non-ASCII characters are escaped.  `docs/writing-comp-files.md` shows a hand-written
/// example, which is not evidence of what `JSONEncoder` actually emits. The layer name below
/// deliberately contains both a slash and a non-ASCII character so a single artifact answers
/// all three at once.
@Suite @MainActor
struct GoldenDump {

    private static func write(_ data: Data, to relative: String, in root: URL) throws -> [String: Any] {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return ["path": relative, "bytes": data.count]
    }

    @Test func writeGoldenCorpus() async throws {
        // Where the corpus lands.
        //
        // Deliberately NOT the repository root. This test runs inside the sandboxed Compositor
        // app, so it inherits the app's sandbox, and the sandbox refuses writes anywhere outside
        // the app's own container - attempting it fails with NSCocoaErrorDomain 513, "Operation
        // not permitted". The container's Documents directory is writable and survives the run.
        // The resulting path is printed so the caller can collect from it rather than having to
        // reconstruct it.
        let container = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let out = ProcessInfo.processInfo.environment["GOLDEN_DUMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? container.appendingPathComponent("golden-out", isDirectory: true)

        // Start clean so a stale artifact can never be mistaken for a fresh one.
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Printed first, so the location is known even if something later fails.
        print("GOLDEN_DUMP_PATH=\(out.path)")

        var artifacts: [[String: Any]] = []

        // ---------------------------------------------------------------- 001 reference project
        // Slash + non-ASCII in a name; non-default resolution so that field is present.
        let session = EditorSession()
        session.createDocument(width: 4, height: 4, resolution: 300)
        session.addBlankLayer()
        session.addBlankLayer()
        if let first = session.projectSnapshot()?.manifest.layers.first?.id {
            session.renameLayer(first, to: "Hue/Saturation \u{1F324} sky")
        }
        let snapshot = try #require(session.projectSnapshot(), "session produced no snapshot")

        // renameLayer silently no-ops when the session is busy, which would quietly strip the
        // slash and the emoji out of the artifact and make 001 answer nothing. Print what
        // actually landed so the log shows whether the interesting characters survived.
        print("001 layer names: \(snapshot.manifest.layers.map(\.name))")
        print("001 layer count: \(snapshot.manifest.layers.count), resolution: \(String(describing: snapshot.manifest.resolution))")

        let comp = out.appendingPathComponent("001-minimal.comp", isDirectory: true)
        try await ProjectStore.shared.save(snapshot, to: comp)

        let manifestURL = comp.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)

        // Printed, not just written: this makes the CI log itself sufficient to settle the
        // formatting questions without downloading the artifact zip.
        print("=== BEGIN 001-manifest.json (\(manifestBytes.count) bytes) ===")
        print(String(decoding: manifestBytes, as: UTF8.self))
        print("=== END 001-manifest.json ===")
        print("001 first 128 bytes, hex: "
              + manifestBytes.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " "))
        print("001 has trailing newline: \(manifestBytes.last == 0x0A)")

        artifacts.append(try Self.write(manifestBytes, to: "001-minimal.manifest.json", in: out))

        // ---------------------------------------------------------------- 002 save/load/save
        // Reproduces ProjectTests.failedSavePreservesPreviouslySavedPackage's byte-comparison
        // idea: does a reload-and-resave reproduce identical bytes? If not, the writer is not
        // idempotent and no byte-exact golden is safe until that is understood.
        let loaded = try await ProjectStore.shared.load(from: comp)
        let second = out.appendingPathComponent("002-resave.comp", isDirectory: true)
        try await ProjectStore.shared.save(loaded, to: second)
        let resaved = try Data(contentsOf: second.appendingPathComponent("manifest.json"))
        let identical = resaved == manifestBytes
        print("002 reload->resave byte-identical: \(identical)")
        if !identical {
            print("=== BEGIN 002-manifest.json (\(resaved.count) bytes) ===")
            print(String(decoding: resaved, as: UTF8.self))
            print("=== END 002-manifest.json ===")
        }
        artifacts.append(try Self.write(resaved, to: "002-resave.manifest.json", in: out))

        // ---------------------------------------------------------------- 003 adjustments
        // One adjustment layer per kind, with every setting non-default and fixed, so the Windows
        // port can rebuild this same logical document from the same literals and compare the
        // adjustment subtrees byte for byte.
        //
        // Nothing here may be random. addAdjustment() seeds Grain and Add Noise from the system RNG
        // and gives a new Gradient Map the current foreground and background colors, so all three
        // are overwritten with literals below. A case whose bytes cannot be predicted twice over is
        // not a golden, it is a fingerprint of the machine that made it.
        let adjust = EditorSession()
        adjust.createDocument(width: 4, height: 4, resolution: 300)
        adjust.addBlankLayer()

        func setAdjustment(_ kind: AdjustmentKind, _ mutate: (inout LayerAdjustment) -> Void) {
            // Capture the layer set first, so the new layer is identified by difference rather than
            // by position. addAdjustment inserts relative to the active layer, and assuming "last"
            // is the new one is exactly the kind of guess that silently wrote every setting onto a
            // single layer in the first version of this case.
            let before = Set(adjust.projectSnapshot()?.manifest.layers.map(\.id) ?? [])
            adjust.addAdjustment(kind)
            // addAdjustment opens the new adjustment's editor for every kind except Invert, and
            // canEditLayers refuses any further layer edit while an editor is open. Without closing
            // it here, the second and every later call is ignored: the run produces one adjustment
            // layer carrying whichever kind was set last, and nothing says so.
            adjust.adjustmentEditingID = nil
            guard let snapshot = adjust.projectSnapshot(),
                  let layer = snapshot.manifest.layers.first(where: { !before.contains($0.id) }) else {
                print("003 ERROR: \(kind.rawValue) was not added")
                return
            }
            var value = LayerAdjustment(kind: kind)
            mutate(&value)
            // updateAdjustment refuses an invalid value silently, which would leave the layer on its
            // defaults and quietly weaken the artifact, so say so in the log instead.
            guard value.isValid else {
                print("003 ERROR: \(kind.rawValue) is not valid, so updateAdjustment will refuse it")
                return
            }
            adjust.updateAdjustment(layer.id, value: value)
            let landed = adjust.projectSnapshot()?.manifest.layers.first { $0.id == layer.id }?.adjustment
            if landed?.kind != kind {
                print("003 ERROR: \(kind.rawValue) did not take, layer has \(String(describing: landed?.kind))")
            }
        }

        setAdjustment(.hsv) {
            $0.hue = 30; $0.saturation = 40; $0.lightness = -20; $0.colorize = true
        }
        setAdjustment(.levels) {
            $0.levels.ranges = [
                LevelRange(black: 10, gamma: 1.5, white: 240, outputBlack: 5, outputWhite: 250),
                LevelRange(black: 0, gamma: 1, white: 255, outputBlack: 0, outputWhite: 255),
                LevelRange(black: 20, gamma: 0.8, white: 200, outputBlack: 10, outputWhite: 220),
                LevelRange(black: 5, gamma: 2, white: 250, outputBlack: 0, outputWhite: 255),
            ]
        }
        setAdjustment(.curves) {
            $0.curves.channels[1] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 200),
                                     CurvePoint(x: 255, y: 255)]
            $0.curves.channels[3] = [CurvePoint(x: 0, y: 10), CurvePoint(x: 64, y: 30),
                                     CurvePoint(x: 192, y: 240), CurvePoint(x: 255, y: 250)]
        }
        setAdjustment(.exposure) {
            $0.exposure = ExposureSettings(exposure: 1.5, offset: -0.25, gamma: 2.2)
        }
        setAdjustment(.gradientMap) {
            $0.gradientMap = GradientMapSettings(
                shadows: AdjustmentColor(red: 0.1, green: 0.2, blue: 0.3),
                highlights: AdjustmentColor(red: 0.9, green: 0.8, blue: 0.7),
                reversed: true)
        }
        setAdjustment(.grain) {
            $0.grain = GrainSettings(amount: 30, size: 2.5, roughness: 60, seed: 123456)
        }
        setAdjustment(.addNoise) {
            $0.resolvedNoiseAmount = 15
            $0.resolvedNoiseGaussian = true
            $0.resolvedNoiseMonochromatic = true
            $0.resolvedNoiseSeed = 654321
        }
        setAdjustment(.gaussianBlur) { $0.gaussianRadius = 8.5 }
        setAdjustment(.motionBlur) {
            $0.resolvedMotionAngle = -45; $0.resolvedMotionDistance = 100
        }
        // Invert carries no settings at all, so this layer is the control case: it must emit the
        // same key set as a default adjustment of any kind.
        setAdjustment(.invert) { _ in }
        setAdjustment(.blackWhite) {
            $0.blackWhite = BlackWhiteSettings(reds: 45, yellows: 65, greens: 35, cyans: 55,
                                               blues: 25, magentas: 85, tint: true, tintHue: 200,
                                               tintSaturation: 15)
        }
        setAdjustment(.colorBalance) {
            $0.colorBalance = ColorBalanceSettings(
                shadowCyanRed: 10, shadowMagentaGreen: -20, shadowYellowBlue: 30,
                midCyanRed: -5, midMagentaGreen: 15, midYellowBlue: -25,
                highlightCyanRed: 20, highlightMagentaGreen: 5, highlightYellowBlue: -10,
                preserveLuminosity: false)
        }

        let adjustSnapshot = try #require(adjust.projectSnapshot(), "adjustment session produced no snapshot")
        let landedKinds = adjustSnapshot.manifest.layers.compactMap { $0.adjustment?.kind.rawValue }
        print("003 kinds: \(landedKinds)")
        // The first attempt at this case produced a 3427-byte "adjustment corpus" holding a single
        // kind, because a guard refused eleven of the twelve inserts and nothing checked. A dump that
        // writes fewer cases than intended is worse than no dump, so it says so out loud.
        if landedKinds.count != 12 {
            print("003 ERROR: expected 12 adjustment layers, got \(landedKinds.count)")
        }
        let adjustComp = out.appendingPathComponent("003-adjustments.comp", isDirectory: true)
        try await ProjectStore.shared.save(adjustSnapshot, to: adjustComp)
        let adjustManifest = try Data(contentsOf: adjustComp.appendingPathComponent("manifest.json"))
        print("=== BEGIN 003-adjustments.manifest.json (\(adjustManifest.count) bytes) ===")
        print(String(decoding: adjustManifest, as: UTF8.self))
        print("=== END 003-adjustments.manifest.json ===")
        artifacts.append(try Self.write(adjustManifest, to: "003-adjustments.manifest.json", in: out))

        // ---------------------------------------------------------------- 004 HSV ranges
        // Kept apart from 003 on purpose. Swift encodes [ColorRange: T] as an *unkeyed* alternating
        // key/value array, because ColorRange is not CodingKeyRepresentable, and that array's order
        // is Dictionary hash order rather than declaration order. This case records what the order
        // actually was, and saves the same document twice so the log shows whether it is even
        // stable within a single run. If those two differ, no byte-exact comparison of an HSV
        // document is possible for anyone, including the app that wrote it.
        let hsvSession = EditorSession()
        hsvSession.createDocument(width: 4, height: 4, resolution: 300)
        hsvSession.addBlankLayer()
        hsvSession.addAdjustment(.hsv)
        if let id = hsvSession.projectSnapshot()?.manifest.layers.last?.id {
            var value = LayerAdjustment(kind: .hsv)
            var settings = HueSaturationSettings(hue: 10, saturation: 20, lightness: 30, range: .reds)
            settings.range = .yellows
            settings.colorize = true
            settings.invertRange = true
            settings.adjustments[.yellows] = RangeAdjustment(hue: 11, saturation: 21, lightness: 31)
            settings.adjustments[.greens] = RangeAdjustment(hue: 12, saturation: 22, lightness: 32)
            value.hsvSettings = settings
            if value.isValid {
                hsvSession.updateAdjustment(id, value: value)
            } else {
                print("004 ERROR: the HSV adjustment is not valid, so updateAdjustment will refuse it")
            }
        }
        let hsvSnapshot = try #require(hsvSession.projectSnapshot(), "HSV session produced no snapshot")
        let hsvComp = out.appendingPathComponent("004-hsv.comp", isDirectory: true)
        try await ProjectStore.shared.save(hsvSnapshot, to: hsvComp)
        let hsvManifest = try Data(contentsOf: hsvComp.appendingPathComponent("manifest.json"))
        print("=== BEGIN 004-hsv.manifest.json (\(hsvManifest.count) bytes) ===")
        print(String(decoding: hsvManifest, as: UTF8.self))
        print("=== END 004-hsv.manifest.json ===")
        artifacts.append(try Self.write(hsvManifest, to: "004-hsv.manifest.json", in: out))

        let hsvAgain = out.appendingPathComponent("004-hsv-again.comp", isDirectory: true)
        try await ProjectStore.shared.save(hsvSnapshot, to: hsvAgain)
        let hsvAgainManifest = try Data(contentsOf: hsvAgain.appendingPathComponent("manifest.json"))
        print("004 second save byte-identical to the first: \(hsvAgainManifest == hsvManifest)")
        artifacts.append(try Self.write(hsvAgainManifest, to: "004-hsv-again.manifest.json", in: out))

        // ---------------------------------------------------------------- 005 adjustment pixels
        //
        // The manifests settle the file format; they say nothing about whether the port draws the same
        // picture. These artifacts are that comparison: one input raster, and the output of every
        // adjustment the port claims to reproduce exactly, as raw premultiplied RGBA8.
        //
        // Three things make this a fair test rather than a hopeful one.
        //
        // First, the inputs are dumped exactly as constructed, with no round trip, so the C# side is
        // comparing against the bytes this file intended rather than against whatever a color-managed
        // context would have made of them.
        //
        // Second, the round trip is dumped too. Reading pixels back needs a CGContext, and if that
        // path is not the identity then every output below is shifted by it and the comparison would
        // be measuring the harness. The round-trip artifact is byte-compared against the input by the
        // C# probe, so that assumption is checked rather than assumed.
        //
        // Third, each adjustment is serialized with the project's own encoder. The port reads the
        // settings back with the reader it already proved byte-exact, so no setting is retyped by hand
        // on the far side and a disagreement can only be about pixels.
        //
        // The two Core Image blurs are deliberately absent. Their kernels are Apple's and unpublished
        // (Filters.swift:210 and :214), so there is no reference pixel to match and claiming one would
        // be a lie. See the plan's rendering section.
        let pixelSide = 24
        let opaqueInput = try #require(Self.makeInput(side: pixelSide, varyingAlpha: false),
                                       "005 could not build the opaque input raster")
        let alphaInput = try #require(Self.makeInput(side: pixelSide, varyingAlpha: true),
                                      "005 could not build the varying-alpha input raster")

        artifacts.append(try Self.write(Self.rawBytes(side: pixelSide, varyingAlpha: false),
                                        to: "005-input-opaque.raw", in: out))
        artifacts.append(try Self.write(Self.rawBytes(side: pixelSide, varyingAlpha: true),
                                        to: "005-input-alpha.raw", in: out))
        artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: opaqueInput), "005 round trip 1 failed"),
                                        to: "005-roundtrip-opaque.raw", in: out))
        artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: alphaInput), "005 round trip 2 failed"),
                                        to: "005-roundtrip-alpha.raw", in: out))

        // What the kernel actually receives.
        //
        // The adjustment routines do not run on the image that was handed in: every one of them goes
        // through ImageAdjustmentPixels.run, which draws the image into a BrushRaster context and runs
        // the kernel on that buffer (ImageAdjustments.swift:100-108). That context is flipped
        // (BrushStroke.swift:40-41), and BrushRaster.draw only takes its byte-copy fast path when the
        // image's bitmapInfo matches the context's exactly - otherwise it rasterizes.
        //
        // So the pixels the kernel sees are not necessarily the pixels that went in. Dumping them
        // separates the two: if this differs from the input, a mismatch on the C# side is that draw,
        // not the adjustment, and blaming the renderer would be wrong.
        for (suffix, input) in [("opaque", opaqueInput), ("alpha", alphaInput)] {
            do {
                let probe = try BrushRaster.context(width: pixelSide, height: pixelSide, mask: false)
                BrushRaster.draw(input, in: CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide),
                                 mask: false, context: probe)
                guard let data = probe.data else {
                    print("005 ERROR: the \(suffix) kernel-input context had no buffer")
                    continue
                }
                let buffer = Data(bytes: data, count: pixelSide * pixelSide * 4)
                artifacts.append(try Self.write(buffer, to: "005-kernelinput-\(suffix).raw", in: out))
            } catch {
                print("005 ERROR: could not capture the \(suffix) kernel input: \(error)")
            }
        }

        let pixelEncoder = JSONEncoder()
        pixelEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (name, adjustment) in Self.pixelCases() {
            // The same literals the manifest case uses, so a setting cannot drift between the two.
            guard adjustment.isValid else {
                print("005 ERROR: \(name) is not valid, skipping")
                continue
            }
            artifacts.append(try Self.write(try pixelEncoder.encode(adjustment),
                                            to: "005-\(name).adjustment.json", in: out))

            for (suffix, input) in [("opaque", opaqueInput), ("alpha", alphaInput)] {
                let rendered = try adjustment.apply(input)
                let raw = try #require(Self.rgbaBytes(of: rendered), "005 \(name)/\(suffix) produced no bytes")
                // A wrong length would let the C# side compare a truncated buffer successfully.
                guard raw.count == pixelSide * pixelSide * 4 else {
                    print("005 ERROR: \(name)/\(suffix) is \(raw.count) bytes, expected \(pixelSide * pixelSide * 4)")
                    continue
                }
                artifacts.append(try Self.write(raw, to: "005-\(name)-\(suffix).raw", in: out))
            }
        }

        // ---------------------------------------------------------------- 006 blend modes
        //
        // Case 005 covers the C kernels. This covers compositing, which no C file implements: the app
        // hands the work to Core Graphics for the modes it can draw, and to Core Image for the eleven
        // it cannot (LayerAppearance.swift:44-56 and SeparableBlend.swift).
        //
        // That makes these a different kind of reference from case 005, and worth stating plainly. The
        // adjustment kernels are the port's own source compiled twice, so agreement there follows from
        // the build once it is set up right. The blend modes are Apple's closed implementations against
        // the port's own arithmetic, so agreement is a question rather than a formality - and the app's
        // own comments predict part of the answer. Core Graphics' Soft Light "is up to 25 levels off
        // Photoshop's with a light blend color (Core Image's is within 5)"; Color Burn and Color Dodge
        // "ignore how transparent the source is, so a soft brush comes out with a hard edge"
        // (SeparableBlend.swift:6-8). The port implements the Photoshop formulas, so for those modes a
        // mismatch is the expected result and the useful output is knowing its size.
        //
        // Each mode is composited through the same dispatch the canvas uses, so what is dumped here is
        // what the app draws rather than a restatement of it.
        let blendSide = 24
        let backdrop = try #require(Self.makeBlendRaster(side: blendSide, variant: 0, varyingAlpha: false),
                                    "006 could not build the backdrop raster")
        let blendOpaque = try #require(Self.makeBlendRaster(side: blendSide, variant: 1, varyingAlpha: false),
                                       "006 could not build the opaque source raster")
        let blendAlpha = try #require(Self.makeBlendRaster(side: blendSide, variant: 1, varyingAlpha: true),
                                      "006 could not build the varying-alpha source raster")

        artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: backdrop), "006 backdrop unreadable"),
                                        to: "006-backdrop.raw", in: out))
        artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: blendOpaque), "006 source unreadable"),
                                        to: "006-source-opaque.raw", in: out))
        artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: blendAlpha), "006 source-alpha unreadable"),
                                        to: "006-source-alpha.raw", in: out))

        let blendRect = CGRect(x: 0, y: 0, width: blendSide, height: blendSide)
        for mode in LayerBlendMode.allCases {
            let slug = Self.slug(mode.rawValue)

            for (suffix, source) in [("opaque", blendOpaque), ("alpha", blendAlpha)] {
                do {
                    // A plain, unflipped context rather than BrushRaster.context, and that choice is
                    // load-bearing. BrushRaster's context carries a flip (BrushStroke.swift:40-41) so
                    // that its coordinate system has a top-left origin. An image drawn into a flipped
                    // context lands upside down in the buffer, so reading that buffer back yields the
                    // raster vertically mirrored - which is exactly what happened on the first run of
                    // this case: "Normal" came out byte-equal to the source flipped, not to the source.
                    //
                    // The blend is per-pixel and so is unaffected by which pixel sits where; what the
                    // flip breaks is the comparison, because the inputs are dumped top-down. Rather than
                    // have the C# side mirror half the artifacts, the case draws into a context with no
                    // transform, where an image drawn at the full extent reads back unchanged. Nothing
                    // about the dispatch under test changes: SeparableBlend.draw and setBlendMode are
                    // still the two paths, and both work on any bitmap context.
                    guard let context = CGContext(data: nil, width: blendSide, height: blendSide,
                                                  bitsPerComponent: 8, bytesPerRow: blendSide * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                      | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        print("006 ERROR: \(slug)/\(suffix) could not make a context")
                        continue
                    }
                    context.interpolationQuality = .none
                    context.draw(backdrop, in: blendRect)

                    if SeparableBlend.needsSurface(mode) {
                        // The canvas route for the modes Core Graphics cannot draw.
                        let drawn = SeparableBlend.draw(mode, in: context) { surface in
                            surface.draw(source, in: blendRect)
                        }
                        if !drawn { print("006 ERROR: \(slug)/\(suffix) found no Core Image surface") }
                    } else {
                        context.saveGState()
                        context.setBlendMode(mode.cgMode)
                        context.setAlpha(1)
                        context.draw(source, in: blendRect)
                        context.restoreGState()
                    }

                    guard let image = context.makeImage(),
                          let raw = Self.rgbaBytes(of: image) else {
                        print("006 ERROR: \(slug)/\(suffix) produced no bytes")
                        continue
                    }
                    artifacts.append(try Self.write(raw, to: "006-\(slug)-\(suffix).raw", in: out))
                } catch {
                    print("006 ERROR: \(slug)/\(suffix) failed: \(error)")
                }
            }
        }
        // The mode list is dumped rather than left implicit: the C# side must know which Core Image
        // filter each one used, because that is what decides whether a mismatch is expected.
        var modeIndex: [[String: Any]] = []
        for mode in LayerBlendMode.allCases {
            modeIndex.append(["slug": Self.slug(mode.rawValue),
                              "name": mode.rawValue,
                              "path": SeparableBlend.needsSurface(mode) ? "coreImage" : "coreGraphics",
                              "filter": mode.coreImageFilter ?? ""])
        }
        artifacts.append(try Self.write(try JSONSerialization.data(withJSONObject: modeIndex,
                                                                   options: [.prettyPrinted, .sortedKeys]),
                                        to: "006-modes.json", in: out))

        // ---------------------------------------------------------------- 007 layer stack
        //
        // Cases 005 and 006 cover single-raster work: a kernel over one image, and one blend of two.
        // Neither exercises the thing an image editor actually does, which is put several layers at
        // several places on one canvas and resolve them in order. This renders a real layer stack
        // through ImageExporter - the same path export uses, with no UI in it - and dumps the result.
        //
        // The stack is split into two artifacts on purpose, because only one of them can be exact:
        //
        //   * The "exact" stack places every layer unrotated, unscaled and on whole pixels with a
        //     sampling mode that resolves to no resampling at all. LayerRenderer returns .none for an
        //     upright layer landing pixel for pixel (LayerRenderer.swift:44-47), so its pixels are
        //     copied rather than filtered, and what remains is placement, opacity, masking and blending
        //     - all of which are arithmetic the port can match.
        //   * The "rotated" stack adds one rotated layer. That goes through Core Graphics' resampling,
        //     which is closed, so it is dumped to measure where exactness ends rather than to be
        //     matched. Reporting it is the point; asserting it would be a lie.
        //
        // Orientation is checked rather than assumed. ImageExporter's context is flipped
        // (ImageExporter.swift:32-33), and case 006 already showed that drawing into a flipped context
        // mirrors the raster. LayerRenderer compensates with its own scaleBy(y: -1) for a layer that is
        // not flipped (LayerRenderer.swift:22), so the export should come out upright - but that is a
        // deduction, and the first artifact here exists to test it: the base layer fills the whole
        // canvas at 1:1, so if the render is upright the output starts out byte-equal to that raster.
        let stackWidth = 40
        let stackHeight = 32

        // slug, raster variant, pixel size, origin, opacity, blend, masked
        // slug, raster variant, pixel size, origin, opacity, blend, masked, rotation in degrees.
        // Rotation is carried by every entry, zero for the exact stack and 17 for the one rotated
        // layer, so the two stacks have the same shape and the rotated one can simply be appended.
        let exactStack: [(String, Int, Int, Int, CGFloat, CGFloat, Double, LayerBlendMode, Bool, CGFloat)] = [
            ("base", 0, stackWidth, stackHeight, 0, 0, 1.0, .normal, false, 0),
            ("multiply", 1, 16, 16, 8, 6, 0.6, .multiply, false, 0),
            ("screen", 2, 24, 18, 5, 10, 0.85, .screen, false, 0),
            ("masked", 3, 20, 14, 12, 4, 1.0, .normal, true, 0),
        ]
        let rotatedLayer = ("rotated", 1, 12, 12, CGFloat(26), CGFloat(18), 0.7, LayerBlendMode.normal, false, CGFloat(17))

        /// Builds a snapshot from a layer list, in the order the manifest stores them: bottom first.
        func stackSnapshot(_ layers: [(String, Int, Int, Int, CGFloat, CGFloat, Double, LayerBlendMode, Bool, CGFloat)])
            -> (ProjectSnapshot, [String: CGImage], [String: Data]) {
            var records: [ProjectLayerRecord] = []
            var images: [UUID: ImportedImage] = [:]
            var masks: [UUID: ImportedImage] = [:]
            var rasters: [String: CGImage] = [:]
            var maskBytes: [String: Data] = [:]

            for (slug, variant, pixelWidth, pixelHeight, x, y, opacity, blend, masked, rotation) in layers {
                let id = UUID()
                guard let raster = Self.stackRaster(width: pixelWidth, height: pixelHeight, variant: variant),
                      let thumbnail = Self.stackRaster(width: max(1, pixelWidth / 2), height: max(1, pixelHeight / 2),
                                                       variant: variant) else {
                    print("007 ERROR: could not build the \(slug) raster")
                    continue
                }
                rasters[slug] = raster
                records.append(ProjectLayerRecord(
                    id: id, name: slug, isVisible: true,
                    transform: LayerTransform(origin: CGPoint(x: x, y: y),
                                              size: CGSize(width: pixelWidth, height: pixelHeight),
                                              rotation: rotation),
                    imageFile: "\(slug).png", opacity: opacity, blendMode: blend,
                    maskFile: masked ? "\(slug)-mask.png" : nil))
                images[id] = ImportedImage(image: raster, thumbnail: thumbnail, name: slug)

                if masked, let mask = Self.stackMask(width: pixelWidth, height: pixelHeight) {
                    masks[id] = ImportedImage(image: mask.image, thumbnail: mask.image, name: "\(slug)-mask")
                    maskBytes[slug] = mask.bytes
                }
            }

            let manifest = ProjectManifest(documentID: UUID(), width: stackWidth, height: stackHeight,
                                           activeLayerID: records.last?.id, layers: records)
            return (ProjectSnapshot(manifest: manifest, images: images, masks: masks), rasters, maskBytes)
        }

        do {
            let (exactSnapshot, exactRasters, exactMasks) = stackSnapshot(exactStack)
            let exactRendered = try await ImageExporter.shared.render(exactSnapshot)
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: exactRendered.image),
                                                         "007 exact stack produced no bytes"),
                                            to: "007-stack-exact.raw", in: out))

            // The base raster on its own: the same full-canvas, opaque, 1:1 layer as the bottom of the
            // stack, so the C# side can tell an upright render from a mirrored one before judging the
            // rest. Kept separate from the composite so that check does not depend on any other layer.
            if let base = exactRasters["base"], let bytes = Self.rgbaBytes(of: base) {
                artifacts.append(try Self.write(bytes, to: "007-base.raw", in: out))
            }
            for (slug, raster) in exactRasters.sorted(by: { $0.key < $1.key }) {
                guard let bytes = Self.rgbaBytes(of: raster) else { continue }
                artifacts.append(try Self.write(bytes, to: "007-layer-\(slug).raw", in: out))
            }
            for (slug, bytes) in exactMasks.sorted(by: { $0.key < $1.key }) {
                artifacts.append(try Self.write(bytes, to: "007-mask-\(slug).raw", in: out))
            }

            var rotatedStack = exactStack
            rotatedStack.append(rotatedLayer)
            let (rotatedSnapshot, rotatedRasters, _) = stackSnapshot(rotatedStack)
            let rotatedRendered = try await ImageExporter.shared.render(rotatedSnapshot)
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rotatedRendered.image),
                                                         "007 rotated stack produced no bytes"),
                                            to: "007-stack-rotated.raw", in: out))
            if let raster = rotatedRasters["rotated"], let bytes = Self.rgbaBytes(of: raster) {
                artifacts.append(try Self.write(bytes, to: "007-layer-rotated.raw", in: out))
            }

            // The layer list, dumped rather than left implicit. The C# side rebuilds the same stack from
            // these numbers instead of hard-coding a second copy that could drift from this one.
            let described = (exactStack + [rotatedLayer]).map { layer -> [String: Any] in
                ["slug": layer.0, "variant": layer.1, "pixelWidth": layer.2, "pixelHeight": layer.3,
                 "x": Double(layer.4), "y": Double(layer.5), "opacity": layer.6,
                 "blend": layer.7.rawValue, "masked": layer.8, "rotation": Double(layer.9)]
            }
            artifacts.append(try Self.write(try JSONSerialization.data(
                withJSONObject: ["width": stackWidth, "height": stackHeight,
                                 "exactCount": exactStack.count, "layers": described],
                options: [.prettyPrinted, .sortedKeys]), to: "007-stack.json", in: out))
        } catch {
            print("007 ERROR: the layer stack could not be rendered: \(error)")
        }

        // ---------------------------------------------------------------- 008 folders
        //
        // Case 007 stacks flat layers, which is the easy half of a stack. This adds folders, and folders
        // are where a port most easily invents compositing the original does not do.
        //
        // The Mac app does NOT composite a folder as a unit. Its own comment says so plainly: "Folders
        // are pass-through - what's inside is drawn straight onto what is below, never composited as a
        // unit - so the folder's opacity is applied to each of those layers rather than to the folder as
        // a whole" (LayerGroups.swift:49-52). A folder therefore contributes exactly two things to the
        // layers inside it: its opacity, multiplied into each child, and its mask, which clips each
        // child. Its own blend mode is never applied.
        //
        // So the interesting numbers here are the effective opacities, chosen so that a port which
        // composites folders as groups lands somewhere different:
        //
        //     base        own 1.00                             -> 1.00
        //     inside-a    own 0.80, inside folder 0.70         -> 0.56
        //     inside-b    own 1.00, inside folder 0.70         -> 0.70
        //     deep        own 1.00, inside nested 0.50,
        //                          inside folder 0.70         -> 0.35
        //     top         own 0.90                             -> 0.90
        //
        // 0.56 and 0.35 are deliberately not representable in eight bits, so a port that rounds a
        // folder opacity on the way down, or applies it as a second blend instead of one multiplication,
        // cannot land on the same bytes by luck.
        //
        // A hidden folder is included too: nothing inside it may be drawn. The check is that the render
        // matches one built without it at all, rather than that it merely looks plausible.
        let folderWidth = 40
        let folderHeight = 32

        // slug, variant, pixel w/h, origin, opacity, blend, masked, rotation, isGroup, parent slug, visible
        typealias FolderLayer = (String, Int, Int, Int, CGFloat, CGFloat, Double, LayerBlendMode,
                                 Bool, CGFloat, Bool, String?, Bool)
        let folderStack: [FolderLayer] = [
            ("base",       0, folderWidth, folderHeight,  0,  0, 1.00, .normal,   false, 0, false, nil,      true),
            ("folder",     0, folderWidth, folderHeight,  0,  0, 0.70, .normal,   false, 0, true,  nil,      true),
            ("inside-a",   1, 16,          16,            4,  4, 0.80, .normal,   false, 0, false, "folder", true),
            ("inside-b",   2, 20,          12,           14, 10, 1.00, .multiply, false, 0, false, "folder", true),
            ("nested",     0, folderWidth, folderHeight,  0,  0, 0.50, .normal,   false, 0, true,  "folder", true),
            ("deep",       3, 12,          12,           22,  6, 1.00, .normal,   false, 0, false, "nested", true),
            ("top",        1, 18,          18,           10, 12, 0.90, .screen,   false, 0, false, nil,      true),
            // Inside a folder that is switched off. Neither may reach the canvas.
            ("dark",       0, folderWidth, folderHeight,  0,  0, 1.00, .normal,   false, 0, true,  nil,      false),
            ("dark-child", 1, 16,          16,            2,  2, 1.00, .difference, false, 0, false, "dark", true),
        ]

        var folderIds: [String: UUID] = [:]
        var folderRecords: [ProjectLayerRecord] = []
        var folderImages: [UUID: ImportedImage] = [:]

        for (slug, variant, pixelWidth, pixelHeight, x, y, opacity, blend,
             masked, rotation, isGroup, parent, visible) in folderStack {
            let id = UUID()
            folderIds[slug] = id
            if !isGroup {
                guard let raster = Self.stackRaster(width: pixelWidth, height: pixelHeight, variant: variant),
                      let thumbnail = Self.stackRaster(width: max(1, pixelWidth / 2), height: max(1, pixelHeight / 2),
                                                       variant: variant) else {
                    print("008 ERROR: could not build the \(slug) raster")
                    continue
                }
                folderImages[id] = ImportedImage(image: raster, thumbnail: thumbnail, name: slug)
            }
            folderRecords.append(ProjectLayerRecord(
                id: id, name: slug, isVisible: visible,
                transform: LayerTransform(origin: CGPoint(x: x, y: y),
                                          size: CGSize(width: pixelWidth, height: pixelHeight),
                                          rotation: rotation),
                imageFile: isGroup ? nil : "\(slug).png",
                parentID: parent.flatMap { folderIds[$0] },
                isGroup: isGroup, opacity: opacity, blendMode: blend,
                maskFile: masked ? "\(slug)-mask.png" : nil))
        }

        do {
            let folderManifest = ProjectManifest(documentID: UUID(), width: folderWidth, height: folderHeight,
                                                 activeLayerID: nil, layers: folderRecords)
            let folderRendered = try await ImageExporter.shared.render(
                ProjectSnapshot(manifest: folderManifest, images: folderImages, masks: [:]))
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: folderRendered.image),
                                                         "008 folder stack produced no bytes"),
                                            to: "008-stack.raw", in: out))

            // The same stack with the hidden folder taken out entirely. The far side asserts the two
            // renders are identical, which is what "switched off" has to mean.
            let shownRecords = folderRecords.filter { $0.name != "dark" && $0.name != "dark-child" }
            let shownManifest = ProjectManifest(documentID: UUID(), width: folderWidth, height: folderHeight,
                                                activeLayerID: nil, layers: shownRecords)
            let shownRendered = try await ImageExporter.shared.render(
                ProjectSnapshot(manifest: shownManifest, images: folderImages, masks: [:]))
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: shownRendered.image),
                                                         "008 visible-only stack produced no bytes"),
                                            to: "008-stack-without-hidden.raw", in: out))

            let described: [[String: Any]] = folderStack.map { layer in
                ["slug": layer.0, "variant": layer.1, "pixelWidth": layer.2, "pixelHeight": layer.3,
                 "x": Double(layer.4), "y": Double(layer.5), "opacity": layer.6,
                 "blend": layer.7.rawValue, "masked": layer.8, "rotation": Double(layer.9),
                 "isGroup": layer.10, "parent": layer.11 ?? "", "visible": layer.12]
            }
            artifacts.append(try Self.write(try JSONSerialization.data(
                withJSONObject: ["width": folderWidth, "height": folderHeight, "layers": described],
                options: [.prettyPrinted, .sortedKeys]), to: "008-folders.json", in: out))
        } catch {
            print("008 ERROR: the folder stack could not be rendered: \(error)")
        }

        // ---------------------------------------------------------------- 009 folder masks
        //
        // Case 008 established that a folder is pass-through: its opacity multiplies into each layer
        // inside it. This is the other half of the same idea - a folder's mask clips each of those
        // layers, multiplied with the layer's own mask.
        //
        // The part most likely to be got wrong is the edge of the mask's rect. Core Graphics intersects
        // the current clip with the mask's rect and the mask's coverage in one operation
        // (LayerMask.swift:178-187), so a folder mask smaller than the canvas does not merely fade what
        // is under it - it ERASES everything inside the folder that falls outside that rect. Treating a
        // mask as "multiply by the coverage, 1 outside it" is the natural misreading, and the "edge"
        // layer below sits half in and half out of the folder's rect specifically to catch it.
        //
        // The folder here covers (4,3) to (28,23) of a 40x32 canvas:
        //
        //     base      (0,0) 40x32   outside the folder, must be untouched
        //     folder    (4,3) 24x20   the folder, carrying a 24x20 mask
        //     inside    (6,6) 16x16   wholly inside; folder mask only
        //     both     (16,10) 20x14   inside, and carrying its own mask too - the two multiply
        //     edge      (0,0) 10x10   half outside the folder's rect; the outside half must vanish
        //     outside  (20,2) 16x16   not in the folder at all, must be untouched
        let maskCanvasWidth = 40
        let maskCanvasHeight = 32

        typealias MaskedFolderLayer = (String, Int, Int, Int, CGFloat, CGFloat, Double, LayerBlendMode,
                                       Bool, CGFloat, Bool, String?, Bool)
        let maskStack: [MaskedFolderLayer] = [
            ("base",    0, maskCanvasWidth, maskCanvasHeight,  0,  0, 1.0, .normal, false, 0, false, nil,      true),
            ("folder",  0, 24,              20,                4,  3, 1.0, .normal, true,  0, true,  nil,      true),
            ("inside",  1, 16,              16,                6,  6, 1.0, .normal, false, 0, false, "folder", true),
            ("both",    2, 20,              14,               16, 10, 1.0, .normal, true,  0, false, "folder", true),
            ("edge",    3, 10,              10,                0,  0, 1.0, .normal, false, 0, false, "folder", true),
            ("outside", 1, 16,              16,               20,  2, 1.0, .normal, false, 0, false, nil,      true),
        ]

        var maskIds: [String: UUID] = [:]
        var maskRecords: [ProjectLayerRecord] = []
        var maskImages: [UUID: ImportedImage] = [:]
        var maskAssets: [UUID: ImportedImage] = [:]

        for (slug, variant, pixelWidth, pixelHeight, x, y, opacity, blend,
             masked, rotation, isGroup, parent, visible) in maskStack {
            let id = UUID()
            maskIds[slug] = id
            if !isGroup {
                guard let raster = Self.stackRaster(width: pixelWidth, height: pixelHeight, variant: variant),
                      let thumbnail = Self.stackRaster(width: max(1, pixelWidth / 2), height: max(1, pixelHeight / 2),
                                                       variant: variant) else {
                    print("009 ERROR: could not build the \(slug) raster")
                    continue
                }
                maskImages[id] = ImportedImage(image: raster, thumbnail: thumbnail, name: slug)
            }
            var maskFile: String? = nil
            if masked, let mask = Self.stackMask(width: pixelWidth, height: pixelHeight) {
                maskAssets[id] = ImportedImage(image: mask.image, thumbnail: mask.image, name: "\(slug)-mask")
                maskFile = "\(slug)-mask.png"
            }
            maskRecords.append(ProjectLayerRecord(
                id: id, name: slug, isVisible: visible,
                transform: LayerTransform(origin: CGPoint(x: x, y: y),
                                          size: CGSize(width: pixelWidth, height: pixelHeight),
                                          rotation: rotation),
                imageFile: isGroup ? nil : "\(slug).png",
                parentID: parent.flatMap { maskIds[$0] },
                isGroup: isGroup, opacity: opacity, blendMode: blend,
                maskFile: maskFile))
        }

        do {
            let maskManifest = ProjectManifest(documentID: UUID(), width: maskCanvasWidth, height: maskCanvasHeight,
                                               activeLayerID: nil, layers: maskRecords)
            let maskRendered = try await ImageExporter.shared.render(
                ProjectSnapshot(manifest: maskManifest, images: maskImages, masks: maskAssets))
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: maskRendered.image),
                                                         "009 folder mask stack produced no bytes"),
                                            to: "009-stack.raw", in: out))

            // The folder's own mask on its own, dumped so the far side can check its placement before
            // judging what the clip did with it. Without this a wrong mask would look like a wrong clip.
            //
            // Dumped from the image's own data provider rather than drawn into a context: a Gray8 mask
            // read back through a color space would be color-managed, and the point is to hand over the
            // exact bytes the clipper was given.
            if let folderMask = maskAssets[maskIds["folder"]!],
               let gray = folderMask.image.dataProvider?.data {
                artifacts.append(try Self.write(gray as Data, to: "009-folder-mask.raw", in: out))
            }

            let described: [[String: Any]] = maskStack.map { layer in
                ["slug": layer.0, "variant": layer.1, "pixelWidth": layer.2, "pixelHeight": layer.3,
                 "x": Double(layer.4), "y": Double(layer.5), "opacity": layer.6,
                 "blend": layer.7.rawValue, "masked": layer.8, "rotation": Double(layer.9),
                 "isGroup": layer.10, "parent": layer.11 ?? "", "visible": layer.12]
            }
            artifacts.append(try Self.write(try JSONSerialization.data(
                withJSONObject: ["width": maskCanvasWidth, "height": maskCanvasHeight, "layers": described],
                options: [.prettyPrinted, .sortedKeys]), to: "009-masks.json", in: out))
        } catch {
            print("009 ERROR: the folder mask stack could not be rendered: \(error)")
        }

        // ---------------------------------------------------------------- 010 clipping stacks
        //
        // A layer can name another as its clipping source. That is not "this layer is masked by that
        // one" - the base and everything clipped to it are composited as a SINGLE unit and blended into
        // the canvas once, in the BASE's mode (LiveMaskRenderer.swift:76-92,126-134). Two consequences
        // fall out of that, and both are easy to get wrong in a port:
        //
        //   1. The children's own blend modes apply INSIDE the stack, against the base's color, not
        //      against the canvas.
        //   2. The base's opacity is applied to the base before the children are drawn, and the stack
        //      then composites at full opacity - applying the base's opacity again would square it.
        //
        // The base here carries `screen` at 0.8 opacity, which makes both visible at once: a port that
        // composited each layer separately would use each layer's own mode against the canvas, and one
        // that applied the base's opacity at the end as well would darken the whole stack twice.
        //
        //   base   (0,0) 40x32              background
        //   shape  (8,8) 20x16  screen 0.8  the stack's base; its ALPHA is the stack's clip
        //   paint  (4,4) 24x20  normal      clipped to shape, and larger than it
        //   tint   (4,4) 24x20  multiply    clipped to shape, multiplied against shape's color
        //   gap    (2,20) 14x14 normal      breaks the run, so the next layer is not in the stack
        //   late  (20,18) 18x12 normal      names shape but is NOT next to it
        //   above (22,2) 16x16  normal      untouched by any of this
        //
        // "late" is the case a port most easily drops entirely: it is clipped to shape's alpha even
        // though it is not part of shape's stack, because a clipping link is a clip whether or not the
        // layers happen to be adjacent.
        let clipCanvasWidth = 40
        let clipCanvasHeight = 32

        typealias ClippedLayer = (String, Int, Int, Int, CGFloat, CGFloat, Double, LayerBlendMode,
                                  Bool, CGFloat, Bool, String?, Bool, String?)
        let clipStack: [ClippedLayer] = [
            ("base",  0, clipCanvasWidth, clipCanvasHeight,  0,  0, 1.0, .normal,   false, 0, false, nil,     true,  nil),
            ("shape", 1, 20,              16,                8,  8, 0.8, .screen,   false, 0, false, nil,     true,  nil),
            ("paint", 2, 24,              20,                4,  4, 1.0, .normal,   false, 0, false, nil,     true,  "shape"),
            ("tint",  3, 24,              20,                4,  4, 1.0, .multiply, false, 0, false, nil,     true,  "shape"),
            ("gap",   1, 14,              14,                2, 20, 1.0, .normal,   false, 0, false, nil,     true,  nil),
            ("late",  2, 18,              12,               20, 18, 1.0, .normal,   false, 0, false, nil,     true,  "shape"),
            ("above", 1, 16,              16,               22,  2, 1.0, .normal,   false, 0, false, nil,     true,  nil),
        ]

        var clipIds: [String: UUID] = [:]
        var clipRecords: [ProjectLayerRecord] = []
        var clipImages: [UUID: ImportedImage] = [:]

        for (slug, variant, pixelWidth, pixelHeight, x, y, opacity, blend,
             masked, rotation, isGroup, parent, visible, source) in clipStack {
            let id = UUID()
            clipIds[slug] = id
            if !isGroup {
                guard let raster = Self.stackRaster(width: pixelWidth, height: pixelHeight, variant: variant),
                      let thumbnail = Self.stackRaster(width: max(1, pixelWidth / 2), height: max(1, pixelHeight / 2),
                                                       variant: variant) else {
                    print("010 ERROR: could not build the \(slug) raster")
                    continue
                }
                clipImages[id] = ImportedImage(image: raster, thumbnail: thumbnail, name: slug)
            }
            clipRecords.append(ProjectLayerRecord(
                id: id, name: slug, isVisible: visible,
                transform: LayerTransform(origin: CGPoint(x: x, y: y),
                                          size: CGSize(width: pixelWidth, height: pixelHeight),
                                          rotation: rotation),
                imageFile: isGroup ? nil : "\(slug).png",
                parentID: parent.flatMap { clipIds[$0] },
                isGroup: isGroup, opacity: opacity, blendMode: blend,
                maskFile: masked ? "\(slug)-mask.png" : nil,
                maskSourceID: source.flatMap { clipIds[$0] }))
        }

        do {
            let clipManifest = ProjectManifest(documentID: UUID(), width: clipCanvasWidth, height: clipCanvasHeight,
                                               activeLayerID: nil, layers: clipRecords)
            let clipRendered = try await ImageExporter.shared.render(
                ProjectSnapshot(manifest: clipManifest, images: clipImages, masks: [:]))
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: clipRendered.image),
                                                         "010 clipping stack produced no bytes"),
                                            to: "010-stack.raw", in: out))

            // The same stack with every clipping link cut, so the far side can measure how much the
            // stacking actually changed rather than trusting that it did.
            let looseRecords = clipRecords.map { record -> ProjectLayerRecord in
                var copy = record
                copy.maskSourceID = nil
                return copy
            }
            let looseManifest = ProjectManifest(documentID: UUID(), width: clipCanvasWidth, height: clipCanvasHeight,
                                                activeLayerID: nil, layers: looseRecords)
            let looseRendered = try await ImageExporter.shared.render(
                ProjectSnapshot(manifest: looseManifest, images: clipImages, masks: [:]))
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: looseRendered.image),
                                                         "010-stack-unclipped.raw"),
                                            to: "010-stack-unclipped.raw", in: out))

            let described: [[String: Any]] = clipStack.map { layer in
                ["slug": layer.0, "variant": layer.1, "pixelWidth": layer.2, "pixelHeight": layer.3,
                 "x": Double(layer.4), "y": Double(layer.5), "opacity": layer.6,
                 "blend": layer.7.rawValue, "masked": layer.8, "rotation": Double(layer.9),
                 "isGroup": layer.10, "parent": layer.11 ?? "", "visible": layer.12,
                 "source": layer.13 ?? ""]
            }
            artifacts.append(try Self.write(try JSONSerialization.data(
                withJSONObject: ["width": clipCanvasWidth, "height": clipCanvasHeight, "layers": described],
                options: [.prettyPrinted, .sortedKeys]), to: "010-clipping.json", in: out))
        } catch {
            print("010 ERROR: the clipping stack could not be rendered: \(error)")
        }

        // ---------------------------------------------------------------- 011 camera raw
        //
        // Camera Raw is a pipeline of six stages that read each other in a fixed order
        // (CameraRaw.swift:237-266): calibration, the basic grade, Curve and Color Mixer, Effects and
        // Grain, Detail and Optics - with Geometry before all of them, because it changes where the
        // pixels are rather than what they are.
        //
        // This dumps the basic grade, which is the stage everything else sits on. It is one kernel
        // taking twelve numbers, and the two ways to get it wrong are both worth catching separately:
        //
        //   1. the GAINS. Temperature and tint are not passed through - they become per-channel
        //      multipliers, and red and blue take the warm/cool swing in opposite directions while
        //      green takes the magenta swing at twice their weight. On a neutral image every gain is 1
        //      and a wrong sign is invisible, so the white-balance case below moves temperature and
        //      tint on their own, with the tone curve untouched.
        //   2. the TONE MAPPING. Exposure, contrast, highlights, shadows, whites and blacks interact;
        //      the second case moves all of them at once over a full luminance ramp.
        //
        // The input is opaque on purpose. A grade on premultiplied pixels and a grade on straight
        // pixels are the same operation only while alpha is 255, so an opaque input keeps this case
        // about the grade rather than about which convention each side used.
        let rawWidth = 32
        let rawHeight = 24

        if let rawInput = Self.rawRaster(width: rawWidth, height: rawHeight) {
            artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rawInput),
                                                         "011 input produced no bytes"),
                                            to: "011-input.raw", in: out))

            // White balance alone: the gains, with the tone curve left at neutral.
            var balance = CameraRawSettings()
            balance.temperature = 55
            balance.tint = -30
            balance.saturation = 25

            // The full grade: every one of the twelve numbers the kernel takes.
            var grade = CameraRawSettings()
            grade.temperature = 42
            grade.tint = -18
            grade.exposure = 0.65
            grade.contrast = 35
            grade.highlights = -40
            grade.shadows = 55
            grade.whites = 20
            grade.blacks = -15
            grade.vibrance = 30
            grade.saturation = -12

            do {
                let balanced = try balance.apply(rawInput)
                artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: balanced),
                                                             "011 white balance produced no bytes"),
                                                to: "011-white-balance.raw", in: out))
            } catch {
                print("011 ERROR: white balance failed: \(error)")
            }

            do {
                let graded = try grade.apply(rawInput)
                artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: graded),
                                                             "011 grade produced no bytes"),
                                                to: "011-graded.raw", in: out))
            } catch {
                print("011 ERROR: the grade failed: \(error)")
            }

            artifacts.append(try Self.write(try JSONSerialization.data(withJSONObject: [
                "width": rawWidth, "height": rawHeight,
                "whiteBalance": ["temperature": balance.temperature, "tint": balance.tint,
                                 "saturation": balance.saturation],
                "grade": ["temperature": grade.temperature, "tint": grade.tint,
                          "exposure": grade.exposure, "contrast": grade.contrast,
                          "highlights": grade.highlights, "shadows": grade.shadows,
                          "whites": grade.whites, "blacks": grade.blacks,
                          "vibrance": grade.vibrance, "saturation": grade.saturation],
                "gains": ["whiteBalance": [balance.gains.red, balance.gains.green, balance.gains.blue],
                          "grade": [grade.gains.red, grade.gains.green, grade.gains.blue]],
            ], options: [.prettyPrinted, .sortedKeys]), to: "011-camera-raw.json", in: out))
        } else {
            print("011 ERROR: could not build the input raster")
        }

        // ---------------------------------------------------------------- 012 camera raw, the other stages
        //
        // The basic grade is one stage of six, and the ones around it are where the order stops being
        // obvious. Calibration runs BEFORE the grade, because it reinterprets what the camera's
        // primaries mean; running it afterwards is a different picture, and on a gentle test image the
        // two are close enough to look like rounding.
        //
        // Effects runs after, and its five parts do not share a scale: the vignette is shaped to the
        // frame, glow and local contrast are shaped in pixels, and `scale` is preview pixels per layer
        // pixel, so the radii are divided by it. Grain is separate again and is the only stage that
        // takes a seed, which is why it is dumped on its own - a port that reseeded per call would give
        // a different pattern on every redraw instead of a still one.
        //
        // Each group is dumped alone before any of them are combined, so a mismatch names the stage.

        if let rawInput = Self.rawRaster(width: rawWidth, height: rawHeight) {
            // Calibration alone. Nothing else is non-default, so the grade kernel does not run at all.
            var calibrationV6 = CameraRawSettings()
            calibrationV6.calibration.process = .version6
            calibrationV6.calibration.shadowTint = 28
            calibrationV6.calibration.redHue = -22
            calibrationV6.calibration.redSaturation = 40
            calibrationV6.calibration.greenHue = 15
            calibrationV6.calibration.greenSaturation = -35
            calibrationV6.calibration.blueHue = 30
            calibrationV6.calibration.blueSaturation = 18

            // The same amounts at Version 1, which moves them about half as far. A port that ignored the
            // process version would make these two come out identical.
            var calibrationV1 = calibrationV6
            calibrationV1.calibration.process = .version1

            // Effects alone: all five parts at once.
            var effects = CameraRawSettings()
            effects.texture = 45
            effects.clarity = -30
            effects.dehaze = 25
            effects.glow = 60
            effects.glowStyle = .halation
            effects.glowRange = 40
            effects.glowSpread = 20
            effects.glowWarmth = 35
            effects.vignetteAmount = -55
            effects.vignetteStyle = .colorPriority
            effects.vignetteMidpoint = 40
            effects.vignetteRoundness = -25
            effects.vignetteFeather = 65
            effects.vignetteHighlights = 30

            // Grain alone, at a seed that is not zero so a port that dropped the seed would differ.
            var grain = CameraRawSettings()
            grain.grainAmount = 70
            grain.grainSize = 60
            grain.grainRoughness = 35

            // Everything on, in the order the pipeline runs: calibration, the grade, then effects.
            var combined = CameraRawSettings()
            combined.temperature = 42
            combined.tint = -18
            combined.exposure = 0.65
            combined.contrast = 35
            combined.highlights = -40
            combined.shadows = 55
            combined.whites = 20
            combined.blacks = -15
            combined.vibrance = 30
            combined.saturation = -12
            combined.calibration = calibrationV6.calibration
            combined.texture = effects.texture
            combined.clarity = effects.clarity
            combined.dehaze = effects.dehaze
            combined.glow = effects.glow
            combined.glowStyle = effects.glowStyle
            combined.glowRange = effects.glowRange
            combined.glowSpread = effects.glowSpread
            combined.glowWarmth = effects.glowWarmth
            combined.vignetteAmount = effects.vignetteAmount
            combined.vignetteStyle = effects.vignetteStyle
            combined.vignetteMidpoint = effects.vignetteMidpoint
            combined.vignetteRoundness = effects.vignetteRoundness
            combined.vignetteFeather = effects.vignetteFeather
            combined.vignetteHighlights = effects.vignetteHighlights
            combined.grainAmount = grain.grainAmount
            combined.grainSize = grain.grainSize
            combined.grainRoughness = grain.grainRoughness

            let renders: [(String, CameraRawSettings, CGFloat, UInt32)] = [
                ("012-calibration-v6.raw", calibrationV6, 1, 0),
                ("012-calibration-v1.raw", calibrationV1, 1, 0),
                ("012-effects.raw", effects, 1, 0),
                ("012-effects-scaled.raw", effects, 2, 0),
                ("012-grain.raw", grain, 1, 7),
                ("012-combined.raw", combined, 1, 7),
            ]
            for (name, settings, renderScale, renderSeed) in renders {
                do {
                    let rendered = try settings.apply(rawInput, scale: renderScale, seed: renderSeed)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rendered),
                                                                 "\(name) produced no bytes"),
                                                    to: name, in: out))
                } catch {
                    print("012 ERROR: \(name) failed: \(error)")
                }
            }
        }

        // ---------------------------------------------------------------- 013 camera raw Detail and Optics
        //
        // The last two stages, and the only ones that are spatially shaped rather than pointwise: they
        // read neighbouring pixels, which is why `scale` matters and why their radii are measured in
        // pixels of the layer rather than of the preview.
        //
        // Detail and Optics run in that order - Optics first - even though they are dumped as one group
        // here. Sharpening the lens distortion's output is not the same as distorting the sharpening's.
        //
        // Optics is also the stage with a computed input rather than a passed-through one: the radial
        // distortion the kernel takes is the manual amount and the profile amount ADDED, each scaled by
        // the lens strength, and the profile term only counts while the profile toggle is on - so a port
        // that ignored the toggle would still get the default profile amount of 100 into the sum.

        if let rawInput = Self.rawRaster(width: rawWidth, height: rawHeight) {
            // Detail alone: sharpening and both noise reductions.
            var detail = CameraRawSettings()
            detail.detail.sharpenAmount = 90
            detail.detail.sharpenRadius = 30
            detail.detail.sharpenDetail = 60
            detail.detail.sharpenMasking = 20
            detail.detail.noiseLuminance = 45
            detail.detail.noiseLuminanceDetail = 65
            detail.detail.noiseLuminanceContrast = 15
            detail.detail.noiseColor = 55
            detail.detail.noiseColorDetail = 35
            detail.detail.noiseColorSmoothness = 70

            // Optics alone, with the profile toggle ON so the profile terms reach the sum.
            var opticsOn = CameraRawSettings()
            opticsOn.optics.removeChromaticAberration = true
            opticsOn.optics.enableLensProfile = true
            opticsOn.optics.profileDistortion = 80
            opticsOn.optics.profileVignetting = 60
            opticsOn.optics.distortion = -40
            opticsOn.optics.purpleAmount = 50
            opticsOn.optics.purpleHueLow = 260
            opticsOn.optics.purpleHueHigh = 320
            opticsOn.optics.greenAmount = 35
            opticsOn.optics.greenHueLow = 70
            opticsOn.optics.greenHueHigh = 140
            opticsOn.optics.vignetteAmount = 45
            opticsOn.optics.vignetteMidpoint = 30

            // The same optics with the profile toggle OFF. The profile amounts are still at their
            // non-zero defaults, so a port that added them unconditionally would make these two match.
            var opticsOff = opticsOn
            opticsOff.optics.enableLensProfile = false

            // Optics and Detail together, in the order the pipeline runs them.
            var both = opticsOn
            both.detail = detail.detail

            let renders: [(String, CameraRawSettings, CGFloat, UInt32)] = [
                ("013-detail.raw", detail, 1, 0),
                ("013-detail-scaled.raw", detail, 2, 0),
                ("013-optics-profile.raw", opticsOn, 1, 0),
                ("013-optics-no-profile.raw", opticsOff, 1, 0),
                ("013-optics-scaled.raw", opticsOn, 2, 0),
                ("013-detail-optics.raw", both, 1, 0),
            ]
            for (name, settings, renderScale, renderSeed) in renders {
                do {
                    let rendered = try settings.apply(rawInput, scale: renderScale, seed: renderSeed)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rendered),
                                                                 "\(name) produced no bytes"),
                                                    to: name, in: out))
                } catch {
                    print("013 ERROR: \(name) failed: \(error)")
                }
            }

            // The mask preview, which replaces the last stage rather than following it and leaves the
            // basic grade in place.
            var masked = CameraRawSettings()
            masked.exposure = 0.4
            masked.detail = detail.detail
            do {
                let rendered = try masked.apply(rawInput, sharpenMask: true)
                artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rendered),
                                                             "013 mask produced no bytes"),
                                                to: "013-sharpen-mask.raw", in: out))
            } catch {
                print("013 ERROR: the sharpen mask failed: \(error)")
            }
        }

        // ---------------------------------------------------------------- 014 camera raw Curve and Color
        //
        // This group does not hand the kernel its amounts. It hands it LOOKUP TABLES: 256 floats for the
        // tone curve and 256 for each channel curve, all built here in Swift. So a difference anywhere in
        // the curve arithmetic shows up as a table a level or two off, spread across the whole image -
        // which is exactly the kind of mismatch that is hard to attribute from pixels alone.
        //
        // The parametric curve is the part worth isolating. Its two bends nest: the inner one uses the
        // shadow and light dividers with the Shadow and Highlight amounts, the outer uses the dark
        // divider for BOTH of its sides with the Darks and Lights amounts. Reading the arguments off one
        // call and reusing them for the other gives a curve that still rises, still looks like a tone
        // curve, and is wrong.
        //
        // The point curves are evaluated through the same spline as the Curves filter, so they are not
        // dumped separately here - what is new is the composition order, parametric first and then the
        // composite point curve over it.
        //
        // Color Grading and the Color Mixer share the kernel, so all three run together in the combined
        // case at the end, after a grade, in the order the pipeline runs them.

        if let rawInput = Self.rawRaster(width: rawWidth, height: rawHeight) {
            // The parametric curve alone, with dividers that do not sit on their defaults.
            var parametric = CameraRawSettings()
            parametric.curve.shadows = 40
            parametric.curve.darks = -55
            parametric.curve.lights = 35
            parametric.curve.highlights = -25
            parametric.curve.shadowSplit = 18
            parametric.curve.darkSplit = 44
            parametric.curve.lightSplit = 82

            // The point curves alone, with a composite curve that also moves saturation.
            var pointCurve = CameraRawSettings()
            pointCurve.curve.rgb = [CurvePoint(x: 0, y: 0.04), CurvePoint(x: 0.3, y: 0.2),
                                    CurvePoint(x: 0.7, y: 0.86), CurvePoint(x: 1, y: 0.98)]
            pointCurve.curve.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)]
            pointCurve.curve.green = [CurvePoint(x: 0, y: 0.02), CurvePoint(x: 0.5, y: 0.4), CurvePoint(x: 1, y: 1)]
            pointCurve.curve.blue = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.1),
                                     CurvePoint(x: 0.75, y: 0.9), CurvePoint(x: 1, y: 1)]
            pointCurve.curve.refineSaturation = -45

            // The Color Mixer: all eight families, plus two picked colors.
            var mixer = CameraRawSettings()
            mixer.mixer.hue = [12, -8, 20, -30, 15, -18, 25, -10]
            mixer.mixer.saturation = [-20, 30, -40, 25, -15, 35, -25, 18]
            mixer.mixer.luminance = [15, -25, 10, -35, 20, -12, 30, -22]
            mixer.mixer.points = [
                CameraRawPointColor(hue: 25, saturation: 0.7, luminance: 0.5,
                                    hueShift: 30, saturationShift: -40, luminanceShift: 20,
                                    hueRange: 45, saturationRange: 0.6, luminanceRange: 0.3),
                CameraRawPointColor(hue: 210, saturation: 0.4, luminance: 0.6,
                                    hueShift: -25, saturationShift: 35, luminanceShift: -15,
                                    hueRange: 60, saturationRange: 0.5, luminanceRange: 0.7),
            ]

            // Color Grading: all four wheels, with blending and balance off their defaults.
            var grading = CameraRawSettings()
            grading.grading.shadows = CameraRawGradeWheel(hue: 220, saturation: 40, luminance: -15)
            grading.grading.midtones = CameraRawGradeWheel(hue: 40, saturation: 25, luminance: 10)
            grading.grading.highlights = CameraRawGradeWheel(hue: 55, saturation: 30, luminance: 20)
            grading.grading.global = CameraRawGradeWheel(hue: 300, saturation: 15, luminance: -5)
            grading.grading.blending = 65
            grading.grading.balance = -30

            // All three at once, after a grade, in the order the pipeline runs them.
            var curveColor = CameraRawSettings()
            curveColor.temperature = 30
            curveColor.exposure = 0.35
            curveColor.contrast = 20
            curveColor.shadows = 30
            curveColor.curve = parametric.curve
            curveColor.mixer = mixer.mixer
            curveColor.grading = grading.grading

            let renders: [(String, CameraRawSettings, CGFloat, UInt32)] = [
                ("014-curve-parametric.raw", parametric, 1, 0),
                ("014-curve-point.raw", pointCurve, 1, 0),
                ("014-mixer.raw", mixer, 1, 0),
                ("014-grading.raw", grading, 1, 0),
                ("014-curve-color.raw", curveColor, 1, 0),
            ]
            for (name, settings, renderScale, renderSeed) in renders {
                do {
                    let rendered = try settings.apply(rawInput, scale: renderScale, seed: renderSeed)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rendered),
                                                                 "\(name) produced no bytes"),
                                                    to: name, in: out))
                } catch {
                    print("014 ERROR: \(name) failed: \(error)")
                }
            }

            // The option-drag clipping overlay, which is a preview of the grade rather than a grade: it
            // is drawn BY the basic grade, so the amounts have to be non-neutral to have anything to
            // clip. It is dumped for both directions.
            var clippingSource = CameraRawSettings()
            clippingSource.exposure = 1.4
            clippingSource.highlights = 70
            clippingSource.whites = 60
            clippingSource.shadows = -50
            clippingSource.blacks = -45
            for (name, mode) in [("014-clip-highlights.raw", CameraRawClipping.highlights),
                                 ("014-clip-shadows.raw", CameraRawClipping.shadows)] {
                do {
                    let rendered = try clippingSource.apply(rawInput, clipping: mode)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: rendered),
                                                                 "\(name) produced no bytes"),
                                                    to: name, in: out))
                } catch {
                    print("014 ERROR: \(name) failed: \(error)")
                }
            }
            // The scope overlay. It is a different thing from the option-drag overlay above: that one is
            // drawn by the grade through its `clipping` argument, while this one paints over an already
            // graded image, which is what the histogram scope shows.
            var scopeSource = CameraRawSettings()
            scopeSource.exposure = 1.2
            scopeSource.contrast = 40
            scopeSource.shadows = -40
            scopeSource.blacks = -35
            do {
                let graded = try scopeSource.apply(rawInput)
                for (name, shadows, highlights) in [("014-scope-shadows.raw", true, false),
                                                    ("014-scope-highlights.raw", false, true),
                                                    ("014-scope-both.raw", true, true)] {
                    let marked = try CameraRawScope.overlay(graded, shadows: shadows, highlights: highlights)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: marked),
                                                                 "\(name) produced no bytes"),
                                                    to: name, in: out))
                }
            } catch {
                print("014 ERROR: the scope overlay failed: \(error)")
            }
        }

        // ---------------------------------------------------------------- 015 the standalone Vignette
        //
        // A different filter from the vignette inside Camera Raw, and it does not share its defaults. The
        // load-bearing difference is Roundness: 100 here against 0 there. A port that carried one set of
        // defaults across to the other would be wrong on every document that never touched the slider,
        // which is most of them.
        //
        // It is also the one filter that can run on an EMPTY layer: with no pixels to begin with it
        // frames the canvas and fills it, which is what `fillsClear` asks the kernel for. Both are
        // dumped, because a port that passed it unconditionally would paint over transparent pixels on
        // an ordinary layer.
        //
        // The frame is the vignette's shape rather than the raster's size, so a CANVAS smaller than the
        // layer is dumped too - that is the case a port that ignored the frame would still pass on the
        // full-frame renders. And it is the canvas that turns fillsClear on, so that render also covers
        // the transparent-pixel path.

        if let raster = Self.rawRaster(width: rawWidth, height: rawHeight) {
            var vig = FilterSettings()
            vig.vignetteAmount = 70
            vig.vignetteColor = AdjustmentColor(red: 0.15, green: 0.05, blue: 0.35)
            vig.vignetteMidpoint = 40
            vig.vignetteRoundness = -30
            vig.vignetteFeather = 35
            vig.vignetteHighlights = 60

            // Through PixelFilter.run rather than the kernel, so the case covers the frame derivation and
            // the fillsClear decision as well as the falloff itself.
            func run(_ source: CGImage, _ settings: FilterSettings, canvas: CGRect?) throws -> CGImage {
                try PixelFilter.run(FilterJob(kind: .vignette, image: source, settings: settings,
                                              scale: 1, selection: nil, mapping: .identity, canvas: canvas))
            }

            do {
                // An ordinary layer: no canvas, so the vignette frames the layer's own pixels and only
                // recolors the ones that are there.
                let full = try run(raster, vig, canvas: nil)
                artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: full),
                                                             "015 vignette produced no bytes"),
                                                to: "015-vignette.raw", in: out))

                // A canvas smaller than the layer, inset and centered by the mapping: a different frame
                // AND fillsClear on, so transparent pixels get painted where the frame reaches them.
                if let clearRaster = Self.vignetteClearRaster(width: rawWidth, height: rawHeight) {
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: clearRaster),
                                                                 "015 clear input produced no bytes"),
                                                    to: "015-clear-input.raw", in: out))
                    let insetCanvas = CGRect(x: CGFloat(rawWidth) * 0.25, y: CGFloat(rawHeight) * 0.2,
                                             width: CGFloat(rawWidth) * 0.5, height: CGFloat(rawHeight) * 0.5)
                    let cleared = try run(clearRaster, vig, canvas: insetCanvas)
                    artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: cleared),
                                                                 "015 canvas vignette produced no bytes"),
                                                    to: "015-vignette-canvas.raw", in: out))
                }

                // The same frame but the OTHER direction: roundness positive, highlights off, a light
                // edge color. Roundness defaults to 100 here against 0 in Camera Raw, so both signs of it
                // are worth pinning down rather than just the default.
                var light = vig
                light.vignetteAmount = 55
                light.vignetteColor = AdjustmentColor(red: 0.95, green: 0.9, blue: 0.7)
                light.vignetteRoundness = 100
                light.vignetteHighlights = 0
                light.vignetteMidpoint = 65
                light.vignetteFeather = 80
                let bright = try run(raster, light, canvas: nil)
                artifacts.append(try Self.write(try #require(Self.rgbaBytes(of: bright),
                                                             "015 bright vignette produced no bytes"),
                                                to: "015-vignette-bright.raw", in: out))
            } catch {
                print("015 ERROR: the vignette failed: \(error)")
            }

            artifacts.append(try Self.write(try JSONSerialization.data(withJSONObject: [
                "width": rawWidth, "height": rawHeight,
                "amount": vig.vignetteAmount, "midpoint": vig.vignetteMidpoint,
                "roundness": vig.vignetteRoundness, "feather": vig.vignetteFeather,
                "highlights": vig.vignetteHighlights,
                "color": [vig.vignetteColor.red, vig.vignetteColor.green, vig.vignetteColor.blue],
            ], options: [.prettyPrinted, .sortedKeys]), to: "015-vignette.json", in: out))
        }

        // ---------------------------------------------------------------- package listing
        // A sorted path / size / SHA-256 index, so the C# harness never has to enumerate a
        // filesystem to know what a golden contains. Paths are relative to the corpus root
        // ("001-minimal.comp/manifest.json").
        //
        // This block has to come after every package is written, so it sits at the end rather than
        // next to 002. Moving it back up makes the compiler reject the references below.
        var listing: [[String: Any]] = []
        for (name, package) in [("001-minimal.comp", comp),
                                ("003-adjustments.comp", adjustComp),
                                ("004-hsv.comp", hsvComp)] {
            guard let walker = FileManager.default.enumerator(
                at: package, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let rel = name + "/" + url.path.replacingOccurrences(of: package.path + "/", with: "")
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let data = try Data(contentsOf: url)
                listing.append([
                    "path": rel,
                    "bytes": values.fileSize ?? 0,
                    "sha256": SHA256Hex.of(data),
                ])
            }
        }
        listing.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }

        let packages = ["001-minimal.comp", "003-adjustments.comp", "004-hsv.comp"]
        let treeJSON = try JSONSerialization.data(
            withJSONObject: ["root": "001-minimal.comp", "packages": packages, "files": listing],
            options: [.prettyPrinted, .sortedKeys])
        artifacts.append(try Self.write(treeJSON, to: "tree.json", in: out))

        // ---------------------------------------------------------------- metadata
        // Recorded because several of these are machine-dependent and must be known when
        // judging a diff (see plan section 10.9: documentPixelBudget follows physical memory).
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let metadata: [String: Any] = [
            "generatedBy": "GoldenDump (CompositorTests)",
            "manifestVersion": ProjectManifest.current,
            "supportedVersions": [ProjectManifest.supported.lowerBound,
                                  ProjectManifest.supported.upperBound],
            "macOSVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            // Confirmed present at ProjectStore.swift:71 (interpolated into the .tooLarge message).
            "documentBudgetMegapixels": DocumentLimits.documentBudgetMegapixels,
            "artifacts": artifacts,
        ]
        let metaJSON = try JSONSerialization.data(withJSONObject: metadata,
                                                  options: [.prettyPrinted, .sortedKeys])
        artifacts.append(try Self.write(metaJSON, to: "metadata.json", in: out))

        print("=== GOLDEN DUMP COMPLETE: \(artifacts.count) entries in \(out.path) ===")
    }
    // ------------------------------------------------------------------ 005 helpers

    /// The input raster for the pixel comparison, built from a closed form rather than chosen.
    ///
    /// It has to be reproducible on the far side from the same arithmetic, so this uses integer
    /// operations only: no floating point, no library rounding, no color management. Every channel
    /// depends on both x and y, so neither a transposed nor a vertically flipped buffer can match by
    /// accident - which is the point, since row order is exactly the kind of thing that differs
    /// between two graphics stacks and is otherwise invisible.
    static func rawBytes(side: Int, varyingAlpha: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                var r = (x * 16 + y * 3) % 256
                var g = (x * 7 + y * 29) % 256
                var b = (x * 31 + y * 11) % 256
                let a = varyingAlpha ? ((x * 5 + y * 13) % 256) : 255
                if varyingAlpha {
                    // The raster is premultiplied, so a color above its alpha is not a color at all.
                    // Clamping rather than dividing would hide a premultiplication bug.
                    r = r * a / 255
                    g = g * a / 255
                    b = b * a / 255
                }
                bytes[i] = UInt8(r)
                bytes[i + 1] = UInt8(g)
                bytes[i + 2] = UInt8(b)
                bytes[i + 3] = UInt8(a)
            }
        }
        return Data(bytes)
    }

    static func makeInput(side: Int, varyingAlpha: Bool) -> CGImage? {
        let data = rawBytes(side: side, varyingAlpha: varyingAlpha)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The two rasters case 006 blends, built from a closed form for the same reason case 005's input is:
    /// the C# side has to rebuild them from the same integer arithmetic, so a disagreement is about the
    /// blend and not about the pixels that went into it.
    ///
    /// The two variants never share a channel's slope, so no channel of one can be mistaken for a channel
    /// of the other, and every channel depends on both axes.
    static func makeBlendRaster(side: Int, variant: Int, varyingAlpha: Bool) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                var r: Int, g: Int, b: Int
                if variant == 0 {
                    r = (x * 11 + y * 7) % 256
                    g = (x * 5 + y * 23) % 256
                    b = (x * 19 + y * 13) % 256
                } else {
                    r = (x * 29 + y * 17) % 256
                    g = (x * 3 + y * 31) % 256
                    b = (x * 13 + y * 37) % 256
                }
                let a = varyingAlpha ? ((x * 9 + y * 21) % 256) : 255
                if varyingAlpha {
                    r = r * a / 255
                    g = g * a / 255
                    b = b * a / 255
                }
                bytes[i] = UInt8(r)
                bytes[i + 1] = UInt8(g)
                bytes[i + 2] = UInt8(b)
                bytes[i + 3] = UInt8(a)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A file-name-safe form of a blend mode's name. "Linear Dodge (Add)" becomes "linear-dodge-add", so
    /// the artifacts sort and read plainly and the C# side can match them against a list rather than
    /// having to reproduce the punctuation.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.append(ch)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// A layer's pixels for case 007, from a closed form for the same reason as everywhere else: the C#
    /// side rebuilds it from identical integer arithmetic, so a disagreement is about the stack and not
    /// about the input.
    ///
    /// Four variants with no slope shared between them, so no variant can be mistaken for another and
    /// every channel depends on both axes - a transposed or mirrored raster cannot match by accident.
    static func stackRaster(width: Int, height: Int, variant: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r: Int, g: Int, b: Int
                switch variant {
                case 0: r = (x * 13 + y * 5) % 256; g = (x * 7 + y * 19) % 256; b = (x * 23 + y * 11) % 256
                case 1: r = (x * 29 + y * 17) % 256; g = (x * 3 + y * 31) % 256; b = (x * 13 + y * 37) % 256
                case 2: r = (x * 11 + y * 41) % 256; g = (x * 43 + y * 9) % 256; b = (x * 17 + y * 27) % 256
                default: r = (x * 37 + y * 29) % 256; g = (x * 19 + y * 23) % 256; b = (x * 5 + y * 47) % 256
                }
                bytes[i] = UInt8(r)
                bytes[i + 1] = UInt8(g)
                bytes[i + 2] = UInt8(b)
                bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A layer's mask for case 007, as the app stores one: single-channel Gray8 at the layer's pixel size.
    ///
    /// Returned as raw bytes alongside the image because the mask is compared as coverage, not as color,
    /// and reading a gray image back through a color context would convert it.
    /// A raster with genuinely transparent pixels, for the vignette's fillsClear path: alpha ramps in
    /// from nothing across the left third, and the color is stored premultiplied so the invariant
    /// c <= a holds everywhere.
    static func vignetteClearRaster(width: Int, height: Int) -> CGImage? {
        guard width > 1, height > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rampEnd = max(1, width / 3)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = x >= rampEnd ? 255.0 : 255.0 * Double(x) / Double(rampEnd)
                let base = 40.0 + (Double(x) / Double(width - 1)) * 180.0
                let other = 30.0 + (Double(y) / Double(height - 1)) * 200.0
                let scale = alpha / 255.0
                let o = (y * width + x) * 4
                bytes[o] = UInt8(max(0, min(255, (base * scale).rounded())))
                bytes[o + 1] = UInt8(max(0, min(255, (other * scale).rounded())))
                bytes[o + 2] = UInt8(max(0, min(255, (((base + other) / 2) * scale).rounded())))
                bytes[o + 3] = UInt8(max(0, min(255, alpha.rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The opaque raster the Camera Raw case grades: a luminance ramp with a color cast that varies
    /// across it, so the gains and the tone mapping both have something to bite on.
    static func rawRaster(width: Int, height: Int) -> CGImage? {
        guard width > 1, height > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let down = Double(y) * 255 / Double(height - 1)
            for x in 0..<width {
                let across = Double(x) * 255 / Double(width - 1)
                let luma = (across + down) / 2
                let r = luma
                let g = luma * 3 / 4 + across / 4
                let b = luma / 2 + down / 2
                let o = (y * width + x) * 4
                bytes[o] = UInt8(max(0, min(255, r.rounded())))
                bytes[o + 1] = UInt8(max(0, min(255, g.rounded())))
                bytes[o + 2] = UInt8(max(0, min(255, b.rounded())))
                bytes[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    static func stackMask(width: Int, height: Int) -> (image: CGImage, bytes: Data)? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // A soft-edged blob rather than the full range: a mask that is 0 or 255 almost everywhere
                // would pass even if the coverage multiply were wrong by a whole step.
                let dx = Double(x) - Double(width) / 2.0 + 0.5
                let dy = Double(y) - Double(height) / 2.0 + 0.5
                let distance = (dx * dx + dy * dy).squareRoot()
                let radius = Double(min(width, height)) / 2.0
                let coverage = max(0.0, min(1.0, 1.0 - distance / radius))
                bytes[y * width + x] = UInt8((coverage * 255.0).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return (image, Data(bytes))
    }

    /// Reads an image back as premultiplied RGBA8, in the layout the port uses.
    ///
    /// This is the one step that could quietly move every pixel: it goes through a CGContext, and if
    /// that round trip is not the identity then the comparison measures the harness instead of the
    /// renderer. Case 005 dumps the round trip alongside the input so the C# side can check it.
    static func rgbaBytes(of image: CGImage) -> Data? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Data(bytes) : nil
    }

    /// The adjustments whose arithmetic the port reproduces, using the literals from case 003 so a
    /// setting cannot drift between the manifest artifact and the pixel artifact.
    static func pixelCases() -> [(String, LayerAdjustment)] {
        var cases: [(String, LayerAdjustment)] = []

        var hsv = LayerAdjustment(kind: .hsv)
        hsv.hue = 30; hsv.saturation = 40; hsv.lightness = -20; hsv.colorize = true
        cases.append(("hsv", hsv))

        var levels = LayerAdjustment(kind: .levels)
        levels.levels.ranges = [
            LevelRange(black: 10, gamma: 1.5, white: 240, outputBlack: 5, outputWhite: 250),
            LevelRange(black: 0, gamma: 1, white: 255, outputBlack: 0, outputWhite: 255),
            LevelRange(black: 20, gamma: 0.8, white: 200, outputBlack: 10, outputWhite: 220),
            LevelRange(black: 5, gamma: 2, white: 250, outputBlack: 0, outputWhite: 255),
        ]
        cases.append(("levels", levels))

        var curves = LayerAdjustment(kind: .curves)
        curves.curves.channels[1] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 200),
                                     CurvePoint(x: 255, y: 255)]
        curves.curves.channels[3] = [CurvePoint(x: 0, y: 10), CurvePoint(x: 64, y: 30),
                                     CurvePoint(x: 192, y: 240), CurvePoint(x: 255, y: 250)]
        cases.append(("curves", curves))

        var exposure = LayerAdjustment(kind: .exposure)
        exposure.exposure = ExposureSettings(exposure: 1.5, offset: -0.25, gamma: 2.2)
        cases.append(("exposure", exposure))

        var gradient = LayerAdjustment(kind: .gradientMap)
        gradient.gradientMap = GradientMapSettings(
            shadows: AdjustmentColor(red: 0.1, green: 0.2, blue: 0.3),
            highlights: AdjustmentColor(red: 0.9, green: 0.8, blue: 0.7),
            reversed: true)
        cases.append(("gradientMap", gradient))

        var grain = LayerAdjustment(kind: .grain)
        grain.grain = GrainSettings(amount: 30, size: 2.5, roughness: 60, seed: 123456)
        cases.append(("grain", grain))

        var noise = LayerAdjustment(kind: .addNoise)
        noise.resolvedNoiseAmount = 15
        noise.resolvedNoiseGaussian = true
        noise.resolvedNoiseMonochromatic = true
        noise.resolvedNoiseSeed = 654321
        cases.append(("addNoise", noise))

        // Invert carries no settings, so it is the control: the simplest case that must still match.
        cases.append(("invert", LayerAdjustment(kind: .invert)))

        var blackWhite = LayerAdjustment(kind: .blackWhite)
        blackWhite.blackWhite = BlackWhiteSettings(reds: 45, yellows: 65, greens: 35, cyans: 55,
                                                   blues: 25, magentas: 85, tint: true, tintHue: 200,
                                                   tintSaturation: 15)
        cases.append(("blackWhite", blackWhite))

        var colorBalance = LayerAdjustment(kind: .colorBalance)
        colorBalance.colorBalance = ColorBalanceSettings(
            shadowCyanRed: 10, shadowMagentaGreen: -20, shadowYellowBlue: 30,
            midCyanRed: -5, midMagentaGreen: 15, midYellowBlue: -25,
            highlightCyanRed: 20, highlightMagentaGreen: 5, highlightYellowBlue: -10,
            preserveLuminosity: false)
        cases.append(("colorBalance", colorBalance))

        return cases
    }
}

/// CryptoKit's SHA-256, so the index records a real content hash rather than a size alone.
private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

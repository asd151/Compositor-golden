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
                    let context = try BrushRaster.context(width: blendSide, height: blendSide, mask: false)
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

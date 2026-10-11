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
}

/// CryptoKit's SHA-256, so the index records a real content hash rather than a size alone.
private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

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
        // Where the corpus lands: GOLDEN_DUMP_DIR when set, otherwise golden-out/ at the repo
        // root. Deriving the default from #filePath avoids having to plumb an environment
        // variable through xcodebuild into the hosted test bundle, which is not dependable.
        // This suite is only ever run by the "Golden corpus" workflow, via
        // -only-testing:CompositorTests/GoldenDump, so writing by default cannot pollute an
        // ordinary test run.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompositorTests/
            .deletingLastPathComponent()   // repository root
        let out = ProcessInfo.processInfo.environment["GOLDEN_DUMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repoRoot.appendingPathComponent("golden-out", isDirectory: true)

        // Start clean so a stale artifact can never be mistaken for a fresh one.
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("=== GOLDEN DUMP writing to \(out.path) ===")

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

        // ---------------------------------------------------------------- package listing
        // A sorted name/size/SHA256 index, so the C# harness never has to enumerate a
        // filesystem to know what a golden contains.
        var listing: [[String: Any]] = []
        if let walker = FileManager.default.enumerator(at: comp, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                let rel = url.path.replacingOccurrences(of: comp.path + "/", with: "")
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

        let treeJSON = try JSONSerialization.data(
            withJSONObject: ["root": "001-minimal.comp", "files": listing],
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

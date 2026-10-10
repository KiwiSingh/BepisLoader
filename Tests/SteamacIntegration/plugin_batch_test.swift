import Foundation
@main struct PluginBatchTests {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("plugin-batch-" + UUID().uuidString)
        let fm = FileManager.default; try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let one = root.appendingPathComponent("One.dll"), two = root.appendingPathComponent("Two.dll")
        try Data([1,2,3]).write(to: one); try Data([4,5]).write(to: two)
        let batch = try BepInExPluginBatch.inspect([one,two]); precondition(batch.count == 2 && batch[1].data == Data([4,5]))
        try Data([9]).write(to: one); precondition(batch[0].data == Data([1,2,3]))
        func reject(_ files: [URL]) { do { _ = try BepInExPluginBatch.inspect(files); fatalError("Accepted invalid batch") } catch {} }
        reject([]); reject([one,one]); reject(Array(repeating: one, count: 129))
        let wrong = root.appendingPathComponent("not.txt"); try Data([1]).write(to: wrong); reject([one,wrong])
        try Data().write(to: two); reject([one,two])
        let symlink = root.appendingPathComponent("Link.dll"); try fm.createSymbolicLink(at: symlink, withDestinationURL: one); reject([symlink])
        let folder = root.appendingPathComponent("Folder.dll"); try fm.createDirectory(at: folder, withIntermediateDirectories: false); reject([folder])
        print("PASS: multi-plugin snapshots, immutable bytes, whole-batch preflight, duplicate names, count bounds, invalid type, empty DLL, symlink and directory rejection")
    }
}

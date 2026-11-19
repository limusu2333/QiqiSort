#!/usr/bin/env swift
import Foundation
import CryptoKit

// Development-only acquisition. The shipped application never invokes this script.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
func command(_ tool: String, _ args: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "Resources", code: 1, userInfo: [NSLocalizedDescriptionKey: "命令失败：\(tool)"] ) }
}
func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
struct Listing: Decodable { let Data: Items }
struct Items: Decodable { let Files: [Item] }
struct Item: Decodable { let Path: String; let Sha256: String; let Size: Int64; let `Type`: String }
let model = root.appendingPathComponent("resources/models/Qwen3-VL-4B-Instruct-4bit")
try fm.createDirectory(at: model, withIntermediateDirectories: true)
let revision = "a0d14395b0ef9f23cb8c0abae8bba65e84601339"
let listing = model.appendingPathComponent("source-manifest.json")
if !fm.fileExists(atPath: listing.path) {
    try command("/usr/bin/curl", ["-fL", "--retry", "2", "--max-time", "60", "-o", listing.path,
        "https://modelscope.cn/api/v1/models/mlx-community/Qwen3-VL-4B-Instruct-4bit/repo/files?Revision=\(revision)&Recursive=true"])
}
let entries = try JSONDecoder().decode(Listing.self, from: Data(contentsOf: listing)).Data.Files
for item in entries where item.Type == "blob" && !item.Path.hasPrefix(".") {
    guard !item.Path.contains("/"), !item.Path.contains("..") else { fatalError("非法资源路径") }
    let file = model.appendingPathComponent(item.Path)
    if fm.fileExists(atPath: file.path), try digest(file) == item.Sha256 { continue }
    print("获取模型资源：\(item.Path) (\(item.Size) bytes)")
    let part = file.appendingPathExtension("partial")
    try command("/usr/bin/curl", ["-fL", "--retry", "2", "--connect-timeout", "20", "--max-time", "1800", "-C", "-", "-o", part.path,
        "https://modelscope.cn/models/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/\(revision)/\(item.Path)"])
    guard try digest(part) == item.Sha256 else { fatalError("模型校验失败：\(item.Path)") }
    guard !fm.fileExists(atPath: file.path) else { fatalError("已有不同内容，请先检查：\(file.path)") }
    try fm.moveItem(at: part, to: file)
}
print("模型资源全部下载并通过 SHA-256 校验。")

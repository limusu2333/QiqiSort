#!/usr/bin/env swift
import Foundation
import CryptoKit

struct ModelListing: Decodable { let Data: ModelItems }
struct ModelItems: Decodable { let Files: [ModelFile] }
struct ModelFile: Decodable { let Path: String; let Sha256: String; let Size: Int64; let `Type`: String }
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let model = resources.appendingPathComponent("models/Qwen3-VL-4B-Instruct-4bit")
let listing = try JSONDecoder().decode(ModelListing.self, from: Data(contentsOf: model.appendingPathComponent("source-manifest.json")))
for item in listing.Data.Files where item.Type == "blob" && !item.Path.hasPrefix(".") {
    guard !item.Path.contains("/"), !item.Path.contains("..") else { fatalError("模型清单路径非法") }
    let file = try FileHandle(forReadingFrom: model.appendingPathComponent(item.Path))
    var hash = SHA256(), size: Int64 = 0
    while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
        hash.update(data: data); size += Int64(data.count)
    }
    try file.close()
    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard size == item.Size, actual == item.Sha256 else { fatalError("模型资源损坏：\(item.Path)") }
}
for name in ["category", "classify", "groups", "group", "face", "series", "rank", "memory", "memory-numbered"] {
    let rule = try String(contentsOf: resources.appendingPathComponent("rules/\(name).txt"), encoding: .utf8)
    guard !rule.isEmpty else { fatalError("规则为空：\(name)") }
}
struct RuntimeLibrary: Decodable { let version: String; let coreCommit: String; let size: Int64; let sha256: String }
let runtime = resources.appendingPathComponent("runtime")
let library = try JSONDecoder().decode(RuntimeLibrary.self,
    from: Data(contentsOf: runtime.appendingPathComponent("source-manifest.json")))
guard library.version == "0.29.1", library.coreCommit == "ee18e1cbf0ab7937578d716cc1b62b3fb1725e27" else {
    fatalError("图形计算库版本不匹配")
}
let libraryData = try Data(contentsOf: runtime.appendingPathComponent("mlx.metallib"), options: .mappedIfSafe)
let libraryHash = SHA256.hash(data: libraryData).map { String(format: "%02x", $0) }.joined()
guard libraryData.count == library.size, libraryHash == library.sha256 else { fatalError("图形计算库损坏") }
guard FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("licenses/mlx-metal/LICENSE").path) else {
    fatalError("缺少图形计算库许可证")
}
struct VisualManifest: Decodable {
    struct File: Decodable { let path: String; let size: Int; let sha256: String }
    let version: Int; let encoder: String; let model: String; let files: [File]
}
let visual = resources.appendingPathComponent("models/visual-memory").resolvingSymlinksInPath()
let visualManifest = try JSONDecoder().decode(VisualManifest.self,
    from: Data(contentsOf: visual.appendingPathComponent("mobileclip2-manifest.json")))
guard visualManifest.version == 1, visualManifest.encoder == "mobileclip2-s2-72424e70-center256-v1",
      visualManifest.model == "MobileCLIP2.mlmodelc", !visualManifest.files.isEmpty else {
    fatalError("视觉经验模型版本不匹配")
}
for item in visualManifest.files {
    let target = visual.appendingPathComponent(item.path).resolvingSymlinksInPath()
    guard item.path.hasPrefix(visualManifest.model + "/"), !item.path.split(separator: "/").contains(".."),
          target.path.hasPrefix(visual.path + "/") else { fatalError("视觉经验模型路径非法") }
    let bytes = try Data(contentsOf: target, options: .mappedIfSafe)
    guard bytes.count == item.size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.sha256 else {
        fatalError("视觉经验模型损坏：\(item.path)")
    }
}
for name in ["LICENSE", "LICENSE_MODELS", "ACKNOWLEDGEMENTS"] {
    guard FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("licenses/mobileclip2/\(name)").path) else {
        fatalError("缺少视觉经验模型来源文件：\(name)")
    }
}
print("项目内主模型、视觉经验模型、规则及图形计算库校验通过")
let seed = try Data(contentsOf: visual.appendingPathComponent("learning-seed.json"))
guard SHA256.hash(data: seed).map({ String(format: "%02x", $0) }).joined()
    == "0a3898fc5d0d833e6287d0c10c07f51c33f1a2addfa81b85a9040035e5b480aa" else {
    fatalError("分类学习初始样例损坏")
}

let identity = resources.appendingPathComponent("models/face-identity")
struct FaceIdentityManifest: Decodable {
    struct File: Decodable { let path: String; let size: Int; let sha256: String }
    let encoder: String
    let files: [File]
}
let identityManifest = try JSONDecoder().decode(FaceIdentityManifest.self, from: Data(contentsOf: identity.appendingPathComponent("manifest.json")))
guard identityManifest.encoder == "opencv-sface-2021dec-rgb112-v1", !identityManifest.files.isEmpty else { fatalError("人物身份模型清单无效") }
for item in identityManifest.files {
    guard item.path.hasPrefix("SFace.mlmodelc/"), !item.path.split(separator: "/").contains("..") else { fatalError("人物身份资源路径无效") }
    let bytes = try Data(contentsOf: identity.appendingPathComponent(item.path))
    guard bytes.count == item.size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.sha256 else { fatalError("人物身份模型损坏") }
}
guard FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("licenses/sface/LICENSE").path) else { fatalError("缺少人物身份模型许可证") }

struct FusionSeedManifest: Decodable { let method: String; let inputDimension: Int; let seedSHA256: String }
let fusionRoot = resources.appendingPathComponent("models/fusion-network")
let fusionManifest = try JSONDecoder().decode(FusionSeedManifest.self, from: Data(contentsOf: fusionRoot.appendingPathComponent("manifest.json")))
let fusionBytes = try Data(contentsOf: fusionRoot.appendingPathComponent("seed.json"))
guard fusionManifest.inputDimension == 1054,
      SHA256.hash(data: fusionBytes).map({ String(format: "%02x", $0) }).joined() == fusionManifest.seedSHA256 else { fatalError("融合网络初始特征损坏") }

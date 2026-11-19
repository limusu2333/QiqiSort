import Foundation
import CoreML
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let compiled = try MLModel.compileModel(at: source)
try FileManager.default.copyItem(at: compiled, to: destination)
let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
let model = try MLModel(contentsOf: destination, configuration: configuration)
print(model.modelDescription)

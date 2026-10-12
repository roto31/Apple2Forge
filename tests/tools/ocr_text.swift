// Print the text Apple's Vision framework recognizes in an image, one line per
// observation, top to bottom.
// Usage: ocr_text IMAGE
// Exit codes: 0 text printed (possibly none), 1 recognition failed, 2 bad input.

import Foundation
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: ocr_text IMAGE\n".utf8))
    exit(2)
}

let imageURL = URL(fileURLWithPath: arguments[1])
guard FileManager.default.isReadableFile(atPath: imageURL.path) else {
    FileHandle.standardError.write(Data("ERROR: cannot read \(imageURL.path)\n".utf8))
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false

do {
    try VNImageRequestHandler(url: imageURL).perform([request])
} catch {
    FileHandle.standardError.write(Data("ERROR: text recognition failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// Vision's bounding boxes have their origin at the bottom left.
let observations = (request.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
for observation in observations {
    if let best = observation.topCandidates(1).first {
        print(best.string)
    }
}

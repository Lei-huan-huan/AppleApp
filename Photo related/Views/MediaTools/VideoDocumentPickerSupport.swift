//
//  VideoDocumentPickerSupport.swift
//  Photo related
//

import UIKit
import UniformTypeIdentifiers

enum VideoDocumentPickerSupport {
    static var openingContentTypes: [UTType] {
        var list: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        for ext in ["mkv", "avi", "flv", "wmv", "webm", "m4v", "3gp", "ts", "mov", "mp4"] {
            if let type = UTType(filenameExtension: ext) {
                list.append(type)
            }
        }
        return list
    }

    static func makePicker(asCopy: Bool = true, allowsMultipleSelection: Bool) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: openingContentTypes, asCopy: asCopy)
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }
}

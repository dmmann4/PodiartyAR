//
//  ExportPackager.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/12/26.
//


import Foundation
import ZIPFoundation

/// Packages a patient's PDF report together with their .stl scan file into
/// one zip archive, ready to hand to a share sheet / save flow.
///
/// Requires the ZIPFoundation package:
///   Xcode -> File -> Add Package Dependencies...
///   https://github.com/weichsel/ZIPFoundation
enum ExportPackager {

    enum PackagingError: Error {
        case archiveCreationFailed
        case failedToAddEntry(String)
    }

    /// Builds a zip containing the exam PDF and, if available, the patient's
    /// .stl scan. Returns the URL of the resulting zip file.
    static func createExportZip(for patient: Patient) throws -> URL {
        let fileManager = FileManager.default

        // Stage files in their own temp folder with the exact names we want
        // inside the zip, since ZIPFoundation reads the entry name directly
        // off disk relative to a base folder.
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDir) }

        let generatedPDFURL = PDFReportGenerator.generateReport(for: patient)
        let stagedPDFURL = stagingDir.appendingPathComponent("Exam Report.pdf")
        try fileManager.copyItem(at: generatedPDFURL, to: stagedPDFURL)
        try? fileManager.removeItem(at: generatedPDFURL)

        var stagedScanURL: URL?
        if let scanURL = patient.scanFileURL, fileManager.fileExists(atPath: scanURL.path) {
            let destination = stagingDir.appendingPathComponent("Scan.stl")
            try fileManager.copyItem(at: scanURL, to: destination)
            stagedScanURL = destination
        }
        // If there's no scan yet, the zip just contains the PDF — the caller
        // (PatientDetailView) surfaces that to the user before exporting.

        let zipFileName = "\(sanitizedFileName(patient.fullName))-Export.zip"
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent(zipFileName)
        try? fileManager.removeItem(at: zipURL) // start clean if one already exists

        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw PackagingError.archiveCreationFailed
        }

        do {
            try archive.addEntry(with: stagedPDFURL.lastPathComponent, relativeTo: stagingDir)
        } catch {
            throw PackagingError.failedToAddEntry(stagedPDFURL.lastPathComponent)
        }

        if let stagedScanURL {
            do {
                try archive.addEntry(with: stagedScanURL.lastPathComponent, relativeTo: stagingDir)
            } catch {
                throw PackagingError.failedToAddEntry(stagedScanURL.lastPathComponent)
            }
        }

        return zipURL
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}
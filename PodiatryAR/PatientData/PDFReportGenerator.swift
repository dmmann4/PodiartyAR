//
//  PDFReportGenerator.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/12/26.
//


import UIKit

/// Renders a Patient into a neatly formatted, multi-page PDF report.
enum PDFReportGenerator {

    /// Generates the PDF and writes it to a temp file, returning the file URL.
    static func generateReport(for patient: Patient) -> URL {
        let pageWidth: CGFloat = 612   // US Letter, 72pt/in
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let contentWidth = pageWidth - margin * 2
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let fileName = "\(sanitizedFileName(patient.fullName))-Exam-Report.pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let data = renderer.pdfData { context in
            var cursorY: CGFloat = 0

            func startPage() {
                context.beginPage()
                cursorY = margin
            }

            func ensureSpace(_ height: CGFloat) {
                if cursorY + height > pageHeight - margin {
                    startPage()
                }
            }

            func drawText(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 4) {
                guard !text.isEmpty else { return }
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let boundingRect = CGRect(x: margin, y: 0, width: contentWidth, height: .greatestFiniteMagnitude)
                let size = (text as NSString).boundingRect(
                    with: boundingRect.size,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
                ensureSpace(size.height)
                let drawRect = CGRect(x: margin, y: cursorY, width: contentWidth, height: size.height)
                (text as NSString).draw(in: drawRect, withAttributes: attributes)
                cursorY += size.height + spacingAfter
            }

            func drawSectionTitle(_ title: String) {
                ensureSpace(28)
                cursorY += 8
                drawText(title, font: .boldSystemFont(ofSize: 15), color: .black, spacingAfter: 2)
                let lineY = cursorY
                context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                context.cgContext.setLineWidth(0.5)
                context.cgContext.move(to: CGPoint(x: margin, y: lineY))
                context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: lineY))
                context.cgContext.strokePath()
                cursorY += 8
            }

            func drawField(_ label: String, _ value: String) {
                let displayValue = value.isEmpty ? "—" : value
                let attributedText = NSMutableAttributedString(
                    string: "\(label): ",
                    attributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]
                )
                attributedText.append(NSAttributedString(
                    string: displayValue,
                    attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black]
                ))

                let boundingRect = CGRect(x: margin, y: 0, width: contentWidth, height: .greatestFiniteMagnitude)
                let size = attributedText.boundingRect(
                    with: boundingRect.size,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                ensureSpace(size.height)
                attributedText.draw(in: CGRect(x: margin, y: cursorY, width: contentWidth, height: size.height))
                cursorY += size.height + 4
            }

            // MARK: Content

            startPage()

            drawText("Podiatry Exam Report", font: .boldSystemFont(ofSize: 22), spacingAfter: 2)
            drawText("Generated \(Date().formatted(date: .abbreviated, time: .shortened))",
                      font: .systemFont(ofSize: 10), color: .gray, spacingAfter: 12)

            drawSectionTitle("Demographics")
            drawField("Patient ID", patient.patientID)
            drawField("Name", patient.fullName)
            drawField("Date of Birth", patient.dateOfBirth.formatted(date: .abbreviated, time: .omitted))
            drawField("Sex", patient.sex.rawValue)

            drawSectionTitle("Visit")
            drawField("Chief Complaint", patient.chiefComplaint)
            drawField("Symptom Onset", patient.symptomOnset)

            drawSectionTitle("Medical History")
            drawField("Diabetes", patient.hasDiabetes ? "Yes" : "No")
            drawField("Peripheral Vascular Disease", patient.hasPeripheralVascularDisease ? "Yes" : "No")
            drawField("Neuropathy", patient.hasNeuropathy ? "Yes" : "No")
            drawField("Other History", patient.otherMedicalHistory)

            drawSectionTitle("Foot Exam")
            drawField("Skin Condition", patient.skinCondition)
            drawField("Nail Condition", patient.nailCondition)
            drawField("Deformities / Notes", patient.deformitiesNotes)
            drawField("Dorsalis Pedis Pulse", patient.dorsalisPedisPulse.rawValue)
            drawField("Posterior Tibial Pulse", patient.posteriorTibialPulse.rawValue)
            drawField("Monofilament Sensation", patient.monofilamentSensationIntact ? "Intact" : "Diminished/Absent")
            drawField("Gait Notes", patient.gaitNotes)

            drawSectionTitle("3D Scan")
            drawField("Scan File", patient.scanFileURL?.lastPathComponent ?? "Not yet captured — see accompanying .stl in export")
        }

        try? data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}
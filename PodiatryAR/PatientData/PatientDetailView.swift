import SwiftUI

struct PatientDetailView: View {
    let patient: Patient
    
    @State private var exportZipURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isExporting = false
    @State private var exportErrorMessage: String?

    private var dobFormatted: String {
        patient.dateOfBirth.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    InitialStoryboardView()
                } label: {
                    Button { } label: {
                        Label("Start New Scan", systemImage: "camera.viewfinder")
                    }
                }
            }
            Section("Demographics") {
                LabeledContent("Patient ID", value: patient.patientID.isEmpty ? "—" : patient.patientID)
                LabeledContent("Name", value: patient.fullName)
                LabeledContent("Date of Birth", value: dobFormatted)
                LabeledContent("Sex", value: patient.sex.rawValue)
            }

            Section("Visit") {
                LabeledContent("Chief Complaint", value: patient.chiefComplaint.isEmpty ? "—" : patient.chiefComplaint)
                LabeledContent("Symptom Onset", value: patient.symptomOnset.isEmpty ? "—" : patient.symptomOnset)
            }

            Section("Medical History") {
                LabeledContent("Diabetes", value: patient.hasDiabetes ? "Yes" : "No")
                LabeledContent("Peripheral Vascular Disease", value: patient.hasPeripheralVascularDisease ? "Yes" : "No")
                LabeledContent("Neuropathy", value: patient.hasNeuropathy ? "Yes" : "No")
                LabeledContent("Other History", value: patient.otherMedicalHistory.isEmpty ? "—" : patient.otherMedicalHistory)
            }

            Section("Foot Exam") {
                LabeledContent("Skin Condition", value: patient.skinCondition.isEmpty ? "—" : patient.skinCondition)
                LabeledContent("Nail Condition", value: patient.nailCondition.isEmpty ? "—" : patient.nailCondition)
                LabeledContent("Deformities / Notes", value: patient.deformitiesNotes.isEmpty ? "—" : patient.deformitiesNotes)
                LabeledContent("Dorsalis Pedis Pulse", value: patient.dorsalisPedisPulse.rawValue)
                LabeledContent("Posterior Tibial Pulse", value: patient.posteriorTibialPulse.rawValue)
                LabeledContent("Monofilament Sensation", value: patient.monofilamentSensationIntact ? "Intact" : "Diminished/Absent")
                LabeledContent("Gait Notes", value: patient.gaitNotes.isEmpty ? "—" : patient.gaitNotes)
            }
            Section {
                Button {
                    exportPatientRecord()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Preparing Export…")
                        }
                    } else {
                        Label("Export PDF + Scan (.zip)", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
 
                if patient.scanFileURL == nil {
                    Text("No scan captured yet — the export will include the PDF report only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(patient.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingShareSheet) {
            if let exportZipURL {
                ShareSheet(items: [exportZipURL])
            }
        }
        .alert("Export Failed", isPresented: .constant(exportErrorMessage != nil), actions: {
            Button("OK") { exportErrorMessage = nil }
        }, message: {
            Text(exportErrorMessage ?? "")
        })
    }
    private func exportPatientRecord() {
        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = try ExportPackager.createExportZip(for: patient)
                DispatchQueue.main.async {
                    exportZipURL = zipURL
                    isExporting = false
                    isShowingShareSheet = true
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    exportErrorMessage = "Couldn't create the export file. \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PatientDetailView(patient: .seed(patientID: "PT-1024"))
    }
}

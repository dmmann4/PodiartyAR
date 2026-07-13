import SwiftUI

struct LoadPatientView: View {
    @State private var patientID: String = ""
    @State private var loadedPatient: Patient?
    @State private var navigateToDetail = false

    var body: some View {
        Form {
            Section("Patient Lookup") {
                TextField("Patient ID", text: $patientID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section {
                Button("Load Patient") {
                    // No real backend yet — any non-empty ID "loads" seed data
                    // so the flow can be exercised end to end.
                    loadedPatient = Patient.seed(patientID: patientID)
                    navigateToDetail = true
                }
                .disabled(patientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Load Patient")
        .navigationDestination(isPresented: $navigateToDetail) {
            if let loadedPatient {
                PatientDetailView(patient: loadedPatient)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoadPatientView()
    }
}

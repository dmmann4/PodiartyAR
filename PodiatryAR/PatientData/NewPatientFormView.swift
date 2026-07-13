import SwiftUI

struct NewPatientFormView: View {
    @State private var patient = Patient()
    @State private var navigateToDetail = false

    var body: some View {
        Form {
            Section("Demographics") {
                TextField("First Name", text: $patient.firstName)
                TextField("Last Name", text: $patient.lastName)
                DatePicker("Date of Birth", selection: $patient.dateOfBirth, displayedComponents: .date)
                Picker("Sex", selection: $patient.sex) {
                    ForEach(Patient.Sex.allCases) { sex in
                        Text(sex.rawValue).tag(sex)
                    }
                }
            }

            Section("Visit") {
                TextField("Chief Complaint", text: $patient.chiefComplaint, axis: .vertical)
                TextField("Symptom Onset", text: $patient.symptomOnset, axis: .vertical)
            }

            Section("Medical History") {
                Toggle("Diabetes", isOn: $patient.hasDiabetes)
                Toggle("Peripheral Vascular Disease", isOn: $patient.hasPeripheralVascularDisease)
                Toggle("Neuropathy", isOn: $patient.hasNeuropathy)
                TextField("Other History", text: $patient.otherMedicalHistory, axis: .vertical)
            }

            Section("Foot Exam") {
                TextField("Skin Condition", text: $patient.skinCondition, axis: .vertical)
                TextField("Nail Condition", text: $patient.nailCondition, axis: .vertical)
                TextField("Deformities / Notes", text: $patient.deformitiesNotes, axis: .vertical)

                Picker("Dorsalis Pedis Pulse", selection: $patient.dorsalisPedisPulse) {
                    ForEach(Patient.PulseStrength.allCases) { strength in
                        Text(strength.rawValue).tag(strength)
                    }
                }
                Picker("Posterior Tibial Pulse", selection: $patient.posteriorTibialPulse) {
                    ForEach(Patient.PulseStrength.allCases) { strength in
                        Text(strength.rawValue).tag(strength)
                    }
                }

                Toggle("Monofilament Sensation Intact", isOn: $patient.monofilamentSensationIntact)
                TextField("Gait Notes", text: $patient.gaitNotes, axis: .vertical)
            }
        }
        .navigationTitle("New Patient")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // Not persisting anything yet — just carry the in-memory
                    // patient forward to the detail screen.
                    navigateToDetail = true
                }
            }
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            PatientDetailView(patient: patient)
        }
    }
}

#Preview {
    NavigationStack {
        NewPatientFormView()
    }
}

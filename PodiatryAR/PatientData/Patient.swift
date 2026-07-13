import Foundation

/// Basic demographic + podiatry exam info.
/// Nothing here is persisted yet — it's just passed between views in memory.
struct Patient: Identifiable {
    enum Sex: String, CaseIterable, Identifiable {
        case female = "Female"
        case male = "Male"
        case other = "Other"
        var id: String { rawValue }
    }

    enum PulseStrength: String, CaseIterable, Identifiable {
        case absent = "Absent"
        case diminished = "Diminished"
        case normal = "Normal"
        var id: String { rawValue }
    }

    var id = UUID()

    // MARK: Demographics
    var patientID: String = ""
    var firstName: String = ""
    var lastName: String = ""
    var dateOfBirth: Date = Date()
    var sex: Sex = .female

    // MARK: Visit
    var chiefComplaint: String = ""
    var symptomOnset: String = ""

    // MARK: Medical history
    var hasDiabetes: Bool = false
    var hasPeripheralVascularDisease: Bool = false
    var hasNeuropathy: Bool = false
    var otherMedicalHistory: String = ""

    // MARK: Foot exam
    var skinCondition: String = ""
    var nailCondition: String = ""
    var deformitiesNotes: String = ""
    var dorsalisPedisPulse: PulseStrength = .normal
    var posteriorTibialPulse: PulseStrength = .normal
    var monofilamentSensationIntact: Bool = true
    var gaitNotes: String = ""

    // MARK: Scan
    /// Local file URL of the captured .stl scan for this patient, once the
    /// scan flow exists. Nil until then — export handles that gracefully.
    var scanFileURL: URL?

    var fullName: String {
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unnamed Patient" : name
    }
}

extension Patient {
    /// Seed data used when "loading" a patient by ID for now.
    static func seed(patientID: String) -> Patient {
        var patient = Patient()
        patient.patientID = patientID
        patient.firstName = "Jordan"
        patient.lastName = "Rivera"
        patient.dateOfBirth = Calendar.current.date(byAdding: .year, value: -58, to: Date()) ?? Date()
        patient.sex = .male
        patient.chiefComplaint = "Numbness and tingling in both feet"
        patient.symptomOnset = "Gradual onset over 6 months"
        patient.hasDiabetes = true
        patient.hasPeripheralVascularDisease = false
        patient.hasNeuropathy = true
        patient.otherMedicalHistory = "Hypertension, controlled with medication"
        patient.skinCondition = "Dry, mild scaling on heels"
        patient.nailCondition = "Mild onychomycosis, right great toe"
        patient.deformitiesNotes = "Mild hallux valgus bilaterally"
        patient.dorsalisPedisPulse = .diminished
        patient.posteriorTibialPulse = .normal
        patient.monofilamentSensationIntact = false
        patient.gaitNotes = "Antalgic gait, favoring left side"
        return patient
    }
}

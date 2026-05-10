import Foundation

enum PIIType: String, Hashable, Identifiable, CaseIterable {

    // MARK: - Contact
    case phoneNumber
    case email

    // MARK: - Web
    case link
    case ipAddress
    case macAddress

    // MARK: - Identity
    case address
    case socialSecurityNumber
    case dateOfBirth
    case nationalInsuranceNumber
    /// Consolidated case for international government-issued IDs (Canadian SIN,
    /// Indian PAN/Aadhaar, Spanish DNI/NIE, Brazilian CPF, German Steuer-ID,
    /// Italian Codice Fiscale, French INSEE, Japanese My Number).
    /// The matched value in the snippet sub-classifies the specific format.
    case governmentID

    // MARK: - Vehicle
    /// Vehicle Identification Number — 17-character alphanumeric code (no I/O/Q).
    /// Common in car-listing screenshots, insurance documents, and registration photos.
    case vehicleIdentificationNumber

    // MARK: - Financial
    case creditCard
    case iban
    case cryptoWallet
    /// SWIFT / BIC code identifying a bank in international wire transfers.
    case swiftBIC
    /// US ABA 9-digit bank routing number, detected only when a contextual keyword
    /// (routing, ABA) appears nearby to avoid false-positives on plain 9-digit numbers.
    case abaRoutingNumber

    // MARK: - Developer Secrets
    case awsAccessKey
    case githubToken
    case googleAPIKey
    case openAIKey
    case slackToken
    case stripeKey
    case genericPrivateKey
    /// JWT tokens — highly specific double-eyJ structure.
    case jwtToken
    /// Other vendor API tokens: Anthropic, GitLab PAT, npm, HuggingFace,
    /// DigitalOcean, Twilio, SendGrid, Discord bot tokens.
    case developerSecret
    /// Database / message-broker connection strings containing inline credentials.
    case connectionString

    // MARK: - Vision-detected (not text-based)
    /// Human faces detected via VNDetectFaceRectanglesRequest.
    case face
    /// QR codes and barcodes detected via VNDetectBarcodesRequest.
    /// The snippet carries the decoded payload for richer context.
    case barcode

    // MARK: - Unstructured / Contextual
    case unstructuredCredential

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Description

    nonisolated var description: String {
        switch self {
        // Contact
        case .phoneNumber:              return String(localized: "Phone Number")
        case .email:                    return String(localized: "Email Address")
        // Web
        case .link:                     return String(localized: "Link")
        case .ipAddress:                return String(localized: "IP Address")
        case .macAddress:               return String(localized: "MAC Address")
        // Identity
        case .address:                  return String(localized: "Address")
        case .socialSecurityNumber:     return String(localized: "Social Security Number")
        case .dateOfBirth:              return String(localized: "Date of Birth")
        case .nationalInsuranceNumber:  return String(localized: "National Insurance Number")
        case .governmentID:             return String(localized: "Government ID")
        // Vehicle
        case .vehicleIdentificationNumber: return String(localized: "Vehicle Identification Number")
        // Financial
        case .creditCard:               return String(localized: "Credit Card Number")
        case .iban:                     return String(localized: "IBAN")
        case .cryptoWallet:             return String(localized: "Crypto Wallet Address")
        case .swiftBIC:                 return String(localized: "SWIFT / BIC Code")
        case .abaRoutingNumber:         return String(localized: "ABA Routing Number")
        // Developer Secrets
        case .awsAccessKey:             return String(localized: "AWS Access Key")
        case .githubToken:              return String(localized: "GitHub Token")
        case .googleAPIKey:             return String(localized: "Google API Key")
        case .openAIKey:                return String(localized: "OpenAI API Key")
        case .slackToken:               return String(localized: "Slack Token")
        case .stripeKey:                return String(localized: "Stripe Key")
        case .genericPrivateKey:        return String(localized: "Private Key")
        case .jwtToken:                 return String(localized: "JWT Token")
        case .developerSecret:          return String(localized: "Developer Secret")
        case .connectionString:         return String(localized: "Database Connection String")
        // Vision-detected
        case .face:                     return String(localized: "Face")
        case .barcode:                  return String(localized: "QR Code / Barcode")
        // Unstructured / Contextual
        case .unstructuredCredential:   return String(localized: "Physical Credential / Password")
        }
    }
}

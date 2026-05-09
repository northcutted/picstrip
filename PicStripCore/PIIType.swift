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

    // MARK: - Financial
    case creditCard
    case iban
    case cryptoWallet

    // MARK: - Developer Secrets
    case awsAccessKey
    case githubToken
    case googleAPIKey
    case openAIKey
    case slackToken
    case stripeKey
    case genericPrivateKey

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
        // Financial
        case .creditCard:               return String(localized: "Credit Card Number")
        case .iban:                     return String(localized: "IBAN")
        case .cryptoWallet:             return String(localized: "Crypto Wallet Address")
        // Developer Secrets
        case .awsAccessKey:             return String(localized: "AWS Access Key")
        case .githubToken:              return String(localized: "GitHub Token")
        case .googleAPIKey:             return String(localized: "Google API Key")
        case .openAIKey:                return String(localized: "OpenAI API Key")
        case .slackToken:               return String(localized: "Slack Token")
        case .stripeKey:                return String(localized: "Stripe Key")
        case .genericPrivateKey:        return String(localized: "Private Key")
        // Unstructured / Contextual
        case .unstructuredCredential:   return String(localized: "Physical Credential / Password")
        }
    }
}

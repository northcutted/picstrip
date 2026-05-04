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

    var description: String {
        switch self {
        // Contact
        case .phoneNumber:              return "Phone Number"
        case .email:                    return "Email Address"
        // Web
        case .link:                     return "Link"
        case .ipAddress:                return "IP Address"
        case .macAddress:               return "MAC Address"
        // Identity
        case .address:                  return "Address"
        case .socialSecurityNumber:     return "Social Security Number"
        case .dateOfBirth:              return "Date of Birth"
        case .nationalInsuranceNumber:  return "National Insurance Number"
        // Financial
        case .creditCard:               return "Credit Card Number"
        case .iban:                     return "IBAN"
        case .cryptoWallet:             return "Crypto Wallet Address"
        // Developer Secrets
        case .awsAccessKey:             return "AWS Access Key"
        case .githubToken:              return "GitHub Token"
        case .googleAPIKey:             return "Google API Key"
        case .openAIKey:                return "OpenAI API Key"
        case .slackToken:               return "Slack Token"
        case .stripeKey:                return "Stripe Key"
        case .genericPrivateKey:        return "Private Key"
        // Unstructured / Contextual
        case .unstructuredCredential:   return "Physical Credential / Password"
        }
    }
}

import SwiftUI

// MARK: - RiskLevel

/// How a risk level looks wherever it is shown: the About catalogue, the
/// redaction editor, and the live viewfinder all use the same colour and symbol.
extension RiskLevel {
    var color: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .blue
        case .low:      return .green
        }
    }

    var symbolName: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "info.circle.fill"
        case .low:      return "checkmark.circle.fill"
        }
    }
}

// MARK: - PIIType

extension PIIType {
    /// The SF Symbol that stands for this kind of finding.
    var symbolName: String {
        switch self {
        case .phoneNumber:                 return "phone.fill"
        case .email:                       return "envelope.fill"
        case .address:                     return "map.fill"
        case .socialSecurityNumber:        return "person.text.rectangle.fill"
        case .dateOfBirth:                 return "calendar"
        case .nationalInsuranceNumber:     return "person.badge.shield.checkmark.fill"
        case .governmentID:                return "person.text.rectangle"
        case .ipAddress:                   return "network"
        case .macAddress:                  return "wifi"
        case .link:                        return "link"
        case .vehicleIdentificationNumber: return "car.fill"
        case .licensePlate:                return "rectangle.fill"
        case .creditCard:                  return "creditcard.fill"
        case .iban:                        return "building.columns.fill"
        case .cryptoWallet:                return "bitcoinsign.circle.fill"
        case .swiftBIC:                    return "globe"
        case .abaRoutingNumber:            return "banknote.fill"
        case .awsAccessKey:                return "cloud.fill"
        case .githubToken:                 return "chevron.left.forwardslash.chevron.right"
        case .googleAPIKey:                return "key.horizontal.fill"
        case .openAIKey:                   return "sparkles"
        case .slackToken:                  return "message.fill"
        case .stripeKey:                   return "dollarsign.circle.fill"
        case .genericPrivateKey:           return "key.fill"
        case .jwtToken:                    return "ellipsis.curlybraces"
        case .developerSecret:             return "lock.shield.fill"
        case .connectionString:            return "server.rack"
        case .face:                        return "face.dashed"
        case .barcode:                     return "qrcode"
        case .unstructuredCredential:      return "note.text"
        case .personName:                  return "person.text.rectangle"
        case .alwaysCover:                 return "pin.fill"
        }
    }
}

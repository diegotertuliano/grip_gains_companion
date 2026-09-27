import Foundation

enum FrezError: Error, LocalizedError, Equatable {
    case missingKey, invalidKey, keychain, disconnectBeforeEditing
    case invalidSerial, invalidRequest, deviceLimit, notAllowlisted, deviceNotFound, ownershipReview
    case invalidCoefficient, rateLimited, unavailable, network
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your personal Frez access key to connect."
        case .invalidKey: return "Frez rejected your access key. Check or replace it in Frez API Key settings."
        case .keychain: return "Could not access the saved Frez key. Unlock your phone and try again."
        case .disconnectBeforeEditing: return "Disconnect your Frez Dyno before changing its access key."
        case .invalidSerial: return "The Dyno returned an invalid serial number. Check its firmware."
        case .invalidRequest: return "Frez could not accept this calibration request. Check for an app update."
        case .deviceLimit: return "Your Frez account has reached its Personal API device limit. Check Usage in the Frez developer dashboard."
        case .notAllowlisted: return "Frez denied access to this device. Check your developer dashboard or contact Frez support."
        case .deviceNotFound: return "Frez has no calibration for this Dyno. Contact support@frez.app."
        case .ownershipReview: return "Frez requires an ownership review for this Dyno. Contact support@frez.app."
        case .invalidCoefficient: return "Frez returned unusable calibration. No force readings can be shown. Contact Frez support."
        case .rateLimited: return "Frez's request limit was reached. Wait at least a minute before trying again."
        case .unavailable: return "Frez calibration access is unavailable. Try again later or contact Frez support."
        case .network: return "Could not reach Frez. An internet connection is required each time you connect the Dyno."
        case .protocolFailure(let message): return message
        }
    }
}

protocol FrezCoefficientProviding {
    func coefficient(serial: String, accessKey: String) async throws -> Double
}

/// No disk cache, cookies, credential storage, or redirects carrying the personal key.
final class FrezCoefficientClient: NSObject, FrezCoefficientProviding, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    static func validatedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FrezError.missingKey }
        guard key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw FrezError.invalidKey }
        return key
    }

    static func request(serial: String, accessKey: String) throws -> URLRequest {
        guard serial.utf8.count == 15,
              serial.range(of: "^FrezDyno-[0-9]{6}$", options: .regularExpression) != nil else {
            throw FrezError.invalidSerial
        }
        let key = try validatedKey(accessKey)
        var url = URLComponents(string: "https://api.frez.app/functions/v1/dyno-coefficient")!
        url.queryItems = [URLQueryItem(name: "serial", value: serial)]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(key, forHTTPHeaderField: "X-Frez-Access-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func coefficient(serial: String, accessKey: String) async throws -> Double {
        let request = try Self.request(serial: serial, accessKey: accessKey)
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw FrezError.unavailable }
            return try Self.decode(data, statusCode: response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FrezError {
            throw error
        } catch {
            // Never surface URLSession's request details (serial or key) in UI/logs.
            throw FrezError.network
        }
    }

    static func decode(_ data: Data, statusCode: Int) throws -> Double {
        struct Failure: Decodable { let error: String }
        let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
        switch statusCode {
        case 200:
            struct Response: Decodable { let a: Double }
            guard let response = try? JSONDecoder().decode(Response.self, from: data),
                  response.a.isFinite, response.a != 0 else { throw FrezError.invalidCoefficient }
            return response.a
        case 400: throw FrezError.invalidRequest
        case 401: throw FrezError.invalidKey
        case 403: throw code == "device_limit_reached" ? FrezError.deviceLimit : FrezError.notAllowlisted
        case 404: throw FrezError.deviceNotFound
        case 409: throw FrezError.ownershipReview
        case 422: throw FrezError.invalidCoefficient
        case 429: throw FrezError.rateLimited
        default: throw FrezError.unavailable
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

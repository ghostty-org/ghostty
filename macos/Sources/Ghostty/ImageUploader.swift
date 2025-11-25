import Foundation
import os

extension Ghostty {
    /// Result of an image upload operation
    enum ImageUploadResult {
        case success(String)  // Uploaded URL
        case failure(String)  // Error message
        case fallback         // Use fallback behavior (paste file path)
    }

    /// Configuration for image upload
    struct ImageUploadConfig {
        let enable: Bool
        let url: String?
        let format: Config.ImageUploadFormat
        let field: String
        let header: String?
        let responsePath: String
        let maxSize: UInt32
        let timeout: UInt32
        let fallback: Config.ImageUploadFallback

        init(_ config: Config) {
            self.enable = config.imageUploadEnable
            self.url = config.imageUploadUrl
            self.format = config.imageUploadFormat
            self.field = config.imageUploadField
            self.header = config.imageUploadHeader
            self.responsePath = config.imageUploadResponsePath
            self.maxSize = config.imageUploadMaxSize
            self.timeout = config.imageUploadTimeout
            self.fallback = config.imageUploadFallback
        }

        init() {
            self.enable = false
            self.url = nil
            self.format = .multipart
            self.field = "image"
            self.header = nil
            self.responsePath = "json:$.data.link"
            self.maxSize = 10
            self.timeout = 30
            self.fallback = .path
        }
    }

    /// Handles image upload to configured API endpoints
    class ImageUploader {
        private let config: ImageUploadConfig
        private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "image-upload")

        /// Supported image extensions
        private static let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif"
        ]

        init(config: ImageUploadConfig) {
            self.config = config
        }

        /// Check if a file path points to an image file
        func isImageFile(_ path: String) -> Bool {
            let ext = (path as NSString).pathExtension.lowercased()
            return Self.imageExtensions.contains(ext)
        }

        /// Upload an image file and return the result
        func upload(filePath: String) async -> ImageUploadResult {
            // Check if upload is enabled
            guard config.enable else {
                return .fallback
            }

            // Check if URL is configured
            guard let urlString = config.url, !urlString.isEmpty else {
                logger.warning("Image upload enabled but no URL configured")
                return .fallback
            }

            // Check if file is an image
            guard isImageFile(filePath) else {
                return .fallback
            }

            // Read file
            let fileURL = URL(fileURLWithPath: filePath)
            guard let fileData = try? Data(contentsOf: fileURL) else {
                logger.error("Failed to read file: \(filePath)")
                return .failure("Failed to read file")
            }

            // Check file size
            let maxBytes = UInt64(config.maxSize) * 1024 * 1024
            guard fileData.count <= maxBytes else {
                logger.warning("File size \(fileData.count) exceeds max \(maxBytes)")
                return .fallback
            }

            // Build and send request
            guard let url = URL(string: urlString) else {
                logger.error("Invalid upload URL: \(urlString)")
                return .failure("Invalid upload URL")
            }

            do {
                let response = try await performUpload(
                    url: url,
                    fileData: fileData,
                    fileName: fileURL.lastPathComponent
                )

                // Parse response to extract URL
                let uploadedURL = try parseResponse(response)
                logger.info("Image uploaded successfully: \(uploadedURL)")
                return .success(uploadedURL)
            } catch {
                logger.error("Upload failed: \(error.localizedDescription)")
                return .failure(error.localizedDescription)
            }
        }

        /// Perform the HTTP upload request
        private func performUpload(url: URL, fileData: Data, fileName: String) async throws -> Data {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = TimeInterval(config.timeout)

            // Add custom headers
            if let headerString = config.header {
                // Parse header in format "Name: Value"
                let headers = headerString.split(separator: "\n")
                for header in headers {
                    if let colonIndex = header.firstIndex(of: ":") {
                        let name = String(header[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                        let value = String(header[header.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && !value.isEmpty {
                            request.setValue(value, forHTTPHeaderField: name)
                        }
                    }
                }
            }

            // Build request body based on format
            switch config.format {
            case .multipart:
                let boundary = "----GhosttyImageUploadBoundary"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = buildMultipartBody(fileData: fileData, fileName: fileName, boundary: boundary)

            case .json:
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let base64 = fileData.base64EncodedString()
                let json: [String: Any] = [config.field: base64]
                request.httpBody = try JSONSerialization.data(withJSONObject: json)

            case .binary:
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.httpBody = fileData
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImageUploadError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw ImageUploadError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        /// Build multipart/form-data body
        private func buildMultipartBody(fileData: Data, fileName: String, boundary: String) -> Data {
            var body = Data()

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(config.field)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            return body
        }

        /// Parse response to extract uploaded URL using configured path
        private func parseResponse(_ data: Data) throws -> String {
            let responsePath = config.responsePath

            if responsePath.hasPrefix("json:") {
                let jsonPath = String(responsePath.dropFirst(5))
                return try parseJsonPath(data: data, path: jsonPath)
            } else if responsePath.hasPrefix("regex:") {
                // Regex not implemented yet
                throw ImageUploadError.regexNotImplemented
            } else {
                throw ImageUploadError.invalidResponsePath
            }
        }

        /// Parse JSON using a simple JSONPath-like syntax ($.field.subfield)
        private func parseJsonPath(data: Data, path: String) throws -> String {
            let json = try JSONSerialization.jsonObject(with: data)

            var current: Any = json
            let segments = path.split(separator: ".").map(String.init)

            for segment in segments {
                // Skip root marker
                if segment == "$" { continue }

                if let dict = current as? [String: Any] {
                    guard let value = dict[segment] else {
                        throw ImageUploadError.jsonPathNotFound(segment)
                    }
                    current = value
                } else if let array = current as? [Any], let index = Int(segment) {
                    guard index < array.count else {
                        throw ImageUploadError.arrayIndexOutOfBounds(index)
                    }
                    current = array[index]
                } else {
                    throw ImageUploadError.invalidJsonPath
                }
            }

            guard let urlString = current as? String else {
                throw ImageUploadError.notAString
            }

            return urlString
        }
    }

    /// Errors that can occur during image upload
    enum ImageUploadError: LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int)
        case regexNotImplemented
        case invalidResponsePath
        case jsonPathNotFound(String)
        case arrayIndexOutOfBounds(Int)
        case invalidJsonPath
        case notAString

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid server response"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .regexNotImplemented:
                return "Regex parsing not implemented"
            case .invalidResponsePath:
                return "Invalid response path configuration"
            case .jsonPathNotFound(let segment):
                return "JSON path segment not found: \(segment)"
            case .arrayIndexOutOfBounds(let index):
                return "Array index out of bounds: \(index)"
            case .invalidJsonPath:
                return "Invalid JSON path"
            case .notAString:
                return "Response value is not a string"
            }
        }
    }
}

// TAGGR: Uploads user-selected videos directly to the user's YouTube channel.

import CoreTransferable
import Foundation
import GoogleSignIn
import Observation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct TaggrYouTubeConfiguration: Equatable, Sendable {
    let clientID: String
    let reversedClientID: String

    static var current: TaggrYouTubeConfiguration {
        from(info: Bundle.main.infoDictionary ?? [:])
    }

    static func from(info: [String: Any]) -> TaggrYouTubeConfiguration {
        TaggrYouTubeConfiguration(
            clientID: value("GIDClientID", in: info),
            reversedClientID: value("TAGGR_GOOGLE_REVERSED_CLIENT_ID", in: info)
        )
    }

    var isEnabled: Bool {
        !clientID.isEmpty && !reversedClientID.isEmpty
    }

    private static func value(_ key: String, in info: [String: Any]) -> String {
        guard let raw = info[key] as? String else { return "" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("$(") ? "" : value
    }
}

enum YouTubePrivacyStatus: String, CaseIterable, Codable, Sendable {
    case unlisted
    case `public`
    case `private`

    var title: String {
        switch self {
        case .unlisted: "Unlisted"
        case .public: "Public"
        case .private: "Private"
        }
    }
}

struct YouTubeUploadMetadata: Codable, Equatable, Sendable {
    static let maximumTitleCharacters = 100
    static let maximumDescriptionBytes = 5_000

    var title: String
    var description: String
    var privacy: YouTubePrivacyStatus = .unlisted
    var madeForKids: Bool?
    var containsSyntheticMedia = false
    var communityGuidelinesAccepted = false

    var validationMessage: String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return "Enter a YouTube title."
        }
        if title.count > Self.maximumTitleCharacters {
            return "The YouTube title must be 100 characters or fewer."
        }
        if title.contains("<") || title.contains(">") {
            return "The YouTube title cannot contain < or >."
        }
        if description.utf8.count > Self.maximumDescriptionBytes {
            return "The YouTube description must be 5,000 bytes or fewer."
        }
        if description.contains("<") || description.contains(">") {
            return "The YouTube description cannot contain < or >."
        }
        if madeForKids == nil {
            return "Choose whether the video is made for kids."
        }
        if !communityGuidelinesAccepted {
            return "Confirm that the video follows YouTube's rules."
        }
        return nil
    }

    func requestBody() throws -> Data {
        guard validationMessage == nil, let madeForKids else {
            throw YouTubeUploadError.invalidMetadata(validationMessage ?? "Invalid YouTube metadata.")
        }
        let object: [String: Any] = [
            "snippet": [
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "description": description,
            ],
            "status": [
                "privacyStatus": privacy.rawValue,
                "embeddable": true,
                "selfDeclaredMadeForKids": madeForKids,
                "containsSyntheticMedia": containsSyntheticMedia,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

struct YouTubeChannel: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

struct YouTubeDraftTarget: Codable, Equatable, Hashable, Sendable {
    let namespace: PostDraftNamespace
    let context: PostDraftContext
}

enum YouTubeUploadPhase: String, Codable, Sendable {
    case preparing
    case uploading
    case failed
    case completed
}

enum YouTubeUploadRecoveryAction: Equatable {
    case none
    case createSession
    case queryStatus
    case awaitBackgroundTask
}

enum YouTubeBackgroundTaskDisposition: Equatable {
    case keep
    case cancel
}

struct YouTubeUploadJob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let target: YouTubeDraftTarget
    let sourceFileName: String
    let displayFileName: String
    let mimeType: String
    let byteCount: Int64
    let metadata: YouTubeUploadMetadata
    var sessionURL: URL?
    var acknowledgedBytes: Int64
    var retryCount: Int
    var phase: YouTubeUploadPhase
    var videoID: String?
    var failureMessage: String?
    let createdAt: Date

    var youtubeURL: URL? {
        videoID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }
}

enum YouTubeUploadError: LocalizedError, Equatable {
    case unavailable
    case notConnected
    case noChannel
    case invalidMetadata(String)
    case invalidVideo
    case uploadAlreadyRunning
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "YouTube upload is not configured in this build."
        case .notConnected:
            "Connect a YouTube account first."
        case .noChannel:
            "This Google account does not have a YouTube channel."
        case .invalidMetadata(let message):
            message
        case .invalidVideo:
            "The selected video could not be read."
        case .uploadAlreadyRunning:
            "Another YouTube upload is already running."
        case .invalidResponse:
            "YouTube returned an invalid response."
        case .server(_, let message):
            message
        }
    }
}

struct YouTubeVideoSelection: Transferable, Sendable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { selection in
            SentTransferredFile(selection.fileURL)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory
                .appending(
                    path: "\(YouTubeTemporarySelection.directoryPrefix)\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let destination = directory.appending(path: received.file.lastPathComponent)
                try FileManager.default.copyItem(at: received.file, to: destination)
                return YouTubeVideoSelection(fileURL: destination)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}

enum YouTubeTemporarySelection {
    static let directoryPrefix = "taggr-youtube-selection-"

    static func remove(at fileURL: URL?, fileManager: FileManager = .default) {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == temporaryDirectory,
              directory.lastPathComponent.hasPrefix(directoryPrefix) else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }
}

@MainActor
@Observable
final class YouTubeAuthStore {
    static let uploadScope = "https://www.googleapis.com/auth/youtube.upload"
    static let readScope = "https://www.googleapis.com/auth/youtube.readonly"

    let configuration: TaggrYouTubeConfiguration
    private(set) var channel: YouTubeChannel?
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let session: URLSession

    init(
        configuration: TaggrYouTubeConfiguration = .current,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    var isEnabled: Bool { configuration.isEnabled }
    var isConnected: Bool { channel != nil && GIDSignIn.sharedInstance.currentUser != nil }

    func bootstrap() {
        guard isEnabled else { return }
        GIDSignIn.sharedInstance.configure { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = error.localizedDescription
                    return
                }
                self?.restorePreviousSignIn()
            }
        }
    }

    func connect() {
        guard isEnabled else {
            errorMessage = YouTubeUploadError.unavailable.localizedDescription
            return
        }
        guard let presenter = UIApplication.shared.taggrTopViewController else {
            errorMessage = "YouTube sign-in could not be presented."
            return
        }
        isBusy = true
        errorMessage = nil
        GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: [Self.uploadScope, Self.readScope]
        ) { [weak self] result, error in
            let didSignIn = result?.user != nil
            let errorCode = (error as NSError?)?.code
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let errorDescription {
                    self.isBusy = false
                    if errorCode != GIDSignInError.canceled.rawValue {
                        self.errorMessage = errorDescription
                    }
                    return
                }
                guard didSignIn else {
                    self.isBusy = false
                    self.errorMessage = YouTubeUploadError.notConnected.localizedDescription
                    return
                }
                await self.loadChannel()
            }
        }
    }

    func disconnect(onComplete: (@MainActor () -> Void)? = nil) {
        isBusy = true
        GIDSignIn.sharedInstance.disconnect { [weak self] error in
            Task { @MainActor in
                self?.channel = nil
                self?.isBusy = false
                self?.errorMessage = error?.localizedDescription
                onComplete?()
            }
        }
    }

    func accessToken() async throws -> String {
        guard let currentUser = GIDSignIn.sharedInstance.currentUser else {
            throw YouTubeUploadError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            currentUser.refreshTokensIfNeeded { user, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = user?.accessToken.tokenString, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: YouTubeUploadError.notConnected)
                }
            }
        }
    }

    private func restorePreviousSignIn() {
        isBusy = true
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            let didRestore = user != nil && error == nil
            Task { @MainActor in
                guard let self else { return }
                guard didRestore else {
                    self.channel = nil
                    self.isBusy = false
                    return
                }
                await self.loadChannel()
            }
        }
    }

    private func loadChannel() async {
        do {
            let token = try await accessToken()
            var request = URLRequest(
                url: URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")!
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw YouTubeUploadError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw YouTubeUploadError.server(
                    status: response.statusCode,
                    message: Self.apiErrorMessage(data: data, fallback: "YouTube channel lookup failed.")
                )
            }
            struct Response: Decodable {
                struct Item: Decodable {
                    struct Snippet: Decodable { let title: String }
                    let id: String
                    let snippet: Snippet
                }
                let items: [Item]
            }
            guard let item = try JSONDecoder().decode(Response.self, from: data).items.first else {
                throw YouTubeUploadError.noChannel
            }
            channel = YouTubeChannel(id: item.id, title: item.snippet.title)
            errorMessage = nil
        } catch {
            channel = nil
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    static func apiErrorMessage(data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return fallback
        }
        return message
    }
}

actor YouTubeUploadJobStore {
    static let maximumJobAge: TimeInterval = 7 * 24 * 60 * 60

    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TAGGR", directoryHint: .isDirectory)
            .appending(path: "YouTubeUploads", directoryHint: .isDirectory)
    }

    func createJob(
        sourceURL: URL,
        metadata: YouTubeUploadMetadata,
        target: YouTubeDraftTarget
    ) throws -> YouTubeUploadJob {
        try ensureDirectory()
        let id = UUID()
        let pathExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let sourceFileName = "\(id.uuidString).\(pathExtension)"
        let destination = rootURL.appending(path: sourceFileName)
        try fileManager.copyItem(at: sourceURL, to: destination)
        applyProtection(to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let byteCount = values.fileSize, byteCount > 0 else {
            try? fileManager.removeItem(at: destination)
            throw YouTubeUploadError.invalidVideo
        }
        let job = YouTubeUploadJob(
            schemaVersion: YouTubeUploadJob.currentSchemaVersion,
            id: id,
            target: target,
            sourceFileName: sourceFileName,
            displayFileName: sourceURL.deletingPathExtension().lastPathComponent,
            mimeType: values.contentType?.preferredMIMEType ?? "video/quicktime",
            byteCount: Int64(byteCount),
            metadata: metadata,
            sessionURL: nil,
            acknowledgedBytes: 0,
            retryCount: 0,
            phase: .preparing,
            videoID: nil,
            failureMessage: nil,
            createdAt: Date()
        )
        try save(job)
        return job
    }

    func load() -> YouTubeUploadJob? {
        guard let data = try? Data(contentsOf: metadataURL),
              let job = try? JSONDecoder().decode(YouTubeUploadJob.self, from: data),
              job.schemaVersion == YouTubeUploadJob.currentSchemaVersion,
              Date().timeIntervalSince(job.createdAt) <= Self.maximumJobAge,
              job.phase == .completed || fileManager.fileExists(atPath: sourceURL(for: job).path) else {
            deleteAll()
            return nil
        }
        return job
    }

    func save(_ job: YouTubeUploadJob) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: metadataURL, options: .atomic)
        applyProtection(to: metadataURL)
    }

    func sourceURL(for job: YouTubeUploadJob) -> URL {
        rootURL.appending(path: job.sourceFileName)
    }

    func makeChunk(for job: YouTubeUploadJob, offset: Int64, maximumLength: Int) throws -> URL {
        let source = try FileHandle(forReadingFrom: sourceURL(for: job))
        defer { try? source.close() }
        try source.seek(toOffset: UInt64(offset))
        let remaining = max(job.byteCount - offset, 0)
        let data = try source.read(upToCount: min(maximumLength, Int(remaining))) ?? Data()
        guard !data.isEmpty else { throw YouTubeUploadError.invalidVideo }
        let chunkURL = rootURL.appending(path: "chunk-\(job.id.uuidString)-\(offset).bin")
        try data.write(to: chunkURL, options: .atomic)
        applyProtection(to: chunkURL)
        return chunkURL
    }

    func removeChunk(_ url: URL?) {
        guard let url else { return }
        try? fileManager.removeItem(at: url)
    }

    func delete(_ job: YouTubeUploadJob, keepMetadata: Bool = false) {
        try? fileManager.removeItem(at: sourceURL(for: job))
        removeOrphanedChunks()
        if !keepMetadata {
            try? fileManager.removeItem(at: metadataURL)
        }
    }

    func deleteAll() {
        try? fileManager.removeItem(at: rootURL)
    }

    private var metadataURL: URL { rootURL.appending(path: "job.json") }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
        applyProtection(to: rootURL)
    }

    private func applyProtection(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func removeOrphanedChunks() {
        guard let contents = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix("chunk-") {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
@Observable
final class YouTubeUploadCoordinator {
    static let backgroundSessionIdentifier = "network.taggr.ios.youtube-upload"
    static let chunkSize = 8 * 1_024 * 1_024
    static let maximumRetries = 5

    private(set) var job: YouTubeUploadJob?
    private(set) var sentBytes: Int64 = 0
    private(set) var completionRevision = 0
    private(set) var isStarting = false
    private(set) var errorMessage: String?

    let auth: YouTubeAuthStore
    @ObservationIgnored private let store: YouTubeUploadJobStore
    @ObservationIgnored private let delegate = YouTubeBackgroundSessionDelegate()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var restorationTask: Task<YouTubeUploadJob?, Never>?
    @ObservationIgnored private var didRestoreJob = false
    @ObservationIgnored private var isHandlingBackgroundEvents = false
    @ObservationIgnored private var activeChunkURL: URL?
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    init(
        auth: YouTubeAuthStore = YouTubeAuthStore(),
        store: YouTubeUploadJobStore = YouTubeUploadJobStore()
    ) {
        self.auth = auth
        self.store = store
        delegate.owner = self
    }

    var progress: Double {
        guard let job, job.byteCount > 0 else { return 0 }
        return min(Double(max(sentBytes, job.acknowledgedBytes)) / Double(job.byteCount), 1)
    }

    var isRunning: Bool {
        isStarting || job?.phase == .preparing || job?.phase == .uploading
    }

    func bootstrap() async {
        auth.bootstrap()
        await restoreJobIfNeeded()
        guard !isHandlingBackgroundEvents else { return }
        await reconcileBackgroundTasks()
    }

    func start(
        sourceURL: URL,
        metadata: YouTubeUploadMetadata,
        target: YouTubeDraftTarget
    ) async {
        await restoreJobIfNeeded()
        guard !isHandlingBackgroundEvents, !isRunning, job == nil else {
            errorMessage = YouTubeUploadError.uploadAlreadyRunning.localizedDescription
            return
        }
        guard metadata.validationMessage == nil else {
            errorMessage = metadata.validationMessage
            return
        }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let created = try await store.createJob(sourceURL: sourceURL, metadata: metadata, target: target)
            job = created
            sentBytes = 0
            YouTubeTemporarySelection.remove(at: sourceURL)
            await resumeAfterInterruption()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        await restoreJobIfNeeded()
        guard var job, job.phase == .failed else { return }
        job.phase = job.sessionURL == nil ? .preparing : .uploading
        job.failureMessage = nil
        job.retryCount = 0
        self.job = job
        try? await store.save(job)
        await resumeAfterInterruption()
    }

    func cancel() async {
        await restoreJobIfNeeded()
        retryTask?.cancel()
        retryTask = nil
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
        await store.removeChunk(activeChunkURL)
        activeChunkURL = nil
        if let job {
            await store.delete(job)
        }
        job = nil
        sentBytes = 0
        isStarting = false
        errorMessage = nil
    }

    func disconnect() {
        auth.disconnect { [weak self] in
            guard let self else { return }
            Task { await self.cancelAndDeleteAll() }
        }
    }

    func completedURL(for target: YouTubeDraftTarget) -> URL? {
        guard job?.target == target, job?.phase == .completed else { return nil }
        return job?.youtubeURL
    }

    func acknowledgeCompletion(for target: YouTubeDraftTarget) async {
        await restoreJobIfNeeded()
        guard let job, job.target == target, job.phase == .completed else { return }
        await store.delete(job)
        self.job = nil
        sentBytes = 0
        errorMessage = nil
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        isHandlingBackgroundEvents = true
        delegate.setBackgroundCompletionHandler { [weak self] in
            self?.isHandlingBackgroundEvents = false
            completionHandler()
        }
        Task { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            await self.restoreJobIfNeeded()
            _ = self.session
        }
    }

    fileprivate func didSend(task: URLSessionTask, totalBytesSent: Int64) {
        guard task.taskDescription == job?.id.uuidString, let job else { return }
        sentBytes = min(job.acknowledgedBytes + totalBytesSent, job.byteCount)
    }

    fileprivate func didComplete(
        task: URLSessionTask,
        response: HTTPURLResponse?,
        data: Data,
        error: Error?
    ) async {
        guard task.taskDescription == job?.id.uuidString else { return }
        await store.removeChunk(activeChunkURL)
        activeChunkURL = nil
        if let error, (error as NSError).code != NSURLErrorCancelled {
            await scheduleRetry(message: error.localizedDescription)
            return
        }
        guard let response else {
            await scheduleRetry(message: YouTubeUploadError.invalidResponse.localizedDescription)
            return
        }
        await handleUploadResponse(response, data: data)
    }

    private func restoreJobIfNeeded() async {
        guard !didRestoreJob else { return }
        let task: Task<YouTubeUploadJob?, Never>
        if let restorationTask {
            task = restorationTask
        } else {
            let store = store
            let createdTask = Task { await store.load() }
            restorationTask = createdTask
            task = createdTask
        }
        let restoredJob = await task.value
        guard !didRestoreJob else { return }
        job = restoredJob
        sentBytes = restoredJob?.acknowledgedBytes ?? 0
        didRestoreJob = true
        restorationTask = nil
    }

    private func reconcileBackgroundTasks() async {
        let tasks = await session.allTasks
        let matchingTasks = tasks.filter {
            Self.backgroundTaskDisposition(for: job, taskDescription: $0.taskDescription) == .keep
        }
        tasks.filter {
            Self.backgroundTaskDisposition(for: job, taskDescription: $0.taskDescription) == .cancel
        }.forEach { $0.cancel() }

        switch Self.recoveryAction(for: job, hasMatchingBackgroundTask: !matchingTasks.isEmpty) {
        case .none:
            matchingTasks.forEach { $0.cancel() }
        case .awaitBackgroundTask:
            matchingTasks.dropFirst().forEach { $0.cancel() }
        case .createSession, .queryStatus:
            await resumeAfterInterruption()
        }
    }

    private func resumeAfterInterruption() async {
        guard let job else { return }
        do {
            switch Self.recoveryAction(for: job, hasMatchingBackgroundTask: false) {
            case .createSession:
                try await createResumableSession()
            case .queryStatus:
                try await queryUploadStatus()
            case .none, .awaitBackgroundTask:
                return
            }
        } catch {
            await scheduleRetry(message: error.localizedDescription)
        }
    }

    private func createResumableSession() async throws {
        guard var job else { return }
        let token = try await auth.accessToken()
        let request = try Self.resumableSessionRequest(job: job, accessToken: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw YouTubeUploadError.invalidResponse
        }
        guard response.statusCode == 200, let location = response.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw YouTubeUploadError.server(
                status: response.statusCode,
                message: YouTubeAuthStore.apiErrorMessage(data: data, fallback: "YouTube could not start the upload.")
            )
        }
        job.sessionURL = sessionURL
        job.phase = .uploading
        job.failureMessage = nil
        job.retryCount = 0
        self.job = job
        try await store.save(job)
        try await enqueueNextChunk()
    }

    private func enqueueNextChunk() async throws {
        guard let job, let sessionURL = job.sessionURL else {
            throw YouTubeUploadError.invalidResponse
        }
        guard job.acknowledgedBytes < job.byteCount else {
            try await queryUploadStatus()
            return
        }
        let token = try await auth.accessToken()
        let chunkURL = try await store.makeChunk(
            for: job,
            offset: job.acknowledgedBytes,
            maximumLength: Self.chunkSize
        )
        let size = Int64((try chunkURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        guard size > 0 else { throw YouTubeUploadError.invalidVideo }
        activeChunkURL = chunkURL
        let request = Self.chunkRequest(
            job: job,
            sessionURL: sessionURL,
            accessToken: token,
            chunkLength: size
        )
        let task = session.uploadTask(with: request, fromFile: chunkURL)
        task.taskDescription = job.id.uuidString
        task.resume()
    }

    private func queryUploadStatus() async throws {
        guard let job, let sessionURL = job.sessionURL else { return }
        let token = try await auth.accessToken()
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes */\(job.byteCount)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw YouTubeUploadError.invalidResponse
        }
        await handleUploadResponse(response, data: data)
    }

    private func handleUploadResponse(_ response: HTTPURLResponse, data: Data) async {
        guard var job else { return }
        switch response.statusCode {
        case 200, 201:
            struct Response: Decodable { let id: String }
            guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.id.isEmpty else {
                await scheduleRetry(message: YouTubeUploadError.invalidResponse.localizedDescription)
                return
            }
            job.videoID = response.id
            job.acknowledgedBytes = job.byteCount
            job.phase = .completed
            job.failureMessage = nil
            self.job = job
            sentBytes = job.byteCount
            try? await store.save(job)
            await store.delete(job, keepMetadata: true)
            completionRevision &+= 1
        case 308:
            let acknowledged = Self.acknowledgedBytes(from: response) ?? job.acknowledgedBytes
            job.acknowledgedBytes = min(max(acknowledged, job.acknowledgedBytes), job.byteCount)
            job.retryCount = 0
            job.failureMessage = nil
            self.job = job
            sentBytes = job.acknowledgedBytes
            try? await store.save(job)
            do {
                try await enqueueNextChunk()
            } catch {
                await scheduleRetry(message: error.localizedDescription)
            }
        case 401:
            await scheduleRetry(message: "YouTube authorization expired.", immediate: true)
        case 404, 410:
            job.sessionURL = nil
            job.acknowledgedBytes = 0
            self.job = job
            sentBytes = 0
            try? await store.save(job)
            await scheduleRetry(message: "The YouTube upload session expired.", immediate: true)
        case 429, 500...599:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            await scheduleRetry(
                message: YouTubeAuthStore.apiErrorMessage(data: data, fallback: "YouTube is temporarily unavailable."),
                delayOverride: retryAfter
            )
        default:
            failPermanently(
                YouTubeAuthStore.apiErrorMessage(data: data, fallback: "YouTube upload failed (\(response.statusCode)).")
            )
        }
    }

    private func scheduleRetry(
        message: String,
        immediate: Bool = false,
        delayOverride: TimeInterval? = nil
    ) async {
        guard var job else { return }
        guard job.retryCount < Self.maximumRetries else {
            failPermanently(message)
            return
        }
        job.retryCount += 1
        job.failureMessage = message
        self.job = job
        try? await store.save(job)
        let delay = delayOverride ?? (immediate ? 0 : min(pow(2, Double(job.retryCount)), 30))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.resumeAfterInterruption()
        }
    }

    private func failPermanently(_ message: String) {
        guard var job else { return }
        job.phase = .failed
        job.failureMessage = message
        self.job = job
        Task { try? await store.save(job) }
    }

    private func cancelAndDeleteAll() async {
        await cancel()
        await store.deleteAll()
    }

    static func recoveryAction(
        for job: YouTubeUploadJob?,
        hasMatchingBackgroundTask: Bool
    ) -> YouTubeUploadRecoveryAction {
        guard let job, job.phase == .preparing || job.phase == .uploading else {
            return .none
        }
        if hasMatchingBackgroundTask {
            return .awaitBackgroundTask
        }
        return job.sessionURL == nil ? .createSession : .queryStatus
    }

    static func backgroundTaskDisposition(
        for job: YouTubeUploadJob?,
        taskDescription: String?
    ) -> YouTubeBackgroundTaskDisposition {
        guard let job,
              job.phase == .preparing || job.phase == .uploading,
              taskDescription == job.id.uuidString else {
            return .cancel
        }
        return .keep
    }

    static func acknowledgedBytes(from response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Range"),
              let lastComponent = value.split(separator: "-").last,
              let lastByte = Int64(lastComponent) else {
            return nil
        }
        return lastByte + 1
    }

    static func resumableSessionRequest(job: YouTubeUploadJob, accessToken: String) throws -> URLRequest {
        var components = URLComponents(string: "https://www.googleapis.com/upload/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "part", value: "snippet,status"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try job.metadata.requestBody()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(job.byteCount), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(job.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        return request
    }

    static func chunkRequest(
        job: YouTubeUploadJob,
        sessionURL: URL,
        accessToken: String,
        chunkLength: Int64
    ) -> URLRequest {
        let lastByte = job.acknowledgedBytes + chunkLength - 1
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(job.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("bytes \(job.acknowledgedBytes)-\(lastByte)/\(job.byteCount)", forHTTPHeaderField: "Content-Range")
        request.setValue(String(chunkLength), forHTTPHeaderField: "Content-Length")
        return request
    }
}

final class YouTubeBackgroundEventCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var backgroundCompletionHandler: (@MainActor () -> Void)?
    private var backgroundEventsDidFinish = false
    private var pendingOwnerCallbacks = 0

    func setHandler(_ completionHandler: @escaping @MainActor () -> Void) {
        lock.withLock {
            backgroundCompletionHandler = completionHandler
            backgroundEventsDidFinish = false
        }
    }

    func beginOwnerCallback() {
        lock.withLock {
            pendingOwnerCallbacks += 1
        }
    }

    func finishOwnerCallback() {
        deliverIfReady(markEventsFinished: false)
    }

    func eventsDidFinish() {
        deliverIfReady(markEventsFinished: true)
    }

    private func deliverIfReady(markEventsFinished: Bool) {
        let handler = lock.withLock { () -> (@MainActor () -> Void)? in
            if markEventsFinished, backgroundCompletionHandler != nil {
                backgroundEventsDidFinish = true
            } else if !markEventsFinished {
                pendingOwnerCallbacks = max(pendingOwnerCallbacks - 1, 0)
            }
            guard backgroundEventsDidFinish,
                  pendingOwnerCallbacks == 0,
                  let handler = backgroundCompletionHandler else {
                return nil
            }
            backgroundCompletionHandler = nil
            backgroundEventsDidFinish = false
            return handler
        }
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}

private final class YouTubeBackgroundSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    weak var owner: YouTubeUploadCoordinator?
    private let lock = NSLock()
    private let completionGate = YouTubeBackgroundEventCompletionGate()
    private var responseData: [Int: Data] = [:]
    private var responses: [Int: HTTPURLResponse] = [:]

    func setBackgroundCompletionHandler(_ completionHandler: @escaping @MainActor () -> Void) {
        completionGate.setHandler(completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock {
            responses[dataTask.taskIdentifier] = response as? HTTPURLResponse
            responseData[dataTask.taskIdentifier] = Data()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            responseData[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor [weak owner] in
            owner?.didSend(task: task, totalBytesSent: totalBytesSent)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let values = lock.withLock {
            (responses.removeValue(forKey: task.taskIdentifier), responseData.removeValue(forKey: task.taskIdentifier) ?? Data())
        }
        completionGate.beginOwnerCallback()
        Task { @MainActor [weak self, weak owner] in
            await owner?.didComplete(task: task, response: values.0, data: values.1, error: error)
            self?.completionGate.finishOwnerCallback()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionGate.eventsDidFinish()
    }
}

private extension UIApplication {
    var taggrTopViewController: UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return Self.topViewController(from: root)
    }

    static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tabs = controller as? UITabBarController {
            return topViewController(from: tabs.selectedViewController)
        }
        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }
        return controller
    }
}

import Foundation

// UNVERIFIED shapes, see DSMWriteEndpoints.swift. Decoding is lossy so small differences don't break it.

/// Response of a call that starts a background task on the NAS.
struct TaskStartDTO: Decodable, Sendable {
    let taskID: String?

    private enum CodingKeys: String, CodingKey { case taskid, task_id }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = c.lossyString(.taskid) ?? c.lossyString(.task_id)
    }
}

/// Status of a background task (package upgrade, DSM download).
struct TaskStatusDTO: Decodable, Sendable {
    let finished: Bool
    /// 0…1 or 0…100 depending on the API; normalized in `fraction`.
    let progress: Double?
    let status: String?
    let errorCode: Int?

    private enum CodingKeys: String, CodingKey { case finished, progress, percent, status, error, errcode }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lossyString(.status)
        progress = c.lossyDouble(.progress) ?? c.lossyDouble(.percent)
        errorCode = c.lossyInt(.errcode) ?? (try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .error))?.lossyInt(AnyKey("code"))
        let doneStates: Set<String> = ["finished", "done", "completed", "success"]
        finished = c.lossyBool(.finished) ?? status.map { doneStates.contains($0.lowercased()) } ?? false
    }

    var fraction: Double? {
        guard let progress else { return nil }
        return progress > 1 ? progress / 100 : progress
    }

    var hasFailed: Bool {
        if let errorCode, errorCode != 0 { return true }
        guard let status = status?.lowercased() else { return false }
        return status == "failed" || status == "error"
    }
}

/// SYNO.Docker.Container / list
struct ContainerListDTO: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        let name: String
        let image: String?
        let status: String?
        let exitCode: Int?
        let startedAt: String?
        let project: String?

        private enum CodingKeys: String, CodingKey { case name, image, status, State, exitCode, startedAt, labels }
        private enum StateKeys: String, CodingKey { case Status, ExitCode, StartedAt }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = c.lossyString(.name) else {
                throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "container without name"))
            }
            self.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
            image = c.lossyString(.image)
            let state = try? c.nestedContainer(keyedBy: StateKeys.self, forKey: .State)
            status = c.lossyString(.status) ?? state?.lossyString(.Status)
            exitCode = state?.lossyInt(.ExitCode) ?? c.lossyInt(.exitCode)
            startedAt = state?.lossyString(.StartedAt) ?? c.lossyString(.startedAt)
            let labels = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .labels)
            project = labels?.lossyString(AnyKey("com.docker.compose.project"))
        }
    }

    let containers: [Container]

    private enum CodingKeys: String, CodingKey { case containers }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containers = c.lossyArray(Container.self, .containers)
    }
}

/// SYNO.Docker.Container.Resource / get
struct ContainerResourceDTO: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let name: String
        let cpu: Double?
        let memory: Int64?

        private enum CodingKeys: String, CodingKey { case name, cpu, memory }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            cpu = c.lossyDouble(.cpu)
            memory = c.lossyInt64(.memory)
        }
    }

    let resources: [Resource]

    private enum CodingKeys: String, CodingKey { case resources }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resources = c.lossyArray(Resource.self, .resources)
    }
}

/// SYNO.Docker.Container.Log / get
struct ContainerLogDTO: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        let created: String?
        let stream: String?
        let text: String

        private enum CodingKeys: String, CodingKey { case created, stream, text }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            created = c.lossyString(.created)
            stream = c.lossyString(.stream)
            text = c.lossyString(.text) ?? ""
        }
    }

    let logs: [Line]

    private enum CodingKeys: String, CodingKey { case logs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logs = c.lossyArray(Line.self, .logs)
    }
}

/// SYNO.Docker.Project / list. DSM returns an object keyed by project id.
struct ProjectListDTO: Decodable, Sendable {
    struct Project: Decodable, Sendable {
        let id: String
        let name: String
        let status: String?
        let path: String?
        let containerNames: [String]

        private enum CodingKeys: String, CodingKey { case id, name, status, path, containers }
        private enum ContainerKeys: String, CodingKey { case name, Name }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.lossyString(.id) else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "project without id"))
            }
            self.id = id
            name = c.lossyString(.name) ?? id
            status = c.lossyString(.status)
            path = c.lossyString(.path)
            if let names = try? c.decodeIfPresent([String].self, forKey: .containers) {
                containerNames = names
            } else {
                containerNames = c.lossyArray(NamedContainer.self, .containers).map(\.name)
            }
        }
    }

    struct NamedContainer: Decodable, Sendable {
        let name: String

        private enum CodingKeys: String, CodingKey { case name, Name }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = c.lossyString(.name) ?? c.lossyString(.Name) else {
                throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "container without name"))
            }
            self.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
        }
    }

    let projects: [Project]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        projects = c.allKeys
            .compactMap { (try? c.decode(Lossy<Project>.self, forKey: $0))?.value }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

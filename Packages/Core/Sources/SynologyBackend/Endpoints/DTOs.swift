import Foundation

// Response shapes of the DSM APIs used in phase 1.
// Decoding is deliberately tolerant: unknown fields are ignored, every field is optional
// unless the feature cannot work without it.
//
// IMPORTANT: The fixtures in Tests/SynologyBackendTests/Fixtures are synthetic.
// Replace them with anonymized responses captured from a real DSM 7.2+ before release.

struct LoginResponse: Decodable, Sendable, Equatable {
    let sid: String
    let synoToken: String?
    let deviceID: String?

    private enum CodingKeys: String, CodingKey {
        case sid, synotoken, did, device_id
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid = try c.decode(String.self, forKey: .sid)
        synoToken = c.lossyString(.synotoken)
        let did = c.lossyString(.did) ?? c.lossyString(.device_id)
        deviceID = (did?.isEmpty ?? true) ? nil : did
    }
}

/// SYNO.Core.System / info
struct SystemInfoDTO: Decodable, Sendable {
    let model: String?
    let firmwareVersion: String?
    let upTime: String?
    let temperature: Double?
    let temperatureWarning: Bool?
    let ramSizeMB: Int64?

    private enum CodingKeys: String, CodingKey {
        case model, firmware_ver, up_time, sys_temp, sys_tempwarn, temperature_warning, ram_size
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = c.lossyString(.model)
        firmwareVersion = c.lossyString(.firmware_ver)
        upTime = c.lossyString(.up_time)
        temperature = c.lossyDouble(.sys_temp)
        temperatureWarning = c.lossyBool(.sys_tempwarn) ?? c.lossyBool(.temperature_warning)
        ramSizeMB = c.lossyInt64(.ram_size)
    }
}

/// SYNO.Core.System / info, type=network. Only the interfaces are read.
struct NetworkInfoDTO: Decodable, Sendable {
    struct Interface: Decodable, Sendable {
        let id: String?
        let address: String?
        let mask: String?
        let mac: String?

        private enum CodingKeys: String, CodingKey { case id, addr, ip, mask, netmask, mac, hwaddr }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.id)
            address = c.lossyString(.addr) ?? c.lossyString(.ip)
            mask = c.lossyString(.mask) ?? c.lossyString(.netmask)
            mac = c.lossyString(.mac) ?? c.lossyString(.hwaddr)
        }
    }

    let interfaces: [Interface]

    private enum CodingKeys: String, CodingKey { case nif }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interfaces = (try? c.decode([Interface].self, forKey: .nif)) ?? []
    }
}

/// SYNO.Core.System.Utilization / get
struct UtilizationDTO: Decodable, Sendable {
    struct CPU: Decodable, Sendable {
        let user: Double?
        let system: Double?
        let other: Double?

        private enum CodingKeys: String, CodingKey { case user_load, system_load, other_load }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user = c.lossyDouble(.user_load)
            system = c.lossyDouble(.system_load)
            other = c.lossyDouble(.other_load)
        }
    }

    struct Memory: Decodable, Sendable {
        /// Percent
        let realUsage: Double?
        /// KiB
        let memorySize: Int64?
        let totalReal: Int64?
        let availableReal: Int64?

        private enum CodingKeys: String, CodingKey { case real_usage, memory_size, total_real, avail_real }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            realUsage = c.lossyDouble(.real_usage)
            memorySize = c.lossyInt64(.memory_size)
            totalReal = c.lossyInt64(.total_real)
            availableReal = c.lossyInt64(.avail_real)
        }
    }

    struct Network: Decodable, Sendable {
        let device: String?
        let rx: Double?
        let tx: Double?

        private enum CodingKeys: String, CodingKey { case device, rx, tx }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device = c.lossyString(.device)
            rx = c.lossyDouble(.rx)
            tx = c.lossyDouble(.tx)
        }
    }

    struct Disk: Decodable, Sendable {
        struct Total: Decodable, Sendable {
            let readBytes: Double?
            let writeBytes: Double?

            private enum CodingKeys: String, CodingKey { case read_byte, write_byte }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                readBytes = c.lossyDouble(.read_byte)
                writeBytes = c.lossyDouble(.write_byte)
            }
        }

        let total: Total?
    }

    let cpu: CPU?
    let memory: Memory?
    let network: [Network]
    let disk: Disk?

    private enum CodingKeys: String, CodingKey { case cpu, memory, network, disk }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try? c.decodeIfPresent(CPU.self, forKey: .cpu)
        memory = try? c.decodeIfPresent(Memory.self, forKey: .memory)
        network = c.lossyArray(Network.self, .network)
        disk = try? c.decodeIfPresent(Disk.self, forKey: .disk)
    }
}

/// SYNO.Storage.CGI.Storage / load_info
struct StorageDTO: Decodable, Sendable {
    struct Volume: Decodable, Sendable {
        let id: String
        let path: String?
        let displayName: String?
        let status: String?
        let totalBytes: Int64?
        let usedBytes: Int64?
        let fileSystem: String?

        private enum CodingKeys: String, CodingKey { case id, vol_path, display_name, status, size, fs_type }
        private enum SizeKeys: String, CodingKey { case total, used }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Entries without an id are dropped by `lossyArray`.
            guard let id = c.lossyString(.id) else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "volume without id"))
            }
            self.id = id
            path = c.lossyString(.vol_path)
            displayName = c.lossyString(.display_name)
            status = c.lossyString(.status)
            fileSystem = c.lossyString(.fs_type)
            let size = try? c.nestedContainer(keyedBy: SizeKeys.self, forKey: .size)
            totalBytes = size?.lossyInt64(.total)
            usedBytes = size?.lossyInt64(.used)
        }
    }

    struct Disk: Decodable, Sendable {
        let id: String
        let name: String?
        let longName: String?
        let model: String?
        let temperature: Double?
        let status: String?
        let smartStatus: String?

        private enum CodingKeys: String, CodingKey { case id, name, longName, model, temp, status, smart_status }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.lossyString(.id) else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "disk without id"))
            }
            self.id = id
            name = c.lossyString(.name)
            longName = c.lossyString(.longName)
            model = c.lossyString(.model)
            temperature = c.lossyDouble(.temp)
            status = c.lossyString(.status)
            smartStatus = c.lossyString(.smart_status)
        }
    }

    let volumes: [Volume]
    let disks: [Disk]

    private enum CodingKeys: String, CodingKey { case volumes, disks }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = c.lossyArray(Volume.self, .volumes)
        disks = c.lossyArray(Disk.self, .disks)
    }
}

/// SYNO.Core.Package / list
struct PackageListDTO: Decodable, Sendable {
    struct Package: Decodable, Sendable {
        let id: String
        let name: String?
        let version: String?
        let status: String?
        let description: String?

        private enum CodingKeys: String, CodingKey { case id, name, version, additional }
        private enum AdditionalKeys: String, CodingKey { case status, description }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = c.lossyString(.name)
            version = c.lossyString(.version)
            let additional = try? c.nestedContainer(keyedBy: AdditionalKeys.self, forKey: .additional)
            status = additional?.lossyString(.status)
            description = additional?.lossyString(.description)
        }
    }

    let packages: [Package]

    private enum CodingKeys: String, CodingKey { case packages }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packages = c.lossyArray(Package.self, .packages)
    }
}

/// SYNO.Core.Package.Server / list – packages offered by the package server (UNVERIFIED shape).
struct ServerPackageListDTO: Decodable, Sendable {
    struct Package: Decodable, Sendable {
        let id: String
        let version: String?
        /// Download of the .spk, its MD5 and size: what Package Center hands to `Installation/install`.
        let link: String?
        let md5: String?
        let size: Int64?

        private enum CodingKeys: String, CodingKey { case id, version, link, md5, size }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            version = c.lossyString(.version)
            link = c.lossyString(.link).flatMap { $0.isEmpty ? nil : $0 }
            md5 = c.lossyString(.md5)
            size = c.lossyInt64(.size)
        }
    }

    let packages: [Package]

    private enum CodingKeys: String, CodingKey { case packages }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packages = c.lossyArray(Package.self, .packages)
    }
}

/// SYNO.Core.Upgrade.Server / check (UNVERIFIED shape)
struct UpgradeCheckDTO: Decodable, Sendable {
    let available: Bool
    let version: String?
    let reboot: String?

    private enum CodingKeys: String, CodingKey { case available, update, version, reboot }
    private enum UpdateKeys: String, CodingKey { case available, version, reboot }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let update = try? c.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update)
        available = update?.lossyBool(.available) ?? c.lossyBool(.available) ?? false
        version = update?.lossyString(.version) ?? c.lossyString(.version)
        reboot = update?.lossyString(.reboot) ?? c.lossyString(.reboot)
    }
}

/// SYNO.Core.SyslogClient.Log / list (UNVERIFIED parameters)
struct LogListDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let message: String?
        let level: String?
        let logType: String?
        let time: String?
        let who: String?

        private enum CodingKeys: String, CodingKey { case descr, event, level, logtype, time, who, user }

        // Field names differ between DSM versions / clients: descr or event, who or user.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = c.lossyString(.descr) ?? c.lossyString(.event)
            level = c.lossyString(.level)
            logType = c.lossyString(.logtype)
            time = c.lossyString(.time)
            who = c.lossyString(.who) ?? c.lossyString(.user)
        }
    }

    let items: [Item]
    let total: Int?

    private enum CodingKeys: String, CodingKey { case items, logs, total }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = c.lossyArray(Item.self, .items)
        self.items = items.isEmpty ? c.lossyArray(Item.self, .logs) : items
        total = c.lossyInt(.total)
    }
}

/// SYNO.SDS.Backup.Client.Common.Log / list (UNVERIFIED, shape from open-source clients).
struct BackupLogListDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let event: String?
        let level: String?
        let time: String?
        let user: String?

        private enum CodingKeys: String, CodingKey { case event, descr, level, time, user, who }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = c.lossyString(.event) ?? c.lossyString(.descr)
            level = c.lossyString(.level)
            time = c.lossyString(.time)
            user = c.lossyString(.user) ?? c.lossyString(.who)
        }
    }

    let items: [Item]
    let total: Int?

    private enum CodingKeys: String, CodingKey { case log_list, total, info_count, warn_count, error_count }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lossyArray(Item.self, .log_list)
        total = c.lossyInt(.total)
    }
}

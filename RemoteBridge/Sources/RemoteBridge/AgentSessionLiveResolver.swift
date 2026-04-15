import Darwin
import Foundation

struct AgentPanelProcessSnapshot: Sendable, Equatable {
    let workspaceID: String
    let panelID: String
    let effectiveShellPID: Int32?
}

struct AgentSessionResolvedLocation: Sendable, Equatable {
    let workspaceID: String
    let panelID: String
}

struct ResolvedPanelKey: Hashable, Sendable {
    let workspaceID: String
    let panelID: String
}

struct AgentSessionLiveResolutionState: Sendable, Equatable {
    let resolvedLocationsBySessionID: [String: AgentSessionResolvedLocation]
    let sessionIDByResolvedPanelKey: [ResolvedPanelKey: String]
}

enum AgentSessionLiveResolver {
    static func resolve(recordsBySessionID: [String: AgentSessionRegistryRecord],
                        panelsByWorkspaceID: [String: [AgentPanelProcessSnapshot]],
                        processParentPIDMap: [Int32: Int32]) -> AgentSessionLiveResolutionState {
        var locationsByRootPID = [Int32: AgentSessionResolvedLocation]()
        for panels in panelsByWorkspaceID.values {
            for panel in panels {
                guard let pid = panel.effectiveShellPID, pid > 0 else {
                    continue
                }
                locationsByRootPID[pid] = AgentSessionResolvedLocation(workspaceID: panel.workspaceID,
                                                                       panelID: panel.panelID)
            }
        }

        let sortedRecords = recordsBySessionID.values.sorted(by: sortRecordsNewestFirst)
        var resolvedLocationsBySessionID = [String: AgentSessionResolvedLocation]()
        var sessionIDByResolvedPanelKey = [ResolvedPanelKey: String]()

        for record in sortedRecords {
            guard let resolvedLocation = resolvedLocation(forPID: record.pid,
                                                          locationsByRootPID: locationsByRootPID,
                                                          processParentPIDMap: processParentPIDMap) else {
                continue
            }
            resolvedLocationsBySessionID[record.sessionID] = resolvedLocation
            let panelKey = ResolvedPanelKey(workspaceID: resolvedLocation.workspaceID,
                                            panelID: resolvedLocation.panelID)
            sessionIDByResolvedPanelKey[panelKey] = sessionIDByResolvedPanelKey[panelKey] ?? record.sessionID
        }

        return AgentSessionLiveResolutionState(resolvedLocationsBySessionID: resolvedLocationsBySessionID,
                                               sessionIDByResolvedPanelKey: sessionIDByResolvedPanelKey)
    }

    static func processParentPIDMapFromSystem() -> [Int32: Int32] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else {
            return [:]
        }

        let count = Int(bufferSize) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: count)
        let bytesReturned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard bytesReturned > 0 else {
            return [:]
        }

        let validCount = Int(bytesReturned) / MemoryLayout<pid_t>.stride
        var processParentPIDMap = [Int32: Int32]()
        processParentPIDMap.reserveCapacity(validCount)

        for pid in pids.prefix(validCount) where pid > 0 {
            var info = proc_bsdshortinfo()
            let rc = proc_pidinfo(pid,
                                  PROC_PIDT_SHORTBSDINFO,
                                  0,
                                  &info,
                                  Int32(MemoryLayout<proc_bsdshortinfo>.stride))
            guard rc == Int32(MemoryLayout<proc_bsdshortinfo>.stride) else {
                continue
            }
            guard let parentPID = Int32(exactly: info.pbsi_ppid) else {
                continue
            }
            processParentPIDMap[pid] = parentPID
        }

        return processParentPIDMap
    }

    private static func resolvedLocation(forPID pid: Int32,
                                         locationsByRootPID: [Int32: AgentSessionResolvedLocation],
                                         processParentPIDMap: [Int32: Int32]) -> AgentSessionResolvedLocation? {
        guard pid > 0 else {
            return nil
        }

        var currentPID = pid
        var visited = Set<Int32>()
        while currentPID > 0 && visited.insert(currentPID).inserted {
            if let location = locationsByRootPID[currentPID] {
                return location
            }
            guard let parentPID = processParentPIDMap[currentPID], parentPID > 0 else {
                return nil
            }
            currentPID = parentPID
        }

        return nil
    }

    private static func sortRecordsNewestFirst(_ lhs: AgentSessionRegistryRecord,
                                               _ rhs: AgentSessionRegistryRecord) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.sessionID < rhs.sessionID
        }
        return lhs.createdAt > rhs.createdAt
    }
}

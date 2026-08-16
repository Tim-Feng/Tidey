import Foundation

struct BridgeVideoPreviewActionResult {
    let response: BridgeResponse
    let registeredPrepareID: String?
    let closedPrepareID: String?
    let deviceID: String?

    init(response: BridgeResponse,
         registeredPrepareID: String? = nil,
         closedPrepareID: String? = nil,
         deviceID: String? = nil) {
        self.response = response
        self.registeredPrepareID = registeredPrepareID
        self.closedPrepareID = closedPrepareID
        self.deviceID = deviceID
    }
}

/// Event-loop-owned connection state. It records only prepare identifiers;
/// the registry remains the descriptor owner. A result that arrives after
/// socket loss is revoked before it can be published.
final class BridgeVideoPreviewConnectionLeaseTracker {
    private let deviceID: String
    private let leaseRegistry: BridgeMediaLeaseRegistry
    private var prepareIDs = Set<String>()

    init(deviceID: String, leaseRegistry: BridgeMediaLeaseRegistry) {
        self.deviceID = deviceID
        self.leaseRegistry = leaseRegistry
    }

    @discardableResult
    func accept(_ result: BridgeVideoPreviewActionResult,
                connectionIsActive: Bool) -> Bool {
        if let prepareID = result.registeredPrepareID {
            guard result.deviceID == deviceID, connectionIsActive else {
                if let resultDeviceID = result.deviceID {
                    leaseRegistry.close(prepareID: prepareID, deviceID: resultDeviceID)
                }
                return false
            }
            prepareIDs.insert(prepareID)
        }
        if let prepareID = result.closedPrepareID {
            prepareIDs.remove(prepareID)
        }
        return connectionIsActive
    }

    func retire() {
        for prepareID in prepareIDs {
            leaseRegistry.close(prepareID: prepareID, deviceID: deviceID)
        }
        prepareIDs.removeAll(keepingCapacity: false)
    }
}

struct BridgeVideoPreviewActionHandler {
    typealias Prepare = (_ path: String,
                         _ workspaceID: String,
                         _ panelID: String) async throws -> BridgeVideoPreparedSource

    private let leaseRegistry: BridgeMediaLeaseRegistry
    private let prepareIDGenerator: () -> String
    private let prepare: Prepare

    init(leaseRegistry: BridgeMediaLeaseRegistry,
         prepareIDGenerator: @escaping () -> String = { UUID().uuidString },
         prepare: @escaping Prepare) {
        self.leaseRegistry = leaseRegistry
        self.prepareIDGenerator = prepareIDGenerator
        self.prepare = prepare
    }

    static func live(rootResolver: PanelFileRootResolving,
                     leaseRegistry: BridgeMediaLeaseRegistry) -> BridgeVideoPreviewActionHandler {
        let handler = BridgeVideoPrepareHandler(rootResolver: rootResolver)
        return BridgeVideoPreviewActionHandler(leaseRegistry: leaseRegistry) { path, workspaceID, panelID in
            try await handler.prepare(path: path, workspaceID: workspaceID, panelID: panelID)
        }
    }

    func handles(_ request: BridgeRequest) -> Bool {
        request.action == BridgeVideoPreviewProtocolV1.prepareAction
            || request.action == BridgeVideoPreviewProtocolV1.closeAction
    }

    func handle(_ request: BridgeRequest,
                principal: BridgeAuthenticatedPrincipal?) async -> BridgeVideoPreviewActionResult? {
        guard handles(request) else {
            return nil
        }
        guard case .device(let deviceID) = principal else {
            return BridgeVideoPreviewActionResult(
                response: BridgeResponse(id: request.id,
                                         ok: false,
                                         result: nil,
                                         error: BridgeInternalError.unauthorized.payload)
            )
        }

        if request.action == BridgeVideoPreviewProtocolV1.closeAction {
            return close(request, deviceID: deviceID)
        }
        return await prepare(request, deviceID: deviceID)
    }

    private func close(_ request: BridgeRequest,
                       deviceID: String) -> BridgeVideoPreviewActionResult {
        guard let prepareID = request.params?["prepare_id"]?.stringValue,
              !prepareID.isEmpty else {
            return errorResponse(request,
                                 error: .invalidRequest("video_close requires prepare_id"))
        }
        let didClose = leaseRegistry.close(prepareID: prepareID, deviceID: deviceID)
        return BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: request.id,
                                     ok: true,
                                     result: [
                                        "prepare_id": .string(prepareID),
                                        "closed": .bool(didClose),
                                     ],
                                     error: nil),
            closedPrepareID: prepareID,
            deviceID: deviceID
        )
    }

    private func prepare(_ request: BridgeRequest,
                         deviceID: String) async -> BridgeVideoPreviewActionResult {
        guard let params = request.params,
              let workspaceID = params["workspace_id"]?.stringValue,
              let panelID = params["panel_id"]?.stringValue,
              let path = params["path"]?.stringValue,
              !workspaceID.isEmpty,
              !panelID.isEmpty,
              !path.isEmpty else {
            return errorResponse(request,
                                 error: .invalidRequest("video_prepare requires workspace_id, panel_id, and path"))
        }

        let prepareID = prepareIDGenerator()
        do {
            let prepared = try await prepare(path, workspaceID, panelID)
            switch prepared.result.route {
            case .direct:
                guard let openedFile = prepared.openedFile else {
                    return failedResponse(request,
                                          prepareID: prepareID,
                                          code: "invalid_response",
                                          message: "Bridge 無法建立影片讀取權限。")
                }
                do {
                    let grant = try leaseRegistry.register(openedFile: openedFile,
                                                           deviceID: deviceID,
                                                           prepareID: prepareID,
                                                           mime: prepared.result.mime)
                    return readyResponse(request,
                                         prepared: prepared.result,
                                         grant: grant,
                                         deviceID: deviceID)
                } catch {
                    openedFile.close()
                    throw error
                }
            case .transcode, .remux:
                prepared.openedFile?.close()
                return stateResponse(request,
                                     prepareID: prepareID,
                                     state: .conversionRequired,
                                     route: prepared.result.route,
                                     code: "conversion_required",
                                     message: "這個影片需要先在 Mac 轉成相容格式；目前版本尚未提供轉檔。")
            case .unsupported:
                prepared.openedFile?.close()
                return stateResponse(request,
                                     prepareID: prepareID,
                                     state: .unsupported,
                                     route: .unsupported,
                                     code: "unsupported",
                                     message: "這個影片目前無法預覽。")
            }
        } catch let error as BridgeInternalError {
            return failedResponse(request,
                                  prepareID: prepareID,
                                  code: error.payload.code,
                                  message: error.payload.message)
        } catch let error as BridgeMediaLeaseRegistryError {
            let code: String
            let message: String
            switch error {
            case .capacityExceeded:
                code = "resource_busy"
                message = "目前開啟的影片預覽已達上限，請先關閉其他影片。"
            case .secureTokenUnavailable, .tokenCollision:
                code = "lease_unavailable"
                message = "目前無法建立影片讀取權限，請稍後再試。"
            }
            return failedResponse(request, prepareID: prepareID, code: code, message: message)
        } catch {
            return failedResponse(request,
                                  prepareID: prepareID,
                                  code: "bridge_error",
                                  message: "Bridge 無法準備這個影片。")
        }
    }

    private func readyResponse(_ request: BridgeRequest,
                               prepared: BridgeVideoProbeResult,
                               grant: BridgeMediaLeaseGrant,
                               deviceID: String) -> BridgeVideoPreviewActionResult {
        let duration = UInt64(max(0, prepared.durationMS.rounded()))
        return BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: request.id,
                                     ok: true,
                                     result: [
                                        "prepare_id": .string(grant.prepareID),
                                        "state": .string(BridgeVideoPreviewState.ready.rawValue),
                                        "route": .string(BridgeVideoPreviewRoute.direct.rawValue),
                                        "lease_path": .string(grant.leasePath),
                                        "mime": .string(grant.mime),
                                        "size": .number(Double(grant.size)),
                                        "duration_ms": .number(Double(duration)),
                                        "has_audio": .bool(prepared.hasAudio),
                                        "expires_at": .string(ISO8601DateFormatter().string(from: grant.expiresAt)),
                                        "accepts_ranges": .bool(true),
                                     ],
                                     error: nil),
            registeredPrepareID: grant.prepareID,
            deviceID: deviceID
        )
    }

    private func stateResponse(_ request: BridgeRequest,
                               prepareID: String,
                               state: BridgeVideoPreviewState,
                               route: BridgeVideoPreviewRoute,
                               code: String,
                               message: String) -> BridgeVideoPreviewActionResult {
        BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: request.id,
                                     ok: true,
                                     result: [
                                        "prepare_id": .string(prepareID),
                                        "state": .string(state.rawValue),
                                        "route": .string(route.rawValue),
                                        "code": .string(code),
                                        "message": .string(message),
                                     ],
                                     error: nil)
        )
    }

    private func failedResponse(_ request: BridgeRequest,
                                prepareID: String,
                                code: String,
                                message: String) -> BridgeVideoPreviewActionResult {
        stateResponse(request,
                      prepareID: prepareID,
                      state: .failed,
                      route: .unsupported,
                      code: code,
                      message: message)
    }

    private func errorResponse(_ request: BridgeRequest,
                               error: BridgeInternalError) -> BridgeVideoPreviewActionResult {
        BridgeVideoPreviewActionResult(
            response: BridgeResponse(id: request.id,
                                     ok: false,
                                     result: nil,
                                     error: error.payload)
        )
    }
}

import Foundation

@objc(TideyShellIntegrationInstallPlan)
@objcMembers
final class TideyShellIntegrationInstallPlan: NSObject {
    let shellExtension: String
    let configFile: String
    let destinationPath: String
    let sourceLine: String

    init(shellExtension: String,
         configFile: String,
         destinationPath: String,
         sourceLine: String) {
        self.shellExtension = shellExtension
        self.configFile = configFile
        self.destinationPath = destinationPath
        self.sourceLine = sourceLine
    }
}

@objc(TideyShellIntegrationConfigWriter)
@objcMembers
final class TideyShellIntegrationConfigWriter: NSObject {
    static func installPlan(forShell shell: String,
                            environment: [String: String],
                            homeDirectory: String,
                            bashProfileExists: Bool) -> TideyShellIntegrationInstallPlan? {
        let shellName = (shell as NSString).lastPathComponent
        let shellExtension: String
        let configFile: String

        switch shellName {
        case "zsh":
            let baseDirectory = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory
            shellExtension = "zsh"
            configFile = (baseDirectory as NSString).appendingPathComponent(".zshrc")
        case "bash":
            shellExtension = "bash"
            if bashProfileExists {
                configFile = (homeDirectory as NSString).appendingPathComponent(".bash_profile")
            } else {
                configFile = (homeDirectory as NSString).appendingPathComponent(".profile")
            }
        case "fish":
            shellExtension = "fish"
            configFile = (homeDirectory as NSString).appendingPathComponent(".config/fish/config.fish")
        default:
            return nil
        }

        let destinationPath = (homeDirectory as NSString).appendingPathComponent(".iterm2_shell_integration.\(shellExtension)")
        let sourceLine: String
        if shellExtension == "fish" {
            let shellPath = "$HOME/.iterm2_shell_integration.\(shellExtension)"
            sourceLine = "\n# Tidey shell integration\ntest -e \(shellPath); and source \(shellPath); or true\n"
        } else {
            let shellPath = "\"${HOME}/.iterm2_shell_integration.\(shellExtension)\""
            sourceLine = "\n# Tidey shell integration\ntest -e \(shellPath) && source \(shellPath)\n"
        }

        return TideyShellIntegrationInstallPlan(shellExtension: shellExtension,
                                                configFile: configFile,
                                                destinationPath: destinationPath,
                                                sourceLine: sourceLine)
    }

    @objc(configContainsInstallationMarkerInContents:)
    static func configContainsInstallationMarker(in contents: String) -> Bool {
        contents.contains("iterm2_shell_integration")
    }

    @objc(appendSourceLineForPlan:error:)
    static func appendSourceLine(for plan: TideyShellIntegrationInstallPlan,
                                 error outError: NSErrorPointer) -> Bool {
        let fileManager = FileManager.default
        let configDirectory = (plan.configFile as NSString).deletingLastPathComponent

        do {
            try fileManager.createDirectory(atPath: configDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: nil)

            if !fileManager.fileExists(atPath: plan.configFile) {
                let created = fileManager.createFile(atPath: plan.configFile,
                                                     contents: nil,
                                                     attributes: nil)
                if !created {
                    let nsError = NSError(domain: NSPOSIXErrorDomain,
                                          code: Int(EIO),
                                          userInfo: [
                                            NSLocalizedDescriptionKey: "Could not create \(plan.configFile)."
                                          ])
                    outError?.pointee = nsError
                    return false
                }
            }

            let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: plan.configFile))
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            if let data = plan.sourceLine.data(using: .utf8) {
                fileHandle.write(data)
            }
            return true
        } catch let caughtError {
            outError?.pointee = caughtError as NSError
            return false
        }
    }
}

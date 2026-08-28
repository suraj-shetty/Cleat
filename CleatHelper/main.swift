import Foundation

// The helper only ever runs as a launchd daemon started by SMAppService. Running
// it by hand would sit forever on a Mach service it cannot check in for, so bail
// out with a clear message instead.
guard getuid() == 0 else {
    FileHandle.standardError.write(Data("""
    CleatHelper is a privileged launchd daemon and is registered by Cleat.app.
    It is not meant to be run directly.

    """.utf8))
    exit(EXIT_FAILURE)
}

let service = HelperService()
service.run()

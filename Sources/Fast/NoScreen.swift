import Darwin

// The browser needs the window server, and AppKit aborts without it, in
// _RegisterApplication, before a line of Yab runs: an agent's sandbox
// (Codex's seatbelt denies the window server's and LaunchServices' names) or
// an ssh login (a session with no graphic access) took `yab` down there with
// SIGABRT, crash #34. Asked before AppKit, so such a launch says where to go
// and leaves. Both questions cost microseconds, nothing a normal launch feels.
enum NoScreen {
    static var here: Bool {
        var audit = auditinfo_addr()
        if getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0,
           audit.ai_flags & UInt64(AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS.rawValue) == 0 { return true }
        var port: mach_port_t = 0
        guard bootstrap_look_up(bootstrap_port, "com.apple.windowserver.active", &port) == KERN_SUCCESS else { return true }
        mach_port_deallocate(mach_task_self_, port)
        return false
    }

    static func leave() -> Never {
        let line = "\(AgentSetup.command): the browser can't open here, there is no screen to draw on (a sandbox or an ssh login).\n"
            + "Ask \(Brand.name) from here with `\(AgentSetup.command) \"task\"`, give an agent its tools with `\(AgentSetup.command) mcp`, or see `\(AgentSetup.command) help`.\n"
        fputs(line, stderr)
        exit(69)  // EX_UNAVAILABLE
    }
}

@_silgen_name("bootstrap_look_up")
private func bootstrap_look_up(_ bp: mach_port_t, _ name: UnsafePointer<CChar>, _ sp: UnsafeMutablePointer<mach_port_t>) -> kern_return_t

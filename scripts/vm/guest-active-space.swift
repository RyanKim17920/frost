// Run inside the guest's GUI session: prints the ID of the active Space (desktop), to tell desktops apart when they
// share a wallpaper (`docs/testing-vm.md`, "Spaces"). Uses private CoreGraphics calls; for VM testing only.
//   swiftc -O /tmp/guest-active-space.swift -o /tmp/guest-active-space
//   scripts/vm/vm-exec.sh --gui /tmp/guest-active-space
import Foundation

typealias MainConnectionID = @convention(c) () -> Int32
typealias GetActiveSpace = @convention(c) (Int32) -> UInt64

guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
      let connection = dlsym(cg, "CGSMainConnectionID"), let active = dlsym(cg, "CGSGetActiveSpace")
else {
    print("CoreGraphics Space calls not found")
    exit(1)
}
let mainConnection = unsafeBitCast(connection, to: MainConnectionID.self)
let activeSpace = unsafeBitCast(active, to: GetActiveSpace.self)
print("active space:", activeSpace(mainConnection()))

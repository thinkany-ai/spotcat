import AppKit

let screens: [CGRect] = [
    CGRect(x: 0, y: 80, width: 1440, height: 790),
    CGRect(x: -1920, y: 40, width: 1920, height: 1010),
    CGRect(x: 2560, y: -1080, width: 1920, height: 1040),
    CGRect(x: 0, y: 0, width: 600, height: 300),
    CGRect(x: 0, y: 0, width: 5120, height: 2800),
    CGRect(x: 0, y: 0, width: 100, height: 100),
]
for screen in screens {
    let frame = ClipboardShelfLayout.frame(in: screen)
    precondition(screen.contains(frame), "Shelf must remain inside visible screen")
    precondition(frame.width <= 1440 && frame.height <= 520)
    precondition(frame.width > 0 && frame.height > 0)
    precondition(abs(frame.midX - screen.midX) < 0.001)
    precondition(frame.minY > screen.minY)
}
print("PASS: bottom shelf geometry on 6 screen layouts")

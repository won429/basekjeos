import Foundation

@main
struct NotchAlertSizingChecks {
    static func main() {
        for camera: CGFloat in [0, 180, 210] {
            let music: CGFloat = camera == 0 ? 204 : 320
            let sizes = NotchAlertSizing.widths(musicWidth: music, cameraWidth: camera, screenWidth: 1440)
            let center = NotchAlertSizing.protectedCenter(cameraWidth: camera)
            precondition(sizes.power > music && sizes.airPods > music)
            precondition((sizes.power - center) / 2 >= 120)
            precondition((sizes.airPods - center) / 2 >= 96)
            precondition(sizes.power <= 1416 && sizes.airPods <= 1416)
        }
        for scale: CGFloat in [0.45, 0.75, 1] {
            for camera: CGFloat in [0, 180, 210] {
                let center = NotchAlertSizing.protectedCenter(cameraWidth: max(camera, 126 * scale))
                let music = max(camera, 126 * scale) + 64 * scale
                let width = NotchAlertSizing.volumeWidth(musicWidth: music, protectedCenter: center,
                                                         scale: scale, screenWidth: 1440)
                precondition(width > music)
                precondition((width - center) / 2 - 18 * scale >= 76 * scale - 0.001)
            }
        }
        let small = NotchAlertSizing.widths(musicWidth: 320, cameraWidth: 210, screenWidth: 400)
        precondition(small.power <= 376 && small.airPods <= 376)
        precondition(NotchAlertSizing.protectedCenter(cameraWidth: 0) == 0)
        print("Notch alert widths passed: real/virtual notch, camera clearance, larger wings, screen limit")
    }
}

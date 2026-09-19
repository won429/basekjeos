import Foundation

enum NotchAlertSizing {
    static func protectedCenter(cameraWidth: CGFloat) -> CGFloat {
        cameraWidth > 0 ? cameraWidth + 16 : 0
    }

    static func volumeWidth(musicWidth: CGFloat, protectedCenter: CGFloat,
                            scale: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(max(1, screenWidth - 24),
            max(musicWidth + 48 * scale, protectedCenter + 2 * (26 + 76) * scale))
    }

    static func widths(musicWidth: CGFloat, cameraWidth: CGFloat,
                       screenWidth: CGFloat) -> (power: CGFloat, airPods: CGFloat) {
        let center = protectedCenter(cameraWidth: cameraWidth)
        let limit = max(1, screenWidth - 24)
        return (min(limit, max(musicWidth + 64, center + 240, 284)),
                min(limit, max(musicWidth + 48, center + 224, 288)))
    }
}

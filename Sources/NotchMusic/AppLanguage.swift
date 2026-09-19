import Foundation

enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("ko") == true
            ? .korean
            : .english
    }

    var title: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        }
    }

    func chargingStatus(isConnected: Bool) -> String {
        switch (self, isConnected) {
        case (.korean, true): return "충전중"
        case (.korean, false): return "충전종료"
        case (.english, true): return "Charging"
        case (.english, false): return "Not Charging"
        }
    }

    var airPodsConnectedStatus: String {
        switch self {
        case .korean: return "연결됨"
        case .english: return "Connected"
        }
    }

    var batteryLevelStatus: String {
        self == .korean ? "배터리 잔량" : "Battery"
    }

    var lowBatteryStatus: String { self == .korean ? "배터리 부족" : "Low Battery" }
    func batteryDetailTitle(_ percentage: Int) -> String {
        self == .korean ? "배터리 \(percentage)%" : "\(percentage)% Battery"
    }
    var lowPowerPrompt: String {
        self == .korean ? "저전력 모드를 켜려면 클릭하십시오." : "Click to turn on Low Power Mode."
    }
    var lowPowerActive: String {
        self == .korean ? "저전력 모드가 활성화됨" : "Low Power Mode is on"
    }
    var lowPowerChanging: String {
        self == .korean ? "저전력 모드 변경 중…" : "Changing Low Power Mode…"
    }
    var lowPowerFailed: String {
        self == .korean ? "변경하지 못했습니다. 설정 열기" : "Couldn’t change mode. Open settings"
    }
    var lowPowerSettingsHint: String {
        self == .korean ? "탭하여 저전력 모드 설정 열기" : "Tap to open Low Power Mode settings"
    }

    func chargingAccessibilityLabel(isConnected: Bool, percentage: Int) -> String {
        switch (self, isConnected) {
        case (.korean, true): return "충전 중 \(percentage)퍼센트"
        case (.korean, false): return "충전 종료 \(percentage)퍼센트"
        case (.english, true): return "Charging, \(percentage) percent"
        case (.english, false): return "Not charging, \(percentage) percent"
        }
    }

    func airPodsAccessibilityDescription(
        name: String,
        unitBattery: Int?,
        leftBattery: Int?,
        rightBattery: Int?
    ) -> String {
        switch self {
        case .korean:
            let unit = unitBattery.map { "유닛 배터리 \($0)퍼센트" }
                ?? "유닛 배터리 정보 없음"
            let sides = [
                leftBattery.map { "왼쪽 \($0)퍼센트" },
                rightBattery.map { "오른쪽 \($0)퍼센트" }
            ].compactMap { $0 }.joined(separator: ", ")
            return "\(name) 연결됨, \(unit)" + (sides.isEmpty ? "" : ", \(sides)")
        case .english:
            let unit = unitBattery.map { "AirPods battery \($0) percent" }
                ?? "AirPods battery unavailable"
            let sides = [
                leftBattery.map { "left \($0) percent" },
                rightBattery.map { "right \($0) percent" }
            ].compactMap { $0 }.joined(separator: ", ")
            return "\(name) connected, \(unit)" + (sides.isEmpty ? "" : ", \(sides)")
        }
    }
}

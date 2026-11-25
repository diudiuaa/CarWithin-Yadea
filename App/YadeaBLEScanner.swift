import CoreBluetooth
import Foundation

/// 蓝牙诊断：车把／仪表按键到底走 Wi-Fi 还是走蓝牙，一直只有猜测，没有证据。
///
/// 投屏期间顺手被动扫一遍附近的 BLE 设备：发现 → 连接 → 列服务与特征值 →
/// 对所有 notify 特征值打日志。按下去如果这里冒出新的十六进制行，说明按键确实走蓝牙，
/// 那就可以照这串做映射；如果一切安静，说明按键只可能从仪表那条 TCP 上来（见 YadeaOutput）。
final class YadeaBLEScanner: NSObject {
    private var central: CBCentralManager?
    private var log: (String) -> Void = { _ in }
    private var running = false
    /// 已经报过的设备，避免同一台反复刷。
    private var seenDevices: Set<String> = []
    /// 已经报过的上行数据，避免 notify 每秒刷屏。
    private var seenValues: Set<String> = []
    private var connecting: Set<UUID> = []

    func start(log: @escaping (String) -> Void) {
        guard !running else { return }
        running = true
        self.log = log
        log(CWL("蓝牙诊断：开始扫描附近设备；投屏时按下车把按键，若这里出现新行说明按键走蓝牙。"))
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func stop() {
        guard running else { return }
        running = false
        central?.stopScan()
        central = nil
        connecting.removeAll()
    }
}

extension YadeaBLEScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            log(CWL("蓝牙诊断：App 没有蓝牙权限，请到系统设置里允许。"))
        case .poweredOff:
            log(CWL("蓝牙诊断：系统蓝牙未打开。"))
        case .unsupported:
            log(CWL("蓝牙诊断：本机不支持蓝牙。"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "未命名"
        let key = peripheral.identifier.uuidString + "|" + name
        if seenDevices.insert(key).inserted {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map(\.uuidString).joined(separator: ",") ?? "-"
            log(CWL("蓝牙诊断：发现 {1} · 信号 {2} · 广播服务 {3}",
                    [name, "\(RSSI)", services]))
        }
        // 最多同时挂 6 台，避免把附近所有设备的通知都拉进来
        guard connecting.count < 6, connecting.insert(peripheral.identifier).inserted else { return }
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log(CWL("蓝牙诊断：已连接 {1}，读取服务…",
                [peripheral.name ?? peripheral.identifier.uuidString]))
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error {
            log(CWL("蓝牙诊断：连接 {1} 失败：{2}",
                    [peripheral.name ?? "设备", error.localizedDescription]))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            log(CWL("蓝牙诊断：{1} 已断开：{2}",
                    [peripheral.name ?? "设备", error.localizedDescription]))
        }
    }
}

extension YadeaBLEScanner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            log(CWL("蓝牙诊断：{1} 没有可读服务。", [peripheral.name ?? "设备"]))
            return
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        if characteristics.isEmpty {
            log(CWL("蓝牙诊断：服务 {1} 没有特征值。", [service.uuid.uuidString]))
            return
        }
        for characteristic in characteristics {
            let properties = characteristic.properties
            guard properties.contains(.notify) || properties.contains(.indicate) else { continue }
            peripheral.setNotifyValue(true, for: characteristic)
            log(CWL("蓝牙诊断：订阅通知 {1} / {2}",
                    [service.uuid.uuidString, characteristic.uuid.uuidString]))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log(CWL("蓝牙诊断：订阅失败 {1}：{2}",
                    [characteristic.uuid.uuidString, error.localizedDescription]))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        guard seenValues.insert(characteristic.uuid.uuidString + " " + hex).inserted else { return }
        log(CWL("蓝牙按键数据 {1}（{2}）", [hex, characteristic.uuid.uuidString]))
    }
}

//
//  Receiver.swift
//  C19X
//
//  Created by Freddy Choi on 24/03/2020.
//  Copyright © 2020 C19X. All rights reserved.
//

import Foundation
import CoreBluetooth
import os

/**
 Beacon receiver scans for peripherals with fixed service UUID.
 */
protocol Receiver {
    /// Delegates for receiving beacon detection events.
    var delegates: [ReceiverDelegate] { get set }
    
    /**
     Create a receiver that uses the same sequential dispatch queue as the transmitter.
     */
    init(queue: DispatchQueue)
    
    /**
     Start receiver. The actual start is triggered by bluetooth state changes.
     */
    func start(_ source: String)
    
    /**
     Stop and resets receiver.
     */
    func stop(_ source: String)
    
    /**
     Scan for beacons. This is normally called when bluetooth powers on, but also called by
     background app refresh task in the AppDelegate as backup for keeping the receiver awake.
     */
    func scan(_ source: String)
}

/**
 RSSI in dBm.
 */
typealias RSSI = Int

/**
 Beacon receiver delegate listens for beacon detection events (beacon code, rssi).
 */
protocol ReceiverDelegate {
    /**
     Beacon code has been detected.
     */
    func receiver(didDetect: BeaconCode, rssi: RSSI)
    
    /**
     Receiver did update state.
     */
    func receiver(didUpdateState: CBManagerState)
}

/**
 Operating system type is either Android or iOS. The distinction is necessary as the
 two are handled very differently to reduce chance of error (Android) and ensure
 background scanning works (iOS).
 */
enum OperatingSystem {
    case android
    case ios
}

/**
 Beacon peripheral for collating information (beacon code) acquired from asynchronous callbacks.
 */
class Beacon {
    /// Peripheral underpinning the beacon.
    var peripheral: CBPeripheral {
        didSet { lastUpdatedAt = Date() }
    }
    /**
     Operating system (Android | iOS) distinguished by whether the beacon characteristic supports
     notify (iOS only). Android devices are discoverable by iOS in all circumstances, thus a connect
     if only required on first contact, or after Android BLE address change which makes the peripheral
     appear as a new peripheral. While the beacon code does change on the Android side, the fact
     that the BLE address is constant makes it unnecessary to reconnect to get the latest code, i.e.
     no security benefit. iOS on the other hand requires an open connection with another iOS device
     to ensure background scan (via writeValue to Transmitter, delay on Transmitter, then receive
     didUpdateValueFor, which triggers readRSSI) continues to function when both devices are in
     background mode.
     */
    var operatingSystem: OperatingSystem? {
        didSet { lastUpdatedAt = Date() }
    }
    /// Notifying beacon characteristic (iOS peripherals only).
    var characteristic: CBCharacteristic? {
        didSet { lastUpdatedAt = Date() }
    }
    /// RSSI value obtained from either scanForPeripheral or readRSSI.
    var rssi: RSSI? {
        didSet { lastUpdatedAt = Date() }
    }
    /// Beacon code obtained from the lower 64-bits of the beacon characteristic UUID.
    var code: BeaconCode? {
        didSet {
            lastUpdatedAt = Date()
            codeUpdatedAt = Date()
        }
    }
    /**
     Last update timestamp for beacon code. Need to track this to invalidate codes from
     yesterday. It is unnecessary to invalidate old codes obtained during a day as the fact
     that the BLE address is constant (Android) or the connection is open (iOS) means
     changing the code will offer no security benefit, but increases connection failure risks,
     especially for Android devices.
     */
    private var codeUpdatedAt = Date.distantPast
    /**
     Last update timestamp for any beacon information. Need to track this to invalidate
     peripherals that have not been seen for a long time to avoid holding on to an ever
     growing table of beacons and pending connections to iOS devices. Invalidated
     beacons can be discovered again in the future by scan instead.
     */
    private var lastUpdatedAt = Date.distantPast
    /// Track connection interval and up time statistics for this beacon, for debug purposes.
    let statistics = TimeIntervalSample()
    
    /**
     Beacon identifier is the same as the peripheral identifier.
     */
    var uuidString: String { get { peripheral.identifier.uuidString } }
    /**
     Beacon is ready if all the information is available (operatingSystem, RSSI, code), and
     the code was acquired today (day code changes at midnight everyday).
     */
    var isReady: Bool { get {
        guard operatingSystem != nil, code != nil, rssi != nil else {
            return false
        }
        let today = UInt64(Date().timeIntervalSince1970).dividedReportingOverflow(by: UInt64(86400))
        let createdOnDay = UInt64(codeUpdatedAt.timeIntervalSince1970).dividedReportingOverflow(by: UInt64(86400))
        return createdOnDay == today
    } }
    var isExpired: Bool { get {
        Date().timeIntervalSince(lastUpdatedAt) > (3 * TimeInterval.minute)
    } }
    
    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

/**
 Beacon receiver scans for peripherals with fixed service UUID in foreground and background modes. Background scan
 for Android is trivial as scanForPeripherals will always return all Android devices on every call. Background scan for iOS
 devices that are transmitting in background mode is more complex, requiring an open connection to subscribe to a
 notifying characteristic that is used as trigger for keeping both iOS devices in background state (rather than suspended
 or killed). For iOS - iOS devices, on detection, the receiver will (1) write blank data to the transmitter, which triggers the
 transmitter to send a characteristic data update after 8 seconds, which in turns (2) triggers the receiver to receive a value
 update notification, to (3) create the opportunity for a read RSSI call and repeat of this looped process that keeps both
 devices awake.
 
 Please note, the iOS - iOS process is unreliable if (1) the user switches off bluetooth via Airplane mode settings, (2) the
 device reboots, and (3) it will fail completely if the app has been killed by the user. These are conditions that cannot be
 handled reliably by CoreBluetooth state restoration.
 */
class ConcreteReceiver: NSObject, Receiver, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let log = OSLog(subsystem: "org.c19x.beacon", category: "Receiver")
    /// Dedicated sequential queue for all beacon transmitter and receiver tasks.
    private let queue: DispatchQueue!
    /// Central manager for managing all connections, using a single manager for simplicity.
    private var central: CBCentralManager!
    /**
     Characteristic UUID encodes the characteristic identifier in the upper 64-bits and the beacon code in the lower 64-bits
     to achieve reliable read of beacon code without an actual GATT read operation. In theory, the whole 128-bits can be
     used considering the beacon only has one characteristic.
     */
    private let (characteristicCBUUIDUpper,_) = beaconCharacteristicCBUUID.values
    /// Table of known beacons, indexed by the peripheral UUID.
    private var beacons: [String: Beacon] = [:]
    /// Dummy data for writing to the transmitter to trigger state restoration or resume from suspend state to background state.
    private let emptyData = Data(repeating: 0, count: 0)
    /**
     Shifting timer for triggering peripheral scan just before the app switches from background to suspend state following a
     call to CoreBluetooth delegate methods. Apple documentation suggests the time limit is about 10 seconds.
     */
    private var scanTimer: DispatchSourceTimer?
    /// Dedicated sequential queue for the shifting timer.
    private let scanTimerQueue = DispatchQueue(label: "org.c19x.beacon.receiver.Timer")
    /// Delegates for receiving beacon detection events.
    var delegates: [ReceiverDelegate] = []
    /// Track scan interval and up time statistics for the receiver, for debug purposes.
    private let statistics = TimeIntervalSample()
    
    
    required init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        self.central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey : "org.C19X.beacon.Receiver",
            CBCentralManagerOptionShowPowerAlertKey : true])
    }
    
    func start(_ source: String) {
        os_log("start (source=%s)", log: log, type: .debug, source)
        guard !central.isScanning else {
            os_log("start denied, already started (source=%s)", log: log, type: .fault, source)
            return
        }
        // Start scanning
        if central.state == .poweredOn {
            scan("start|" + source)
        }
    }
    
    func stop(_ source: String) {
        os_log("stop (source=%s)", log: log, type: .debug, source)
        guard central.isScanning else {
            os_log("stop denied, already stopped (source=%s)", log: log, type: .fault, source)
            return
        }
        // Stop scanning
        scanTimer?.cancel()
        scanTimer = nil
        central.stopScan()
        // Cancel all connections, the resulting didDisconnect and didFailToConnect
        beacons.values.forEach() { beacon in
            if beacon.peripheral.state != .disconnected {
                disconnect("stop|" + source, beacon.peripheral)
            }
        }
    }
    
    func scan(_ source: String) {
        statistics.add()
        os_log("scan (source=%s,statistics={%s})", log: log, type: .debug, source, statistics.description)
        guard central.state == .poweredOn else {
            os_log("scan failed, bluetooth is not powered on", log: log, type: .fault)
            return
        }
        // Scan for peripherals -> didDiscover
        central.scanForPeripherals(withServices: [beaconServiceCBUUID])
        // Connected peripherals -> Check registration
        central.retrieveConnectedPeripherals(withServices: [beaconServiceCBUUID]).forEach() { peripheral in
            let uuid = peripheral.identifier.uuidString
            if beacons[uuid] == nil {
                os_log("scan found connected but unknown peripheral (peripheral=%s)", log: log, type: .fault, uuid)
                disconnect("scan|unknown", peripheral)
//                beacons[uuid] = Beacon(peripheral: peripheral)
            }
        }
        // All peripherals -> Discard expired beacons
        beacons.values.filter{$0.isExpired}.forEach { beacon in
            let uuid = beacon.uuidString
            os_log("scan found expired peripheral (peripheral=%s)", log: log, type: .debug, uuid)
            disconnect("scan|expired", beacon.peripheral)
            beacons[uuid] = nil
        }
        // All peripherals -> Check pending actions
        beacons.values.forEach() { beacon in
            // All peripherals -> Connect if operating system is unknown (e.g. after restore)
            // This will also enable removable of invalid devices following restore, in didFailToConnect
            if beacon.operatingSystem == nil, beacon.peripheral.state != .connected {
                connect("scan|noOS|" + beacon.peripheral.state.description, beacon.peripheral)
            }
            // iOS peripherals
            else if let operatingSystem = beacon.operatingSystem, operatingSystem == .ios {
                // iOS peripherals (Connected) -> Wake transmitter
                if beacon.peripheral.state == .connected {
                    wakeTransmitter("scan|ios", beacon)
                }
                // iOS peripherals (Not connected) -> Connect
                else {
                    connect("scan|ios|" + beacon.peripheral.state.description, beacon.peripheral)
                }
            }
            // All peripherals -> Check delegate (bit too paranoid?)
            if beacon.peripheral.delegate == nil {
                os_log("scan found detached peripheral (peripheral=%s)", log: log, type: .fault, beacon.uuidString)
                beacon.peripheral.delegate = self
            }
        }
    }
    
    /**
     Schedule scan for beacons after a delay of 8 seconds to start scan again just before
     state change from background to suspended. Scan is sufficient for finding Android
     devices repeatedly in both foreground and background states.
     */
    private func scheduleScan(_ source: String) {
        scanTimer?.cancel()
        scanTimer = DispatchSource.makeTimerSource(queue: scanTimerQueue)
        scanTimer?.schedule(deadline: DispatchTime.now().advanced(by: DispatchTimeInterval.seconds(8)))
        scanTimer?.setEventHandler { [weak self] in
            self?.scan("scheduleScan|"+source)
        }
        scanTimer?.resume()
    }
    
    /**
     Connect peripheral. Scanning is stopped temporarily, as recommended by Apple documentation, before initiating connect, otherwise
     pending scan operations tend to take priority and connect takes longer to start. Scanning is scheduled to resume later, to ensure scan
     resumes, even if connect fails.
     */
    private func connect(_ source: String, _ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        os_log("connect (source=%s,peripheral=%s)", log: log, type: .debug, source, uuid)
        guard central.state == .poweredOn, central.isScanning else {
            os_log("connect denied, central stopped (source=%s,peripheral=%s)", log: log, type: .fault, source, uuid)
            return
        }
        scheduleScan("connect")
        central.connect(peripheral)
    }
    
    /**
     Disconnect peripheral. On didDisconnect, a connect request will be made for iOS devices to maintain an open connection;
     there is no further action for Android. On didFailedToConnect, a connect request will be made for both iOS and Android
     devices as the error is likely to be transient (as described in Apple documentation), except if the error is "Device in invalid"
     then the peripheral is unregistered by removing it from the beacons table.
     */
    private func disconnect(_ source: String, _ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        os_log("disconnect (source=%s,peripheral=%s)", log: log, type: .debug, source, uuid)
        central.cancelPeripheralConnection(peripheral)
    }
    
    /// Read RSSI
    private func readRSSI(_ source: String, _ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        guard peripheral.state == .connected else {
            return
        }
        os_log("readRSSI (source=%s,peripheral=%s)", log: self.log, type: .debug, source, uuid)
        peripheral.readRSSI()
    }
    
    /// Read beacon code
    private func readCode(_ source: String, _ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        guard peripheral.state == .connected else {
            return
        }
        os_log("readCode (source=%s,peripheral=%s)", log: self.log, type: .debug, source, uuid)
        peripheral.discoverServices([beaconServiceCBUUID])
    }
    
    /**
     Wake transmitter by writing blank data to the beacon characteristic. This will trigger the transmitter to generate a data value update notification
     in 8 seconds, which in turn will trigger this receiver to receive a didUpdateValueFor call to keep both the transmitter and receiver awake, while
     maximising the time interval between bluetooth calls to minimise power usage.
     */
    private func wakeTransmitter(_ source: String, _ beacon: Beacon) {
        guard let operatingSystem = beacon.operatingSystem, operatingSystem == .ios, let characteristic = beacon.characteristic else {
            return
        }
        os_log("wakeTransmitter (source=%s,peripheral=%s)", log: log, type: .debug, source, beacon.uuidString)
        beacon.peripheral.writeValue(emptyData, for: characteristic, type: .withResponse)
    }
    
    /// Notify receiver delegates of beacon detection
    private func notifyDelegates(_ source: String, _ beacon: Beacon) {
        guard beacon.isReady, let code = beacon.code, let rssi = beacon.rssi else {
            return
        }
        beacon.statistics.add()
        for delegate in self.delegates {
            delegate.receiver(didDetect: code, rssi: rssi)
        }
        // Invalidate RSSI after notify
        beacon.rssi = nil
        os_log("Detected beacon (source=%s,peripheral=%s,code=%s,rssi=%s,statistics={%s})", log: self.log, type: .debug, source, String(describing: beacon.uuidString), String(describing: code), String(describing: rssi), String(describing: beacon.statistics.description))
    }
    
    // MARK: - CBCentralManagerDelegate
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        // Restore -> Populate beacons
        os_log("Restore", log: log, type: .debug)
        self.central = central
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                peripheral.delegate = self
                let uuid = peripheral.identifier.uuidString
                if let beacon = beacons[uuid] {
                    beacon.peripheral = peripheral
                } else {
                    beacons[uuid] = Beacon(peripheral: peripheral)
                }
                os_log("Restored (peripheral=%s,state=%s)", log: log, type: .debug, uuid, peripheral.state.description)
            }
        }
        // Reconnection check performed in scan following centralManagerDidUpdateState:central.state == .powerOn
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Bluetooth on -> Scan
        os_log("State updated (toState=%s)", log: log, type: .debug, central.state.description)
        if (central.state == .poweredOn) {
            scan("updateState")
        }
        delegates.forEach { $0.receiver(didUpdateState: central.state) }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Discover -> Notify delegates | Wake transmitter | Connect -> Scan again
        let uuid = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        os_log("didDiscover (peripheral=%s,rssi=%d,state=%s)", log: log, type: .debug, uuid, rssi, peripheral.state.description)
        // Register beacon -> Set delegate -> Update RSSI
        if beacons[uuid] == nil {
            beacons[uuid] = Beacon(peripheral: peripheral)
        }
        peripheral.delegate = self
        guard let beacon = beacons[uuid] else {
            return
        }
        beacon.rssi = rssi
        // Beacon is ready -> Notify delegates -> Wake transmitter -> Scan again
        // Beacon is "ready" when it has all the required information (operatingSystem, code, rssi)
        // and the codeUpdatedAt date is today.
        if let operatingSystem = beacon.operatingSystem, beacon.isReady {
            // Android -> Notify delegates -> Scan again
            // Android peripheral is detected by iOS central for every call to scanForPeripherals, in both foreground and background modes.
            // Android BLE address changes over time, thus triggering expire, then connect and therefore no need to connect every time to
            // check for beacon code expiry, which also minimises connect calls to Android devices.
            if operatingSystem == .android {
                notifyDelegates("didDiscover|android", beacon)
                scheduleScan("didDiscover|android")
            }
            // iOS -> Notify delegates -> Wake transmitter -> Scan again
            // iOS peripheral is kept awake by writing empty data to the beacon characteristic, which triggers a value update notification
            // after 8 seconds. The notification triggers the receiver's didUpdateValueFor callback, which wakes up the receiver to initiate
            // a readRSSI call. Please note, a beacon code update on the transmitter will trigger the receiver's didModifyService callback,
            // which wakes up the receiver to initiate a readCode (if already connected) or connect call.
            else {
                notifyDelegates("didDiscover|android", beacon)
                wakeTransmitter("didDiscover", beacon)
                scheduleScan("didDiscover|ios")
            }
        }
        // Beacon is not ready | Beacon is new -> Connect
        else if !beacon.isReady || beacon.peripheral.state == .disconnected || beacon.peripheral.state == .disconnecting {
            connect("didDiscover", peripheral)
        }
        // Default -> Scan again
        scheduleScan("didDiscover")
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Connect -> Read Code | Read RSSI
        let uuid = peripheral.identifier.uuidString
        os_log("didConnect (peripheral=%s)", log: log, type: .debug, uuid)
        guard let beacon = beacons[uuid] else {
            // This should never happen
            return
        }
        if !beacon.isReady {
            // Not ready -> Read Code (RSSI should already be available from didDiscover)
            readCode("didConnect", peripheral)
        } else {
            // Ready -> Read RSSI -> Read Code
            // This is the path after restore, didFailToConnect, disconnect[iOS], didModifyService where
            // the RSSI value may be available but need to be refreshed
            readRSSI("didConnect", peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Connect fail -> Unregister | Connect
        // Failure for peripherals advertising the beacon service should be transient, so try again.
        // This is also where iOS reports invalidated devices if connect is called after restore,
        // thus offers an opportunity for house keeping.
        let uuid = peripheral.identifier.uuidString
        os_log("didFailToConnect (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        if String(describing: error).contains("Device is invalid") {
            os_log("Unregister invalid device (peripheral=%s)", log: log, type: .debug, uuid)
            beacons[uuid] = nil
        } else {
            connect("didFailToConnect", peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Disconnected -> Connect if iOS
        // Keep connection only for iOS, not necessary for Android as they are always detectable
        let uuid = peripheral.identifier.uuidString
        os_log("didDisconnectPeripheral (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        if let beacon = beacons[uuid], let operatingSystem = beacon.operatingSystem, operatingSystem == .ios {
            connect("didDisconnectPeripheral", peripheral)
        }
    }
    
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        // Read RSSI -> Read Code | Notify delegates -> Scan again
        // This is the primary loop for iOS after initial connection and subscription to
        // the notifying beacon characteristic. The loop is scan -> wakeTransmitter ->
        // didUpdateValueFor -> readRSSI -> notifyDelegates -> scheduleScan -> scan
        let uuid = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        os_log("didReadRSSI (peripheral=%s,rssi=%d,error=%s)", log: log, type: .debug, uuid, rssi, String(describing: error))
        if let beacon = beacons[uuid] {
            beacon.rssi = rssi
            if !beacon.isReady {
                readCode("didReadRSSI", peripheral)
                return
            } else {
                notifyDelegates("didReadRSSI", beacon)
                if let operatingSystem = beacon.operatingSystem, operatingSystem == .android {
                    disconnect("didReadRSSI", peripheral)
                }
            }
        }
        // For initial connection, the scheduleScan call would have been made just before connect.
        // It is called again here to extend the time interval between scans.
        scheduleScan("didReadRSSI")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Discover services -> Discover characteristics | Disconnect
        let uuid = peripheral.identifier.uuidString
        os_log("didDiscoverServices (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        guard let services = peripheral.services else {
            disconnect("didDiscoverServices|serviceEmpty", peripheral)
            return
        }
        for service in services {
            os_log("didDiscoverServices, found service (peripheral=%s,service=%s)", log: log, type: .debug, uuid, service.uuid.description)
            if (service.uuid == beaconServiceCBUUID) {
                os_log("didDiscoverServices, found beacon service (peripheral=%s)", log: log, type: .debug, uuid)
                peripheral.discoverCharacteristics(nil, for: service)
                return
            }
        }
        disconnect("didDiscoverServices|serviceNotFound", peripheral)
        // The disconnect calls here shall be handled by didDisconnect which determines whether to retry for iOS or stop for Android
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Discover characteristics -> Notify delegates -> Disconnect | Wake transmitter -> Scan again
        let uuid = peripheral.identifier.uuidString
        os_log("didDiscoverCharacteristicsFor (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        guard let beacon = beacons[uuid], let characteristics = service.characteristics else {
            disconnect("didDiscoverCharacteristicsFor|characteristicEmpty", peripheral)
            return
        }
        for characteristic in characteristics {
            os_log("didDiscoverCharacteristicsFor, found characteristic (peripheral=%s,characteristic=%s)", log: log, type: .debug, uuid, characteristic.uuid.description)
            let (upper,beaconCode) = characteristic.uuid.values
            if upper == characteristicCBUUIDUpper {
                let notifies = characteristic.properties.contains(.notify)
                os_log("didDiscoverCharacteristicsFor, found beacon characteristic (peripheral=%s,beaconCode=%s,notifies=%s,os=%s)", log: log, type: .debug, uuid, beaconCode.description, (notifies ? "true" : "false"), (notifies ? "ios" : "android"))
                beacon.code = beaconCode
                // Characteristic notifies -> Operating system is iOS, else Android
                beacon.operatingSystem = (notifies ? .ios : .android)
                // Characteristic change -> Unsubscribe
                if let c = beacon.characteristic, characteristic != c {
                    peripheral.setNotifyValue(false, for: c)
                    beacon.characteristic = nil
                }
                // Characteristic notifies -> Subscribe
                if notifies, beacon.characteristic == nil {
                    beacon.characteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                notifyDelegates("didDiscoverCharacteristicsFor", beacon)
            }
        }
        // iOS -> Wake transmitter
        if let operatingSystem = beacon.operatingSystem, operatingSystem == .ios {
            wakeTransmitter("didDiscoverCharacteristicsFor", beacon)
        }
            // Android -> Disconnect
        else {
            disconnect("didDiscoverCharacteristicsFor", peripheral)
        }
        // Always -> Scan again
        // For initial connection, the scheduleScan call would have been made just before connect.
        // It is called again here to extend the time interval between scans.
        scheduleScan("didDiscoverCharacteristicsFor")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Wrote characteristic -> Scan again
        let uuid = peripheral.identifier.uuidString
        os_log("didWriteValueFor (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        // For all situations, scheduleScan would have been made earlier in the chain of async calls.
        // It is called again here to extend the time interval between scans, as this is usually the
        // last call made in all paths to wake the transmitter.
        scheduleScan("didWriteValueFor")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // iOS only
        // Modified service -> Invalidate beacon -> Read Code | Connect
        // Beacon code updates will change the characteristic UUID being broadcasted by the transmitter
        // which will trigger a didModifyServices call on all the iOS subscibers, thus iOS devices will
        // need to read the new code, if already connected, or connect to read the new code.
        let uuid = peripheral.identifier.uuidString
        os_log("didModifyServices (peripheral=%s)", log: log, type: .debug, uuid)
        if let beacon = beacons[uuid] {
            beacon.code = nil
            if peripheral.state == .connected {
                readCode("didModifyServices", peripheral)
            } else {
                connect("didModifyServices", peripheral)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // iOS only
        // Updated value -> Read RSSI
        // Beacon characteristic is writable, primarily to enable non-transmitting Android devices to submit their
        // beacon code and RSSI as data to the transmitter via GATT write. The characteristic is also notifying on
        // iOS devices, to offer a mechanism for waking receivers. The process works as follows, (1) receiver writes
        // blank data to transmitter, (2) transmitter broadcasts value update notification after 8 seconds, (3)
        // receiver is woken up to handle didUpdateValueFor notification, (4) receiver calls readRSSI, (5) readRSSI
        // call completes and schedules scan after 8 seconds, (6) scan writes blank data to all iOS transmitters.
        // Process repeats to keep both iOS transmitters and receivers awake while maximising time interval between
        // bluetooth calls to minimise power usage.
        let uuid = peripheral.identifier.uuidString
        os_log("didUpdateValueFor (peripheral=%s,error=%s)", log: log, type: .debug, uuid, String(describing: error))
        readRSSI("didUpdateValueFor", peripheral)
    }
}

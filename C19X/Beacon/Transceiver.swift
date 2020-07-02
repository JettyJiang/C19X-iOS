//
//  Transceiver.swift
//  C19X
//
//  Created by Freddy Choi on 01/04/2020.
//  Copyright © 2020 C19X. All rights reserved.
//

import Foundation
import CoreBluetooth
import os

/**
 Beacon transmitter and receiver for broadcasting and detecting frequently changing beacon codes
 that can be later resolved for on-device matching based on the daily beacon code seeds.
 
 Each registered device has a single shared secret that is generated and obtained from the server
 on registration. This is a one-off operation. The shared secret is then stored at the server and also
 in secure storage on the device. A sequence of day codes is then generated from the shared secret
 by recursively applying SHA to the hashes, and running the sequence in reverse to provide a finite
 list of forward secure codes, where historic codes cannot predict future codes. One day code is used
 per day. The daily beacon code seed is generated by reversing the day code binary data, and applying
 SHA to generate a hash as the seed. This separates the seed from the day code, and it is this seed
 that is being published by the central server later when a user submits their infection status, i.e.
 the published seed data cannot be reconnected to the day codes.
 
 Beacon codes for a day are generated by recursively hashing the daily beacon code seed to produce
 a collection of hashes, and the actual code is a long value produced by taking the modulo of each hash.
 This scheme makes it possible for the beacon codes to be regenerated on-device for matching given
 the daily seed codes.
 
 When a user submits his/her infection status, only the public identifier and infection status is transmitted
 to the central server. Given all the day codes are generated from the shared secret, the central server is
 able to generate and publish the relevant daily beacon seed codes for any time period for download by
 all the devices, which in turn can use the seed codes to generate the beacon codes for on-device
 matching. Given the original shared secret is shared only once via HTTPS and then stored securely
 on the server side, and also on the device, this scheme offers a small attack surface for decoding all
 the beacon codes.
 */
protocol Transceiver {
    /**
     Start transmitter and receiver to follow Bluetooth state changes to start and stop advertising and scanning.
     */
    func start(_ source: String)
    
    /**
     Stop transmitter and receiver will disable advertising, scanning and terminate all connections.
     */
    func stop(_ source: String)
    
    func append(_ delegate: ReceiverDelegate)
}

/// Time delay between notifications for subscribers.
let transceiverNotificationDelay = DispatchTimeInterval.seconds(8)

class ConcreteTransceiver: NSObject, Transceiver, LocationManagerDelegate {
    private let log = OSLog(subsystem: "org.c19x.beacon", category: "Transceiver")
    private let dayCodes: DayCodes
    private let beaconCodes: BeaconCodes
    private let queue = DispatchQueue(label: "org.c19x.beacon.Transceiver")
    private let transmitter: Transmitter
    private let receiver: Receiver
    private var delegates: [ReceiverDelegate] = []
    private let locationManager: LocationManager

    init(_ sharedSecret: SharedSecret, codeUpdateAfter: TimeInterval) {
        dayCodes = ConcreteDayCodes(sharedSecret)
        beaconCodes = ConcreteBeaconCodes(dayCodes)
        receiver = ConcreteReceiver(queue: queue)
        transmitter = ConcreteTransmitter(queue: queue, beaconCodes: beaconCodes, updateCodeAfter: codeUpdateAfter, receiver: receiver)
        locationManager = ConcreteLocationManager()
        super.init()
        locationManager.append(self)
    }
    
    func start(_ source: String) {
        os_log("start (source=%s)", log: self.log, type: .debug, source)
        transmitter.start(source)
        receiver.start(source)
        // REMOVE FOR PRODUCTION
        if source == "BGAppRefreshTask" {
            delegates.forEach { $0.receiver(didDetect: BeaconCode(0), rssi: RSSI(-10010)) }
        } else {
            delegates.forEach { $0.receiver(didDetect: BeaconCode(0), rssi: RSSI(-10000)) }
        }
    }

    func stop(_ source: String) {
        os_log("stop (source=%s)", log: self.log, type: .debug, source)
        transmitter.stop(source)
        receiver.stop(source)
    }
    
    func append(_ delegate: ReceiverDelegate) {
        delegates.append(delegate)
        receiver.append(delegate)
        transmitter.append(delegate)
    }
    
    // MARK:- LocationManagerDelegate
    
    func locationManager(didDetect: LocationChange) {
        receiver.scan("locationManager")
        os_log("Beacon state report (subscribers) ========", log: self.log, type: .debug)
        transmitter.subscribers().forEach() { central in
            os_log("Beacon state (uuid=%s,state=.subscribing)", log: self.log, type: .debug, central.identifier.uuidString)
        }
    }
}

class CachedBeaconData {
    var code: BeaconCode? {
        didSet {
            lastUpdatedAt = Date()
            codeUpdatedAt = Date()
        }
    }
    var rssi: RSSI? {
       didSet {
           lastUpdatedAt = Date()
       }
    }
    var codeUpdatedAt: Date = Date.distantPast
    var lastUpdatedAt: Date = Date.distantPast
}

class TestTransceiver: NSObject, Transceiver, LocationManagerDelegate, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let log = OSLog(subsystem: "org.c19x.beacon", category: "TestTransceiver")
    private let beaconCode: BeaconCode
    private let settings: Settings
    private let dispatchQueue = DispatchQueue(label: "Transceiver")
    private let emptyData = Data(repeating: 0, count: 0)

    private var delegates: [ReceiverDelegate] = []

    private var peripheralManager: CBPeripheralManager!
    private var peripheralCharacteristic: CBMutableCharacteristic?
    
    private var centralManager: CBCentralManager!
    private var centralManagerPeripherals: [String:CBPeripheral] = [:]
    private var centralManagerCachedBeaconData: [String:CachedBeaconData] = [:]
    
    private var centralManagerScanTimer: DispatchSourceTimer?
    private let centralManagerScanTimerQueue = DispatchQueue(label: "org.c19x.beacon.Timer")

    private var locationManager: LocationManager!

    init(_ beaconCode: BeaconCode, _ settings: Settings) {
        self.beaconCode = beaconCode
        self.settings = settings
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: dispatchQueue, options: [
            CBPeripheralManagerOptionRestoreIdentifierKey : "org.C19X.beacon.Transmitter",
            CBPeripheralManagerOptionShowPowerAlertKey : true
        ])
        
        centralManager = CBCentralManager(delegate: self, queue: dispatchQueue, options: [
            CBCentralManagerOptionRestoreIdentifierKey : "org.C19X.beacon.Receiver",
            CBCentralManagerOptionShowPowerAlertKey : true
        ])
        
        locationManager = ConcreteLocationManager()
        locationManager.append(self)
    }
    
    func start(_ source: String) {}
    
    func stop(_ source: String) {}
    
    func append(_ delegate: ReceiverDelegate) {
        delegates.append(delegate)
    }

    // MARK:- LocationManagerDelegate
    
    func locationManager(didDetect: LocationChange) {
        guard didDetect == .location else {
            return
        }
//        os_log("locationManager:didDetect (change=%s)", log: self.log, type: .debug, didDetect.rawValue)
//        centralManagerScanForPeripherals(centralManager)
    }
    
    // MARK:- CBPeripheralManagerDelegate
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        os_log("peripheralManagerDidUpdateState (state=%s)", log: self.log, type: .debug, peripheral.state.description)
        delegates.forEach{$0.receiver(didUpdateState: peripheral.state)}
        guard peripheral.state == .poweredOn else {
            return
        }
        os_log("peripheralManagerDidUpdateState -> peripheralManagerStartAdvertising (state=%s)", log: self.log, type: .debug, peripheral.state.description)
        peripheralManagerStartAdvertising(peripheral, code: beaconCode)
    }
    
    private func peripheralManagerStartAdvertising(_ peripheral: CBPeripheralManager, code: BeaconCode) {
        os_log("peripheralManagerStartAdvertising -> startAdvertising (state=%s,code=%s)", log: self.log, type: .debug, peripheral.state.description, code.description)
        guard peripheral.state == .poweredOn else {
            return
        }
        peripheralManager = peripheral
        peripheralManager.delegate = self
        let upper = beaconCharacteristicCBUUID.values.upper
        let beaconCharacteristicCBUUID = CBUUID(upper: upper, lower: beaconCode)
        let characteristic = CBMutableCharacteristic(type: beaconCharacteristicCBUUID, properties: [.write, .notify], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: beaconServiceCBUUID, primary: true)
        service.characteristics = [characteristic]
        peripheralManager.removeAllServices()
        peripheralManager.add(service)
        peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey : [service.uuid]])
        peripheralCharacteristic = characteristic
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        os_log("peripheralManager:willRestoreState", log: log, type: .debug)
        peripheralManager = peripheral
        peripheralManager.delegate = self
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services {
                if let characteristics = service.characteristics {
                    for characteristic in characteristics {
                        if characteristic.uuid.values.upper == beaconCharacteristicCBUUID.values.upper, let characteristic = characteristic as? CBMutableCharacteristic {
                            let code = characteristic.uuid.values.lower
                            os_log("peripheralManager:willRestoreState:restoredCharacteristic (code=%s)", log: log, type: .debug, code.description)
                            peripheralCharacteristic = characteristic
                        }
                    }
                }
            }
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        os_log("peripheralManagerDidStartAdvertising (error=%s)", log: log, type: .debug, error?.localizedDescription ?? "nil")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        os_log("peripheralManager:didSubscribeTo (%s)", log: log, type: .debug, central.description)
        // Enables airplane mode survival for a while
        peripheralManagerUpdateValue(peripheral)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        os_log("peripheralManager:didUnsubscribeFrom (%s)", log: log, type: .debug, central.description)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        let centrals = requests.map{$0.central}
        os_log("peripheralManager:didReceiveWrite (centrals=%s)", log: log, type: .debug, centrals.description)
    }

    func peripheralManagerUpdateValue(_ peripheral: CBPeripheralManager) {
        os_log("peripheralManagerUpdateValue", log: log, type: .debug)
        guard let characteristic = peripheralCharacteristic else {
            return
        }
        peripheral.updateValue(emptyData, for: characteristic, onSubscribedCentrals: nil)
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        os_log("peripheralManagerIsReady:toUpdateSubscribers -> peripheralManagerUpdateValue", log: log, type: .debug)
        peripheralManagerUpdateValue(peripheral)
    }
    
    // MARK:- CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        os_log("centralManagerDidUpdateState (state=%s)", log: self.log, type: .debug, central.state.description)
        guard central.state == .poweredOn else {
            return
        }
        centralManager = central
        centralManager.delegate = self
        centralManagerScanForPeripherals(central)
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        os_log("centralManager:willRestoreState", log: log, type: .debug)
        centralManager = central
        centralManager.delegate = self
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                settings.peripherals(append: peripheral.identifier.uuidString)
                peripheral.delegate = self
                centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
                os_log("centralManager:willRestoreState:restored (%s)", log: log, type: .debug, peripheral.description)
            }
        }
    }
    
    func centralManagerScanForPeripherals(_ central: CBCentralManager) {
        os_log("centralManager:scanForPeripherals (state=%s) ====================", log: log, type: .debug, central.state.description)
        scheduleCentralManagerScanForPeripherals()
        let identifiers = settings.peripherals().sorted{$0 < $1}.compactMap{UUID(uuidString: $0)}
        central.retrieveConnectedPeripherals(withServices: [beaconServiceCBUUID]).forEach() { peripheral in
            os_log("centralManager:scanForPeripherals:retrieveConnectedPeripherals -> connect (%s)", log: log, type: .debug, peripheral.description)
            centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
            guard central.state == .poweredOn else {
                return
            }
            central.connect(peripheral)
        }
        // Enables resume from airplane mode
        let peripherals = central.retrievePeripherals(withIdentifiers: identifiers)
        peripherals.forEach() { peripheral in
            centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
            guard central.state == .poweredOn else {
                return
            }
            central.connect(peripheral)
        }
        guard central.state == .poweredOn else {
            return
        }
        central.scanForPeripherals(
            withServices: [beaconServiceCBUUID],
            options: [CBCentralManagerScanOptionSolicitedServiceUUIDsKey: [beaconServiceCBUUID]])
    }
    
    func scheduleCentralManagerScanForPeripherals() {
        centralManagerScanTimer?.cancel()
        centralManagerScanTimer = DispatchSource.makeTimerSource(queue: centralManagerScanTimerQueue)
        // Schedule is held idle until didSubscribe
        centralManagerScanTimer?.schedule(deadline: DispatchTime.now().advanced(by: .seconds(8)))
        centralManagerScanTimer?.setEventHandler { [weak self] in
            guard let centralManager = self?.centralManager else {
                return
            }
            self?.centralManagerScanForPeripherals(centralManager)
        }
        centralManagerScanTimer?.resume()
    }

    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        os_log("centralManager:didDiscover -> connect (%s)", log: log, type: .debug, peripheral.description)
        settings.peripherals(append: peripheral.identifier.uuidString)
        centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        os_log("centralManager:didConnect -> readRSSI (%s)", log: log, type: .debug, peripheral.description)
        peripheral.delegate = self
        peripheral.readRSSI()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        os_log("centralManager:didDisconnectPeripheral -> connect (%s)", log: log, type: .debug, peripheral.description)
//        peripheral.delegate = nil
//        centralManagerPeripherals[peripheral.identifier.uuidString] = nil
        
        settings.peripherals(append: peripheral.identifier.uuidString)
        centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
        central.connect(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        os_log("centralManager:didFailToConnect (%s)", log: log, type: .debug, peripheral.description)
        peripheral.delegate = nil
        centralManagerPeripherals[peripheral.identifier.uuidString] = nil
    }
    
    // MARK:- CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let uuid = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        os_log("peripheral:didReadRSSI -> discoverServices (rssi=%s,%s)", log: log, type: .debug, rssi.description, peripheral.description)
        if centralManagerCachedBeaconData[uuid] == nil {
            centralManagerCachedBeaconData[uuid] = CachedBeaconData()
        }
        centralManagerCachedBeaconData[uuid]?.rssi = rssi
        peripheral.discoverServices([beaconServiceCBUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.filter({$0.uuid == beaconServiceCBUUID}).first else {
            os_log("peripheral:didDiscoverServices -> cancelPeripheralConnection (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        os_log("peripheral:didDiscoverServices -> discoverCharacteristics (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        os_log("peripheral:didDiscoverCharacteristicsFor (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
        guard let characteristic = service.characteristics?.filter({ $0.uuid.values.upper == beaconCharacteristicCBUUID.values.upper }).first else {
            os_log("peripheral:didDiscoverCharacteristicsFor -> cancelPeripheralConnection (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        let code = BeaconCode(characteristic.uuid.values.lower)
        os_log("peripheral:didDiscoverCharacteristicsFor -> FOUND (uuid=%s,code=%s)", log: log, type: .debug, peripheral.identifier.uuidString, code.description)
        if characteristic.properties.contains(.notify) {
            os_log("peripheral:didDiscoverCharacteristicsFor:ios -> setNotifyValue (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
            peripheral.setNotifyValue(true, for: characteristic)
        } else {
            os_log("peripheral:didDiscoverCharacteristicsFor:android -> cancelPeripheralConnection (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
            centralManager.cancelPeripheralConnection(peripheral)
        }
        // Notify delegates
        if centralManagerCachedBeaconData[peripheral.identifier.uuidString] == nil {
            centralManagerCachedBeaconData[peripheral.identifier.uuidString] = CachedBeaconData()
            centralManagerCachedBeaconData[peripheral.identifier.uuidString]?.code = code
        }
        if let rssi = centralManagerCachedBeaconData[peripheral.identifier.uuidString]?.rssi {
            delegates.forEach{$0.receiver(didDetect: code, rssi: rssi)}
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        os_log("peripheral:didUpdateValueFor (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        os_log("peripheral:didUpdateNotificationStateFor (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        os_log("peripheral:didWriteValueFor (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        os_log("peripheral:didModifyServices (uuid=%s)", log: log, type: .debug, peripheral.identifier.uuidString)
        settings.peripherals(append: peripheral.identifier.uuidString)
        centralManagerPeripherals[peripheral.identifier.uuidString] = peripheral
        centralManager.connect(peripheral)
    }
}

extension CBPeripheral {
    var uuidString: String { get { identifier.uuidString }}
    open override var description: String { get {
        let stateString = state.description
        let objectIdentifier = Unmanaged.passUnretained(self).toOpaque().debugDescription.suffix(6).description
        return "<P:uuid=" + uuidString + ",state=" + stateString + ",obj=" + objectIdentifier + ">"
    }}
}

extension CBCentral {
    var uuidString: String { get { identifier.uuidString }}
    open override var description: String { get {
        let objectIdentifier = Unmanaged.passUnretained(self).toOpaque().debugDescription.suffix(6).description
        return "<C:uuid=" + uuidString + ",obj=" + objectIdentifier + ">"
    }}
}

extension CBMutableCharacteristic {
    var uuidString: String { get { uuid.uuidString }}
    open override var description: String { get {
        let objectIdentifier = Unmanaged.passUnretained(self).toOpaque().debugDescription.suffix(6).description
        let code = uuid.values.lower.description
        let centrals = subscribedCentrals?.description ?? "[]"
        return "<CHAR:uuid=" + uuidString + ",code=" + code + ",subscribers=" + centrals + ",obj=" + objectIdentifier + ">"
    }}
}

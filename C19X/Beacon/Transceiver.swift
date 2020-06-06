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
     Beacon transmitter.
     */
    var transmitter : Transmitter { get set }
    /**
     Beacon receiver.
     */
    var receiver: Receiver { get set }

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

class ConcreteTransceiver : Transceiver {
    private let log = OSLog(subsystem: "org.c19x.beacon", category: "Transceiver")
    private let dayCodes: DayCodes
    private let beaconCodes: BeaconCodes
    private let queue = DispatchQueue(label: "org.c19x.beacon.Transceiver")
    var transmitter : Transmitter
    var receiver: Receiver
    
    init(_ sharedSecret: SharedSecret, codeUpdateAfter: TimeInterval) {
        dayCodes = ConcreteDayCodes(sharedSecret)
        beaconCodes = ConcreteBeaconCodes(dayCodes)
        transmitter = ConcreteTransmitter(queue: queue, beaconCodes: beaconCodes, updateCodeAfter: codeUpdateAfter)
        receiver = ConcreteReceiver(queue: queue)
    }
    
    func start(_ source: String) {
        transmitter.start(source)
        receiver.start(source)
    }

    func stop(_ source: String) {
        transmitter.stop(source)
        receiver.stop(source)
    }
    
    func append(_ delegate: ReceiverDelegate) {
        receiver.delegates.append(delegate)
        transmitter.delegates.append(delegate)
    }
}
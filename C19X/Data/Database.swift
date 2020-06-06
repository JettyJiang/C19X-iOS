//
//  Database.swift
//  C19X
//
//  Created by Freddy Choi on 14/05/2020.
//  Copyright © 2020 C19X. All rights reserved.
//

import Foundation
import CoreData
import os

protocol Database {
    var contacts: [Contact] { get }
    
    /**
     Add new contact record.
     */
    func insert(time: Date, code: BeaconCode, rssi: RSSI)
    
    /**
     Remove all database records before given date.
     */
    func remove(_ before: Date)
}

class ConcreteDatabase: Database {
    private let log = OSLog(subsystem: "org.c19x.data", category: "Database")
    private var persistentContainer: NSPersistentContainer

    private var lock = NSLock()
    var contacts: [Contact] = []

    init() {
        persistentContainer = NSPersistentContainer(name: "C19X")
        let storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = storeDirectory.appendingPathComponent("C19X.sqlite")
        let description = NSPersistentStoreDescription(url: url)
        description.shouldInferMappingModelAutomatically = true
        description.shouldMigrateStoreAutomatically = true
        description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
        persistentContainer.persistentStoreDescriptions = [description]
        persistentContainer.loadPersistentStores { description, error in
            description.options.forEach() { option in
                os_log("Loaded persistent stores (key=%s,value=%s)", log: self.log, type: .debug, option.key, option.value.description)
            }
            if let error = error {
                fatalError("Unable to load persistent stores: \(error)")
            }
        }
        load()
    }
    
    func insert(time: Date, code: BeaconCode, rssi: RSSI) {
        os_log("insert (time=%s,code=%s,rssi=%d)", log: log, type: .debug, time.description, code.description, rssi)
        lock.lock()
        do {
            let managedContext = persistentContainer.viewContext
            let object = NSEntityDescription.insertNewObject(forEntityName: "Contact", into: managedContext) as! Contact
            object.setValue(time, forKey: "time")
            object.setValue(Int64(code), forKey: "code")
            object.setValue(Int32(rssi), forKey: "rssi")
            try managedContext.save()
            contacts.append(object)
        } catch let error as NSError {
            os_log("insert failed (time=%s,code=%s,rssi=%d,error=%s)", log: log, type: .debug, time.description, code.description, rssi, error.description)
        }
        lock.unlock()
    }
    
    func remove(_ before: Date) {
        os_log("remove (before=%s)", log: self.log, type: .debug, before.description)
        lock.lock()
        let managedContext = persistentContainer.viewContext
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "Contact")
        do {
            let objects: [Contact] = try managedContext.fetch(fetchRequest) as! [Contact]
            objects.forEach() { o in
                if let time = o.value(forKey: "time") as? Date {
                    if (time.compare(before) == .orderedAscending) {
                        managedContext.delete(o)
                    }
                }
            }
            try managedContext.save()
            load()
        } catch let error as NSError {
            os_log("Remove failed (error=%s)", log: self.log, type: .fault, error.description)
        }
        lock.unlock()
    }
    
    private func load() {
        os_log("Load", log: self.log, type: .debug)
        let managedContext = persistentContainer.viewContext
        let fetchRequest = NSFetchRequest<Contact>(entityName: "Contact")
        do {
            self.contacts = try managedContext.fetch(fetchRequest)
            os_log("Loaded (count=%d)", log: self.log, type: .debug, self.contacts.count)
        } catch let error as NSError {
            os_log("Load failed (error=%s)", log: self.log, type: .fault, error.description)
        }
    }
}
//
//  DeviceDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import LoopKit
import LoopKitUI
import LoopCore
import LoopTestingKit
import UserNotifications
import AudioToolbox
import AVFoundation

final class DeviceDataManager {
    
    private let queue = DispatchQueue(label: "com.loopkit.DeviceManagerQueue", qos: .utility)
    
    private let log = DiagnosticLogger.shared.forCategory("DeviceManager")
    
    /// Remember the launch date of the app for diagnostic reporting
    private let launchDate = Date()
    
    /// set initial lastAlarmDate to launchDate minus 24 hours
    
    var lastAlarmDate = Date() - .hours(24)
    
    /// Manages authentication for remote services
    let remoteDataManager = RemoteDataManager()
    
    private var nightscoutDataManager: NightscoutDataManager!
    
    private(set) var testingScenariosManager: TestingScenariosManager?
    
    /// The last error recorded by a device manager
    /// Should be accessed only on the main queue
    private(set) var lastError: (date: Date, error: Error)?
    
    /// The last time a BLE heartbeat was received and acted upon.
    private var lastBLEDrivenUpdate = Date.distantPast
    
    // MARK: - CGM
    
    var cgmManager: CGMManager? {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            setupCGM()
            UserDefaults.appGroup?.cgmManager = cgmManager
        }
    }
    
    // MARK: - Pump
    
    var pumpManager: PumpManagerUI? {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            
            // If the current CGMManager is a PumpManager, we clear it out.
            if cgmManager is PumpManagerUI {
                cgmManager = nil
            }
            
            setupPump()
            
            NotificationCenter.default.post(name: .PumpManagerChanged, object: self, userInfo: nil)
            
            UserDefaults.appGroup?.pumpManagerRawValue = pumpManager?.rawValue
        }
    }
    
    private(set) var pumpManagerHUDProvider: HUDProvider?
    
    // MARK: - WatchKit
    
    private var watchManager: WatchDataManager!
    
    // MARK: - Status Extension
    
    private var statusExtensionManager: StatusExtensionDataManager!
    
    // MARK: - Plugins
    
    private var pluginManager: PluginManager
    
    // MARK: - Initialization
    
    
    private(set) var loopManager: LoopDataManager!
    
    init() {
        pluginManager = PluginManager()
        
        if let pumpManagerRawValue = UserDefaults.appGroup?.pumpManagerRawValue {
            pumpManager = pumpManagerFromRawValue(pumpManagerRawValue)
        } else {
            pumpManager = nil
        }
        
        if let cgmManager = UserDefaults.appGroup?.cgmManager {
            self.cgmManager = cgmManager
        } else if isCGMManagerValidPumpManager {
            self.cgmManager = pumpManager as? CGMManager
        }
        
        remoteDataManager.delegate = self
        statusExtensionManager = StatusExtensionDataManager(deviceDataManager: self)
        
        loopManager = LoopDataManager(
            lastLoopCompleted: statusExtensionManager.context?.lastLoopCompleted,
            basalDeliveryState: pumpManager?.status.basalDeliveryState,
            lastPumpEventsReconciliation: pumpManager?.lastReconciliation
        )
        watchManager = WatchDataManager(deviceManager: self)
        nightscoutDataManager = NightscoutDataManager(deviceDataManager: self)
        
        if debugEnabled {
            testingScenariosManager = LocalTestingScenariosManager(deviceManager: self)
        }
        
        loopManager.delegate = self
        loopManager.carbStore.syncDelegate = remoteDataManager.nightscoutService.uploader
        loopManager.doseStore.delegate = self
        
        setupPump()
        setupCGM()
    }
    
    var isCGMManagerValidPumpManager: Bool {
        guard let rawValue = UserDefaults.appGroup?.cgmManagerState else {
            return false
        }
        
        return pumpManagerTypeFromRawValue(rawValue) != nil
    }
    
    var availablePumpManagers: [AvailableDevice] {
        return pluginManager.availablePumpManagers + availableStaticPumpManagers
    }
    
    public func pumpManagerTypeByIdentifier(_ identifier: String) -> PumpManagerUI.Type? {
        return pluginManager.getPumpManagerTypeByIdentifier(identifier) ?? staticPumpManagersByIdentifier[identifier] as? PumpManagerUI.Type
    }
    
    private func pumpManagerTypeFromRawValue(_ rawValue: [String: Any]) -> PumpManager.Type? {
        guard let managerIdentifier = rawValue["managerIdentifier"] as? String else {
            return nil
        }
        
        return pumpManagerTypeByIdentifier(managerIdentifier)
    }
    
    func pumpManagerFromRawValue(_ rawValue: [String: Any]) -> PumpManagerUI? {
        guard let rawState = rawValue["state"] as? PumpManager.RawStateValue,
            let Manager = pumpManagerTypeFromRawValue(rawValue)
            else {
                return nil
        }
        
        return Manager.init(rawState: rawState) as? PumpManagerUI
    }
    
    private func processCGMResult(_ manager: CGMManager, result: CGMResult) {
        switch result {
        case .newData(let values):
            log.default("CGMManager:\(type(of: manager)) did update with \(values.count) values")
            
            loopManager.addGlucose(values) { result in
                if manager.shouldSyncToRemoteService {
                    switch result {
                    case .success(let values):
                        self.nightscoutDataManager.uploadGlucose(values, sensorState: manager.sensorState)
                    case .failure:
                        break
                    }
                }
                
                self.log.default("Asserting current pump data")
                self.pumpManager?.assertCurrentPumpData()
            }
        case .noData:
            log.default("CGMManager:\(type(of: manager)) did update with no data")
            
            pumpManager?.assertCurrentPumpData()
        case .error(let error):
            log.default("CGMManager:\(type(of: manager)) did update with error: \(error)")
            
            self.setLastError(error: error)
            log.default("Asserting current pump data")
            pumpManager?.assertCurrentPumpData()
        }
        
        updatePumpManagerBLEHeartbeatPreference()
    }
    
    
}

private extension DeviceDataManager {
    func setupCGM() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        cgmManager?.cgmManagerDelegate = self
        cgmManager?.delegateQueue = queue
        loopManager.glucoseStore.managedDataInterval = cgmManager?.managedDataInterval
        
        updatePumpManagerBLEHeartbeatPreference()
    }
    
    func setupPump() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        pumpManager?.pumpManagerDelegate = self
        pumpManager?.delegateQueue = queue
        
        loopManager.doseStore.device = pumpManager?.status.device
        pumpManagerHUDProvider = pumpManager?.hudProvider()
        
        // Proliferate PumpModel preferences to DoseStore
        if let pumpRecordsBasalProfileStartEvents = pumpManager?.pumpRecordsBasalProfileStartEvents {
            loopManager?.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
        }
    }
    
    func setLastError(error: Error) {
        DispatchQueue.main.async {
            self.lastError = (date: Date(), error: error)
        }
    }
}

// MARK: - Client API
extension DeviceDataManager {
    func enactBolus(units: Double, at startDate: Date = Date(), completion: @escaping (_ error: Error?) -> Void) {
        guard let pumpManager = pumpManager else {
            completion(LoopError.configurationError(.pumpManager))
            return
        }
        
        self.loopManager.addRequestedBolus(DoseEntry(type: .bolus, startDate: Date(), value: units, unit: .units), completion: nil)
        pumpManager.enactBolus(units: units, at: startDate, willRequest: { (dose) in
            // No longer used...
        }) { (result) in
            switch result {
            case .failure(let error):
                self.log.error(error)
                NotificationManager.sendBolusFailureNotification(for: error, units: units, at: startDate)
                self.loopManager.bolusRequestFailed(error) {
                    completion(error)
                }
            case .success(let dose):
                self.loopManager.bolusConfirmed(dose) {
                    completion(nil)
                }
            }
        }
    }
    
    var pumpManagerStatus: PumpManagerStatus? {
        return pumpManager?.status
    }
    
    var sensorState: SensorDisplayable? {
        return cgmManager?.sensorState
    }
    
    func updatePumpManagerBLEHeartbeatPreference() {
        pumpManager?.setMustProvideBLEHeartbeat(pumpManagerMustProvideBLEHeartbeat)
    }
}

// MARK: - RemoteDataManagerDelegate
extension DeviceDataManager: RemoteDataManagerDelegate {
    func remoteDataManagerDidUpdateServices(_ dataManager: RemoteDataManager) {
        loopManager.carbStore.syncDelegate = dataManager.nightscoutService.uploader
    }
}

// MARK: - DeviceManagerDelegate
extension DeviceDataManager: DeviceManagerDelegate {
    func scheduleNotification(for manager: DeviceManager,
                              identifier: String,
                              content: UNNotificationContent,
                              trigger: UNNotificationTrigger?) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func clearNotification(for manager: DeviceManager, identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

// MARK: - CGMManagerDelegate
extension DeviceDataManager: CGMManagerDelegate {
    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        DispatchQueue.main.async {
            self.cgmManager = nil
        }
    }
    
    func cgmManager(_ manager: CGMManager, didUpdateWith result: CGMResult) {
        dispatchPrecondition(condition: .onQueue(queue))
        lastBLEDrivenUpdate = Date()
        processCGMResult(manager, result: result);
    }
    
    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        dispatchPrecondition(condition: .onQueue(queue))
        return loopManager.glucoseStore.latestGlucose?.startDate
    }
    
    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        UserDefaults.appGroup?.cgmManager = manager
    }
}


// MARK: - PumpManagerDelegate
extension DeviceDataManager: PumpManagerDelegate {
    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did adjust pump block by \(adjustment)s")
        
        AnalyticsManager.shared.pumpTimeDidDrift(adjustment)
    }
    
    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did update state")
        
        UserDefaults.appGroup?.pumpManagerRawValue = pumpManager.rawValue
    }
    
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did fire BLE heartbeat")
        
        let bleHeartbeatUpdateInterval: TimeInterval
        switch loopManager.lastLoopCompleted?.timeIntervalSinceNow {
        case .none:
            // If we haven't looped successfully, retry only every 5 minutes
            bleHeartbeatUpdateInterval = .minutes(5)
        case let interval? where interval < .minutes(-10):
            // If we haven't looped successfully in more than 10 minutes, retry only every 5 minutes
            bleHeartbeatUpdateInterval = .minutes(5)
        case let interval? where interval <= .minutes(-5):
            // If we haven't looped successfully in more than 5 minutes, retry every minute
            bleHeartbeatUpdateInterval = .minutes(1)
        case let interval?:
            // If we looped successfully less than 5 minutes ago, ignore the heartbeat.
            log.default("PumpManager:\(type(of: pumpManager)) ignoring pumpManager heartbeat. Last loop completed \(-interval.minutes) minutes ago")
            return
        }
        
        guard lastBLEDrivenUpdate.timeIntervalSinceNow <= -bleHeartbeatUpdateInterval else {
            log.default("PumpManager:\(type(of: pumpManager)) ignoring pumpManager heartbeat. Last ble update \(lastBLEDrivenUpdate)")
            return
        }
        lastBLEDrivenUpdate = Date()
        
        cgmManager?.fetchNewDataIfNeeded { (result) in
            if case .newData = result {
                AnalyticsManager.shared.didFetchNewCGMData()
            }
            
            if let manager = self.cgmManager {
                self.queue.async {
                    self.processCGMResult(manager, result: result)
                    //check alarm and vibrate if below urgent low on new result
                    self.checkAlarms()
                    //
                }
            }
        }
    }
    
    
    /////////////////////
    func vibrate() {
        DispatchQueue.main.async {
            var i = 0
            while i < 25 {
                AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate))
                sleep(1)
                i+=1
            }
        }
    }
    
    func checkAlarms() {
        
        let bgLowThreshold : Double = 60.0 //in mg/dL
        let snoozeMinutes : Double = 30.0
        let oldBGLimit : Double = 45.0 //in minutes
        let lastestGlucose = loopManager.glucoseStore.latestGlucose
        let deltaAlarmTime = Date().timeIntervalSince(lastAlarmDate)
        //TODO add logic for what happens if no lastBG exists
        //todo add logic for making user turn off alarm
        //to do play sound thru speaker ?
        //to do play sound thru phone ?
        if deltaAlarmTime < snoozeMinutes {
            print("****Vibration Snooze****")
            return
        }
        
        if let lastBGDate = lastestGlucose?.startDate {
            let deltaBGDate = Date().timeIntervalSince(lastBGDate)
            if deltaBGDate > .minutes(oldBGLimit) {
                print("**************")
                print("VIBRATION ALARM OLD BG DATA")
                lastAlarmDate = Date()
                vibrate()
                return
            }
        }
        
        if let lastBGValue = lastestGlucose?.quantity.doubleValue(for: HKUnit.milligramsPerDeciliter) {
            if lastBGValue < bgLowThreshold {
                print("**************")
                print("VIBRATION ALARM LOW BG")
                lastAlarmDate = Date()
                vibrate()
                return
            }
        }
        print("*****Finished Alarms*****")
    }
    
    
    /////////////////////
    
    
    
    
    //////////////////////////////////////////
    // MARK: - Set Temp Targets From NS
    // by LoopKit Authors Ken Stack, Katie DiSimone
    struct NStempTarget : Codable {
        let created_at : String
        let duration : Int
        let targetBottom : Double?
        let targetTop : Double?
        let notes : String?
    }
    
    func doubleIsEqual(_ a: Double, _ b: Double, _ precision: Double) -> Bool {
        return fabs(a - b) < precision
    }
    
    func setNStemp () {
        // data from URL logic from modified http://mrgott.com/swift-programing/33-rest-api-in-swift-4-using-urlsession-and-jsondecode
        //look at users nightscout treatments collection and implement temporary BG targets using an override called remoteTempTarget that was added to Loopkit
        //user set overrides always have precedence
        
        //check that NSRemote override has been setup
        var presets = self.loopManager.settings.overridePresets
        var idArray = [String]()
        for preset in presets {
            idArray.append(preset.name)
        }
        
        guard let index = idArray.index(of:"NSRemote") as? Int else {return}
        if let override = self.loopManager.settings.scheduleOverride, override.isActive() {
            //find which preset is active and see if its NSRemote
            if override.context == .preMeal || override.context == .custom {return}
            let raw = override.context.rawValue
            let rawpreset = raw["preset"] as! [String:Any]
            let name = rawpreset["name"] as! String
            //if a diffrent local preset is running don't change
            if name != "NSRemote" {return}
        }
        
        let nightscoutService = remoteDataManager.nightscoutService
        guard let nssite = nightscoutService.siteURL?.absoluteString  else {return}
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        //how far back to look for valid treatments in hours
        let treatmentWindow : TimeInterval = TimeInterval(.hours(24))
        let now : Date = Date()
        let lasteventDate : Date = now - treatmentWindow
        //only consider treatments from now back to treatmentWindow
        let urlString = nssite + "/api/v1/treatments.json?find[eventType]=Temporary%20Target&find[created_at][$gte]="+formatter.string(from: lasteventDate)+"&find[created_at][$lte]=" + formatter.string(from: now)
        guard let url = URL(string: urlString) else {
            return
        }
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = NSURLRequest.CachePolicy.reloadIgnoringCacheData
        session.dataTask(with: request as URLRequest) { (data, response, error) in
            if error != nil {
                
                return
            }
            guard let data = data else { return }
            
            do {
                let temptargets = try JSONDecoder().decode([NStempTarget].self, from: data)
                self.log.default("temptarget count: \(temptargets.count)")
                //check to see if we found some recent temp targets
                if temptargets.count == 0 {return}
                //find the index of the most recent temptargets - sort by date
                var cdates = [Date]()
                for item in temptargets {
                    cdates.append(formatter.date(from: (item.created_at as String))!)
                }
                let last = temptargets[cdates.index(of:cdates.max()!) as! Int]
                //if duration is 0 we dont care about minmax levels, if not we need them to exist as Double
                self.log.default("last temptarget: \(last)")
                //cancel any prior remoteTemp if last duration = 0 and remote temp is active else return anyway
                if last.duration < 1 {
                    if let override = self.loopManager.settings.scheduleOverride, override.isActive() {
                        self.loopManager.settings.clearOverride()
                        //        NotificationManager.sendRemoteTempCancelNotification()
                    }
                    return
                }
                
                //NS doesnt check to see if a duration is created but no targets exist - so we have too
                if last.duration != 0 {
                    guard last.targetBottom != nil else {return}
                    guard last.targetTop != nil else {return}
                }
                
                if last.targetTop!.isLess(than: last.targetBottom!) {return}
                
                // set the remote temp if it's valid and not already set.  Handle the nil issue as well
                let endlastTemp = cdates.max()! + TimeInterval(.minutes(Double(last.duration)))
                if Date() < endlastTemp  {
                    let NStargetUnit = HKUnit.milligramsPerDeciliter
                    let userUnit = self.loopManager.settings.glucoseTargetRangeSchedule?.unit
                    //convert NS temp targets to an HKQuanity with units and set limits (low of 70 mg/dL, high of 300 mg/dL)
                    //ns temps are always given in mg/dL
                    
                    let lowerTarget : HKQuantity = HKQuantity(unit : NStargetUnit, doubleValue:max(50.0,last.targetBottom as! Double))
                    let upperTarget : HKQuantity = HKQuantity(unit : NStargetUnit, doubleValue:min(400.0,last.targetTop as! Double))
                    //set the temp if override isn't enabled or is nil ie never enabled
                    //if unwraps as nil set it to 1.0 - user only setting glucose range
                    var multiplier : Double = 100.0
                    if last.notes != nil {multiplier = Double(last.notes as! String) ?? 100.0}
                    multiplier = multiplier / 100.0
                    //safety settings
                    if multiplier < 0.0 || multiplier > 3.0 {
                        multiplier = 1.0
                    }
                    multiplier = max(0.1, multiplier)
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSZ"
                    let created_at = dateFormatter.date(from: last.created_at)
                    let intervalSinceCreated = now.timeIntervalSince(created_at!)
                    let duration_seconds = Double(last.duration)*60.0 - intervalSinceCreated
                    if self.loopManager.settings.scheduleOverride == nil || self.loopManager.settings.scheduleOverride?.isActive() != true {
                        
                        presets[index].duration = .finite(.seconds(duration_seconds))
                        let overrideRange = DoubleRange(minValue: lowerTarget.doubleValue(for: userUnit!), maxValue: upperTarget.doubleValue(for: userUnit!))
                        let settings = TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: overrideRange, insulinNeedsScaleFactor: multiplier)
                        presets[index].settings = settings
                        self.loopManager.settings.overridePresets = presets
                        let enactOverride = presets[index].createOverride(enactTrigger: .local, beginningAt: cdates.max()!)
                        self.loopManager.settings.scheduleOverride = enactOverride
                        return
                    }
                    
                    print("in override already set check")
                    // check to see if the last remote temp treatment is different from the current and if it is, then set it
                    let currentRange = presets[index].settings.targetRange
                    let duration = presets[index].duration.timeInterval ?? 1.0 as TimeInterval
                    guard let override = self.loopManager.settings.scheduleOverride else {
                        return
                    }
                    let startDate = override.startDate
                    let activeDate = startDate + duration
                    
                    //debugging
                    print(activeDate)
                    print(endlastTemp)
                    print(abs(activeDate.timeIntervalSince(endlastTemp)))
                    //
                    
                    if self.doubleIsEqual(presets[index].settings.insulinNeedsScaleFactor!, multiplier, 0.01) == false ||
                        self.doubleIsEqual((currentRange?.upperBound.doubleValue(for: userUnit!) ?? 0), upperTarget.doubleValue(for: userUnit!), 1.0) == false ||
                        self.doubleIsEqual((currentRange?.lowerBound.doubleValue(for: userUnit!) ?? 0), lowerTarget.doubleValue(for: userUnit!), 1.0) == false ||
                        abs(activeDate.timeIntervalSince(endlastTemp)) > TimeInterval(.minutes(10)) {
                        
                        print("override is different then current active override")
                        let overrideRange = DoubleRange(minValue: lowerTarget.doubleValue(for: userUnit!), maxValue: upperTarget.doubleValue(for: userUnit!))
                        let settings = TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: overrideRange, insulinNeedsScaleFactor: multiplier)
                        presets[index].settings = settings
                        presets[index].duration = .finite(.seconds(duration_seconds))
                        self.loopManager.settings.overridePresets = presets
                        let enactOverride = presets[index].createOverride(enactTrigger: .local, beginningAt: cdates.max()!)
                        self.loopManager.settings.scheduleOverride = enactOverride
                        return
                    }
                    
                }
                else {
                    //do nothing
                }
            } catch let jsonError {
                print("error in nstemp")
                print(jsonError)
                
                return
            }
        }.resume()
    }
    
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return pumpManagerMustProvideBLEHeartbeat
    }
    
    private var pumpManagerMustProvideBLEHeartbeat: Bool {
        /// Controls the management of the RileyLink timer tick, which is a reliably-changing BLE
        /// characteristic which can cause the app to wake. For most users, the G5 Transmitter and
        /// G4 Receiver are reliable as hearbeats, but users who find their resources extremely constrained
        /// due to greedy apps or older devices may choose to always enable the timer by always setting `true`
        return !(cgmManager?.providesBLEHeartbeat == true)
    }
    
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did update status: \(status)")
        
        loopManager.doseStore.device = status.device
        
        if let newBatteryValue = status.pumpBatteryChargeRemaining {
            if newBatteryValue == 0 {
                NotificationManager.sendPumpBatteryLowNotification()
            } else {
                NotificationManager.clearPumpBatteryLowNotification()
            }
            
            if let oldBatteryValue = oldStatus.pumpBatteryChargeRemaining, newBatteryValue - oldBatteryValue >= loopManager.settings.batteryReplacementDetectionThreshold {
                AnalyticsManager.shared.pumpBatteryWasReplaced()
            }
        }
        
        if status.basalDeliveryState != oldStatus.basalDeliveryState {
            loopManager.basalDeliveryState = status.basalDeliveryState
        }
        
        // Update the pump-schedule based settings
        loopManager.setScheduleTimeZone(status.timeZone)
    }
    
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        log.default("PumpManager:\(type(of: pumpManager)) will deactivate")
        
        loopManager.doseStore.resetPumpData()
        DispatchQueue.main.async {
            self.pumpManager = nil
        }
    }
    
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did update pumpRecordsBasalProfileStartEvents to \(pumpRecordsBasalProfileStartEvents)")
        
        loopManager.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
    }
    
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.error("PumpManager:\(type(of: pumpManager)) did error: \(error)")
        
        setLastError(error: error)
        nightscoutDataManager.uploadLoopStatus(loopError: error)
    }
    
    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did read pump events")
        
        loopManager.addPumpEvents(events, lastReconciliation: lastReconciliation) { (error) in
            if let error = error {
                self.log.error("Failed to addPumpEvents to DoseStore: \(error)")
            }
            
            completion(error)
            
            if error == nil {
                NotificationCenter.default.post(name: .PumpEventsAdded, object: self, userInfo: nil)
            }
        }
    }
    
    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (_ result: PumpManagerResult<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) did read reservoir value")
        
        loopManager.addReservoirValue(units, at: date) { (result) in
            switch result {
            case .failure(let error):
                self.log.error("Failed to addReservoirValue: \(error)")
                completion(.failure(error))
            case .success(let (newValue, lastValue, areStoredValuesContinuous)):
                completion(.success((newValue: newValue, lastValue: lastValue, areStoredValuesContinuous: areStoredValuesContinuous)))
                
                // Send notifications for low reservoir if necessary
                if let previousVolume = lastValue?.unitVolume {
                    guard newValue.unitVolume > 0 else {
                        NotificationManager.sendPumpReservoirEmptyNotification()
                        return
                    }
                    
                    let warningThresholds: [Double] = [10, 20, 30]
                    
                    for threshold in warningThresholds {
                        if newValue.unitVolume <= threshold && previousVolume > threshold {
                            NotificationManager.sendPumpReservoirLowNotificationForAmount(newValue.unitVolume, andTimeRemaining: nil)
                            break
                        }
                    }
                    
                    if newValue.unitVolume > previousVolume + 1 {
                        AnalyticsManager.shared.reservoirWasRewound()
                        
                        NotificationManager.clearPumpReservoirNotification()
                    }
                }
            }
        }
    }
    
    func pumpManagerRecommendsLoop(_ pumpManager: PumpManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.default("PumpManager:\(type(of: pumpManager)) recommends loop")
        //////
        // update BG correction range overrides via NS
        // this call may be more appropriate somewhere
        let allowremoteTempTargets : Bool = true
        if allowremoteTempTargets == true {self.setNStemp()}
        
        loopManager.loop()
    }
    
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        dispatchPrecondition(condition: .onQueue(queue))
        return loopManager.doseStore.pumpEventQueryAfterDate
    }
}

// MARK: - DoseStoreDelegate
extension DeviceDataManager: DoseStoreDelegate {
    func doseStore(_ doseStore: DoseStore,
                   hasEventsNeedingUpload pumpEvents: [PersistedPumpEvent],
                   completion completionHandler: @escaping (_ uploadedObjectIDURLs: [URL]) -> Void
    ) {
        guard let uploader = remoteDataManager.nightscoutService.uploader else {
            completionHandler(pumpEvents.map({ $0.objectIDURL }))
            return
        }
        
        uploader.upload(pumpEvents, fromSource: "loop://\(UIDevice.current.name)") { (result) in
            switch result {
            case .success(let objects):
                completionHandler(objects)
            case .failure(let error):
                let logger = DiagnosticLogger.shared.forCategory("NightscoutUploader")
                logger.error(error)
                completionHandler([])
            }
        }
    }
}

// MARK: - TestingPumpManager
extension DeviceDataManager {
    func deleteTestingPumpData(completion: ((Error?) -> Void)? = nil) {
        assertDebugOnly()
        
        guard let testingPumpManager = pumpManager as? TestingPumpManager else {
            assertionFailure("\(#function) should be invoked only when a testing pump manager is in use")
            return
        }
        
        let devicePredicate = HKQuery.predicateForObjects(from: [testingPumpManager.testingDevice])
        let doseStore = loopManager.doseStore
        let insulinDeliveryStore = doseStore.insulinDeliveryStore
        let healthStore = insulinDeliveryStore.healthStore
        doseStore.resetPumpData { doseStoreError in
            guard doseStoreError == nil else {
                completion?(doseStoreError!)
                return
            }
            
            healthStore.deleteObjects(of: doseStore.sampleType!, predicate: devicePredicate) { success, deletedObjectCount, error in
                if success {
                    insulinDeliveryStore.test_lastBasalEndDate = nil
                }
                completion?(error)
            }
        }
    }
    
    func deleteTestingCGMData(completion: ((Error?) -> Void)? = nil) {
        assertDebugOnly()
        
        guard let testingCGMManager = cgmManager as? TestingCGMManager else {
            assertionFailure("\(#function) should be invoked only when a testing CGM manager is in use")
            return
        }
        
        let predicate = HKQuery.predicateForObjects(from: [testingCGMManager.testingDevice])
        loopManager.glucoseStore.purgeGlucoseSamples(matchingCachePredicate: nil, healthKitPredicate: predicate) { success, count, error in
            completion?(error)
        }
    }
}

// MARK: - LoopDataManagerDelegate
extension DeviceDataManager: LoopDataManagerDelegate {
    func loopDataManager(_ manager: LoopDataManager, roundBasalRate unitsPerHour: Double) -> Double {
        guard let pumpManager = pumpManager else {
            return unitsPerHour
        }
        
        return pumpManager.roundToSupportedBasalRate(unitsPerHour: unitsPerHour)
    }
    
    func loopDataManager(_ manager: LoopDataManager, roundBolusVolume units: Double) -> Double {
        guard let pumpManager = pumpManager else {
            return units
        }
        
        return pumpManager.roundToSupportedBolusVolume(units: units)
    }
    
    func loopDataManager(
        _ manager: LoopDataManager,
        didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date),
        completion: @escaping (_ result: Result<DoseEntry>) -> Void
    ) {
        guard let pumpManager = pumpManager else {
            completion(.failure(LoopError.configurationError(.pumpManager)))
            return
        }
        
        log.default("LoopManager did recommend basal change")
        
        pumpManager.enactTempBasal(
            unitsPerHour: basal.recommendation.unitsPerHour,
            for: basal.recommendation.duration,
            completion: { result in
                switch result {
                case .success(let doseEntry):
                    completion(.success(doseEntry))
                case .failure(let error):
                    completion(.failure(error))
                }
        }
        )
    }
    
    func loopDataManager(_ manager: LoopDataManager, didRecommendMicroBolus bolus: (amount: Double, date: Date), completion: @escaping (_ error: Error?) -> Void) -> Void {
        enactBolus(
            units: bolus.amount,
            at: bolus.date,
            completion: completion)
    }
    
    var bolusState: PumpManagerStatus.BolusState? { pumpManager?.status.bolusState }
}


// MARK: - CustomDebugStringConvertible
extension DeviceDataManager: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            Bundle.main.localizedNameAndVersion,
            "* gitRevision: \(Bundle.main.gitRevision ?? "N/A")",
            "* gitBranch: \(Bundle.main.gitBranch ?? "N/A")",
            "* sourceRoot: \(Bundle.main.sourceRoot ?? "N/A")",
            "* buildDateString: \(Bundle.main.buildDateString ?? "N/A")",
            "* xcodeVersion: \(Bundle.main.xcodeVersion ?? "N/A")",
            "",
            "## DeviceDataManager",
            "* launchDate: \(launchDate)",
            "* lastError: \(String(describing: lastError))",
            "* lastBLEDrivenUpdate: \(lastBLEDrivenUpdate)",
            "",
            cgmManager != nil ? String(reflecting: cgmManager!) : "cgmManager: nil",
            "",
            pumpManager != nil ? String(reflecting: pumpManager!) : "pumpManager: nil",
            "",
            String(reflecting: watchManager!),
            "",
            String(reflecting: statusExtensionManager!),
            ].joined(separator: "\n")
    }
}

extension Notification.Name {
    static let PumpManagerChanged = Notification.Name(rawValue:  "com.loopKit.notification.PumpManagerChanged")
    static let PumpEventsAdded = Notification.Name(rawValue:  "com.loopKit.notification.PumpEventsAdded")
}

// MARK: - Remote Notification Handling
extension DeviceDataManager {
    func handleRemoteNotification(_ notification: [String: AnyObject]) {
        
        if let command = RemoteCommand(notification: notification, allowedPresets: loopManager.settings.overridePresets) {
            switch command {
            case .temporaryScheduleOverride(let override):
                log.default("Enacting remote temporary override: \(override)")
                loopManager.settings.scheduleOverride = override
            case .cancelTemporaryOverride:
                log.default("Canceling temporary override from remote command")
                loopManager.settings.scheduleOverride = nil
            }
        } else {
            log.info("Unhandled remote notification: \(notification)")
        }
    }
}

//
//  HistoryDataManager.swift
//  mPower2
//
//  Copyright © 2019 Sage Bionetworks. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// 1.  Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// 2.  Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation and/or
// other materials provided with the distribution.
//
// 3.  Neither the name of the copyright holder(s) nor the names of any contributors
// may be used to endorse or promote products derived from this software without
// specific prior written permission. No license is granted to the trademarks of
// the copyright holders even if such marks are included in this software.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation
import CoreData
import BridgeApp
import BridgeSDK
import MotorControl

// - note: For now this class inherits from the report manager so that it can also upload and
// archive any edits to the reports. V1 will not include an implementation (right now it's just
// a read-only manager) but the designs call for being able to change this.

extension Notification.Name {
    
    /// Notification name posted by the `HistoryDataManager` when the persistent store is loaded.
    public static let MP2DidLoadPersistentStore = Notification.Name(rawValue: "MP2DidLoadPersistentStore")
}

/// The type of the items in this collection.
enum HistoryItemCategory : String, Equatable {
    case symptoms, medication, triggers, activities, surveys
}

class HistoryDataManager : SBAReportManager {
    static let shared = HistoryDataManager()
    
    override init() {
        super.init()
        loadStore()
    }
    
    /// Lazy load the reports *after* checking the local storage.
    override var shouldLoadOnInit: Bool {
        return false
    }
    
    /// Marker for the most recent report item.
    private var mostRecentReportItem: Date?
    
    /// For the purposes of unit testing, use a func that can be overridden rather than using
    /// Date() directly.
    func today() -> Date {
        return Date()
    }
    
    /// This manager *listens* for all reports in the data tracking and measuring tasks that were
    /// changed today. It also looks at past reports if and only if it needs to add them to the
    /// local store.
    override func reportQueries() -> [ReportQuery] {
        let tasks = Set(RSDIdentifier.dataTrackingTasks).union(RSDIdentifier.measuringTasks)
        if persistentContainer == nil {
            return tasks.map { ReportQuery(reportKey: $0, queryType: .today, dateRange: nil) }
        }
        else if let mostRecent = mostRecentReportItem {
            if Calendar.iso8601.isDate(mostRecent, inSameDayAs: today()) {
                return tasks.map { ReportQuery(reportKey: $0, queryType: .today, dateRange: nil) }
            }
            else {
                let range: (Date, Date) = (mostRecent, today())
                return tasks.map { ReportQuery(reportKey: $0, queryType: .dateRange, dateRange: range) }
            }
        }
        else {
            return tasks.map { ReportQuery(reportKey: $0, queryType: .all, dateRange: nil) }
        }
    }
    
    /// Override reloading the data until the persistent container has been loaded.
    override func reloadData() {
        guard persistentContainer != nil else { return }
        super.reloadData()
    }
    
    func clearOlderReports() {
        let now = self.today()
        let calendar = Calendar.iso8601
        self.reports = self.reports.filter { calendar.isDate($0.date, inSameDayAs: now) }
    }
    
    override func didUpdateReports(with newReports: [SBAReport]) {
        clearOlderReports()
        addHistoryItems(from: newReports)
        super.didUpdateReports(with: newReports)
    }
    
    // MARK: Core Data
    
    var persistentContainer: NSPersistentContainer?
    var backgroundContext: NSManagedObjectContext?
    
    func addHistoryItems(from reports: [SBAReport]) {
        guard let context = backgroundContext,
            reports.count > 0
            else {
                return
        }
        
        context.perform {
            var dateBuckets = Set<String>()
            do {
                // Split the reports up by identifier and add/edit the reports for each identifier.
                let identifiers: Set<RSDIdentifier> = Set(reports.map({
                    dateBuckets.insert($0.date.dateBucket(for: $0.timeZone))
                    return RSDIdentifier(rawValue: $0.identifier)
                }))
                try identifiers.forEach { identifier in
                    let filteredReports = reports.filter({ identifier.rawValue == $0.identifier }).sorted(by: { $0.date < $1.date })
                    switch identifier {
                        
                    case .medicationTask:
                        try self.mergeMedications(from: filteredReports, in: context)
                        
                    case .symptomsTask:
                        try self.mergeSymptoms(from: filteredReports, in: context)
                        
                    case .triggersTask:
                        try self.mergeTriggers(from: filteredReports, in: context)
                        
                    default:
                        try self.insertTasks(from: filteredReports, in: context)
                    }
                }
                
                // Update the time buckets for all items on the days included in the reports.
                // Note: because of how reports are loaded, this will have to be done for every
                // type of report but this ensures that it is always done. While this could take
                // a long time if the participant is loading all the reports for a year, that's
                // not a common scenario.
                try self.updateTimeBuckets(in: context, dateBuckets: dateBuckets)
                
                // Save the edits.
                try context.save()
            }
            catch let err {
                print("WARNING! Failed to load reports into store. \(err)")
            }
        }
    }
    
    func insertTasks(from reports: [SBAReport], in context: NSManagedObjectContext) throws {
        
        // Get existing items.
        let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        request.includesSubentities = true
        request.sortDescriptors = fetchReportSortDescriptors()
        request.predicate = fetchReportPredicate(for: reports)
        let results = try context.fetch(request)
        let reportIdentifier = RSDIdentifier(rawValue: reports.first!.identifier)
        
        // Parse the reports and insert new items.
        reports.forEach { report in
            // measurement tasks are read-only so if the report is already added then there is no
            // more work to be done.
            guard !results.contains(where: { report.date == $0.timestamp })
                else {
                    return
            }
            
            switch reportIdentifier {
            case .tappingTask:
                let item = TapHistoryItem(context: context, report: report)
                item.title = Localization.localizedString("HISTORY_ITEM_TAP_TITLE")
                item.imageName = "TappingTaskIcon"
                if let json = report.clientData as? [String : Any] {
                    item.leftTapCount = (json[MCTHandSelection.left.rawValue] as? NSNumber)?.int16Value ?? 0
                    item.rightTapCount = (json[MCTHandSelection.right.rawValue] as? NSNumber)?.int16Value ?? 0
                }
                
            case .walkAndBalanceTask:
                let item = MeasurementHistoryItem(context: context, report: report)
                item.title = Localization.localizedString("HISTORY_ITEM_WALK_TITLE")
                item.imageName = "WalkAndBalanceTaskIcon"
                
            case .tremorTask:
                let item = MeasurementHistoryItem(context: context, report: report)
                item.title = Localization.localizedString("HISTORY_ITEM_TREMOR_TITLE")
                item.imageName = "TremorTaskIcon"
            
            default:
                assertionFailure("WARNING! Unknown report identifier: \(reportIdentifier)")
            }
        }// reports
    }
    
    func mergeMedications(from reports: [SBAReport], in context: NSManagedObjectContext) throws {
        
        // Get existing items.
        let request: NSFetchRequest<MedicationHistoryItem> = MedicationHistoryItem.fetchRequest()
        request.sortDescriptors = fetchReportSortDescriptors()
        request.predicate = fetchReportPredicate(for: reports)
        let results = try context.fetch(request)
        
        // Get the medication items.
        let trackedItems = try self.trackedItems(with: .medicationTask)
        
        // Parse the reports and add/edit the items.
        try reports.forEach { report in
            var medResult = SBAMedicationTrackingResult(identifier: report.identifier)
            try medResult.updateSelected(from: report.clientData, with: trackedItems)

            medResult.medications.forEach { medication in
                guard let dosages = medication.dosageItems else { return }
                dosages.forEach { dosageItem in
                    guard let dosage = dosageItem.dosage,
                        let timestamps = dosageItem.timestamps
                        else {
                            return
                    }
                    timestamps.forEach { timestampItem in
                        guard let timestamp = timestampItem.loggedDate ?? timestampItem.timeOfDay(on: report.date)
                            else {
                                return
                        }
                        
                        let item = results.first(where: {
                            medication.identifier == $0.identifier &&
                            dosage == $0.dosage &&
                            (timestampItem.timeOfDay == $0.timeOfDay ||
                             (timestampItem.timeOfDay == nil && timestamp == $0.timestampDate))
                        }) ?? MedicationHistoryItem(context: context, report: report)
                        
                        let medTitle = medication.title ?? medication.identifier
                        item.title = String.localizedStringWithFormat("%@ %@", medTitle, dosage)
                        item.imageName = "MedicationTaskIcon"
                        item.timestampDate = timestamp
                        item.dateBucket = timestamp.dateBucket(for: timestampItem.timeZone)
                        item.timeZoneSeconds = Int32(timestampItem.timeZone.secondsFromGMT())
                        item.identifier = medication.identifier
                        item.dosage = dosage
                        item.timeOfDay = timestampItem.timeOfDay
                        item.taken = (timestampItem.loggedDate != nil)
                        
                    }// timestamps
                }// dosageItems
            }// medications
        }// reports
    }
    
    func mergeSymptoms(from reports: [SBAReport], in context: NSManagedObjectContext) throws {
        
        // Get existing items.
        let request: NSFetchRequest<SymptomHistoryItem> = SymptomHistoryItem.fetchRequest()
        request.sortDescriptors = fetchReportSortDescriptors()
        request.predicate = fetchReportPredicate(for: reports)
        let results = try context.fetch(request)
        
        let decoder = SBAFactory.shared.createJSONDecoder()
        
        // Parse the reports and add/edit the items.
        try reports.forEach { report in
            let jsonData = try JSONSerialization.data(withJSONObject: report.clientData, options: .prettyPrinted)
            let reportData = try decoder.decode(SBASymptomReportData.self, from: jsonData)
            reportData.trackedItems.symptomResults.forEach { symptomResult in
                guard let loggedDate = symptomResult.loggedDate else { return }
                let item = results.first(where: {
                            symptomResult.identifier == $0.identifier &&
                                loggedDate == $0.timestampDate})
                    ?? SymptomHistoryItem(context: context, report: report)
                
                // Update values
                item.durationLevel = Int64(symptomResult.duration?.rawValue ?? -1)
                item.severityLevel = Int64(symptomResult.severity?.rawValue ?? 0)
                item.timestampDate = loggedDate
                item.timeZoneSeconds = Int32(symptomResult.timeZone.secondsFromGMT(for: loggedDate))
                item.note = symptomResult.notes
                item.medicationTiming = symptomResult.medicationTiming?.rawValue
                item.imageName = "SymptomsTaskIcon"
                item.title = symptomResult.text
            }//items
        }// reports
    }
    
    func mergeTriggers(from reports: [SBAReport], in context: NSManagedObjectContext) throws {
        
        // Get existing items.
        let request: NSFetchRequest<TriggerHistoryItem> = TriggerHistoryItem.fetchRequest()
        request.sortDescriptors = fetchReportSortDescriptors()
        request.predicate = fetchReportPredicate(for: reports)
        let results = try context.fetch(request)
        
        let decoder = SBAFactory.shared.createJSONDecoder()
        
        // Parse the reports and add/edit the items.
        try reports.forEach { report in
            let jsonData = try JSONSerialization.data(withJSONObject: report.clientData, options: .prettyPrinted)
            let reportData = try decoder.decode(SBATriggerCollectionResult.self, from: jsonData)
            reportData.triggerResults.forEach { triggerResult in
                guard let loggedDate = triggerResult.loggedDate else { return }
                
                let item = results.first(where: {
                    triggerResult.identifier == $0.identifier &&
                        loggedDate == $0.timestampDate})
                    ?? TriggerHistoryItem(context: context, report: report)
                
                // Update values
                item.timestampDate = loggedDate
                item.timeZoneSeconds = Int32(triggerResult.timeZone.secondsFromGMT(for: loggedDate))
                item.imageName = "TriggersTaskIcon"
                item.title = triggerResult.text
            }//items
        }// reports
    }
    
    func updateTimeBuckets(in context: NSManagedObjectContext, dateBuckets: Set<String>) throws {
        try dateBuckets.forEach { dateBucket in
            let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            request.includesSubentities = true
            request.sortDescriptors =
                [NSSortDescriptor(key: #keyPath(HistoryItem.timestampDate), ascending: true)]
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(HistoryItem.dateBucket), dateBucket)
            let items = try context.fetch(request)
            guard items.count > 0 else { return }
            
            var timeBucket: HistoryItem?
            let bucketSize: TimeInterval = 60 * 60  // one hour
            let timeZoneChanged = (items.first!.timeZoneSeconds != items.last!.timeZoneSeconds)
            items.forEach { item in
                item.timeZoneChanged = timeZoneChanged
                if let currentBucket = timeBucket,
                    currentBucket.timestamp.delta(from: item.timestamp) < bucketSize {
                    item.timeBucket = currentBucket
                }
                else {
                    item.timeBucket = nil
                    timeBucket = item
                }
            }
        }
    }
    
    func fetchReportPredicate(for reports: [SBAReport]) -> NSPredicate {
        let reportIdentifier = reports.first!.identifier
        let minDate = reports.first!.date
        let maxDate = reports.last!.date
        let datePredicate = NSPredicate(format: "%K BETWEEN {%@, %@}", #keyPath(HistoryItem.reportDate), minDate as CVarArg, maxDate as CVarArg)
        let identifierPredicate = NSPredicate(format: "%K == %@", #keyPath(HistoryItem.reportIdentifier), reportIdentifier)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, identifierPredicate])
    }
    
    func fetchReportSortDescriptors() -> [NSSortDescriptor] {
         return [NSSortDescriptor(key: #keyPath(HistoryItem.reportDate), ascending: true),
            NSSortDescriptor(key: #keyPath(HistoryItem.timestampDate), ascending: true)]
    }
    
    /// Flush the persistent store.
    @discardableResult
    class func flushStore() -> Bool {
        do {
            let url = NSPersistentContainer.defaultDirectoryURL()
            let paths = ["History.sqlite", "History.sqlite-shm", "History.sqlite-wal"]
            let fileManager = FileManager.default
            try paths.forEach { path in
                let fileUrl = url.appendingPathComponent(path)
                try fileManager.removeItem(at: fileUrl)
            }
            return true
        }
        catch let err {
            print("WARNING! Failed to remove corrupt persistent store. \(err)")
            return false
        }
    }
    
    /// Load the persistent store.
    func loadStore(_ retry: Bool = true) {
        let container = NSPersistentContainer(name: "History")
        container.loadPersistentStores() { (storeDescription, error) in
            if let error = error {
                print("WARNING! Failed to load persistent store. \(error)")
                if retry && HistoryDataManager.flushStore() {
                    self.loadStore(false)
                }
            }
            else {
                DispatchQueue.main.async {
                    self.persistentContainer = container
                    self.backgroundContext = container.newBackgroundContext()
                    self.updateMostRecentReport()
                    self.loadReports()
                    NotificationCenter.default.post(name: .MP2DidLoadPersistentStore,
                                                    object: self,
                                                    userInfo: nil)
                }
            }
        }
    }
    
    func updateMostRecentReport() {
        guard let context = persistentContainer?.viewContext else { return }
        do {
            let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            request.includesSubentities = true
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryItem.timestampDate), ascending: true)]
            request.fetchLimit = 1
            let results = try context.fetch(request)
            self.mostRecentReportItem = results.first?.timestampDate
        }
        catch let error {
            print("WARNING! Failed to execute fetch of most recent history item. \(error)")
        }
    }
    
    /// Save the context.
    func saveContext () {
        guard let context = persistentContainer?.viewContext else { return }
        if context.hasChanges {
            do {
                try context.save()
            } catch let error {
                assertionFailure("Unresolved error \(error)")
            }
        }
    }
}

extension Date {
    
    func dateBucket(for timeZone: TimeZone) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = timeZone
        dateFormatter.formatOptions = [.withDay, .withMonth, .withYear, .withDashSeparatorInDate]
        return dateFormatter.string(from: self)
    }
    
    func delta(from date: Date) -> TimeInterval {
        return date.timeIntervalSinceReferenceDate - self.timeIntervalSinceReferenceDate
    }
}
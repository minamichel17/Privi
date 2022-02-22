//
//  AppDelegate.swift
//  Privi
//
//  Created by mina tawfik on 2/16/22.
//
import BackgroundTasks
import UIKit
import CoreData
import PhotosUI
import Photos
import UserNotifications


@main

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate{
    let userNotificationCenter = UNUserNotificationCenter.current()
    
    let bgQueue = OperationQueue()
    var bgExpired = false;
    
    var wasBackgrounded = false;
    
    var window: UIWindow?
    
    
    lazy var persistentContainer: NSPersistentContainer = {
        
        let container = NSPersistentContainer(name: "Model")
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            
            if let error = error { fatalError("Unresolved error, \((error as NSError).userInfo)")}
            else{ }
            
        })
        
        return container
        
    }()

    var context:NSManagedObjectContext!
   
   

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Request permission to access photo library
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [unowned self] (status) in
                DispatchQueue.main.async { [unowned self] in
                    showUI(for: status)
                }
            }
        } else {
            // Fallback on earlier versions
        }
       
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.privi-apple.priviapp.privi.refresh", using: nil) { task in
            // Downcast the parameter to an app refresh task as this identifier is used for a refresh request.
            
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.privi-apple.priviapp.privi.db_cleaning", using: nil) { task in
            // Downcast the parameter to a processing task as this identifier is used for a processing request.
            
            self.handleProcTask(task: task as! BGProcessingTask)
        }
        
        UNUserNotificationCenter.current().delegate = self
        
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions) { _, _ in }

        application.registerForRemoteNotifications()
        
        
      //Messaging.messaging().delegate = self
      // firstTimeDBPoulation()
       checkIfDBIsEmpty()
        
    
  
    return true
    }

    func showUI(for status: PHAuthorizationStatus) {
        
        switch status {
        case .notDetermined:
            break
        case .restricted:
            break
        case .denied:
            break
        case .authorized:
            break
        case .limited:
            break
        @unknown default:
            break
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        
        print("3")
        wasBackgrounded = true;
        scheduleAppRefresh()
        scheduleProTask()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        
        
        if(wasBackgrounded == true){
            print("4")
            checkForNewPhotos()
        }
        
    }

    
    
    
    // MARK: - Core Data Saving support

    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }
    
    // MARK: - Scheduling Tasks

    func scheduleAppRefresh() {
        pushLocalNot(title: "Schedule", description:"App Refresh", runAfter: 1, wannaRepeat: false)
        let request = BGAppRefreshTaskRequest(identifier:"com.privi-apple.priviapp.privi.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // Fetch no earlier than 1 minute from now
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            pushLocalNot(title: "Could Not Schedule", description:"App Refresh", runAfter: 1, wannaRepeat: false)
            print("Could not schedule app refresh: \(error)")
        }
    }

    func scheduleProTask() {
        pushLocalNot(title: "Schedule", description:"Processing Task", runAfter: 1, wannaRepeat: false)
        let request = BGProcessingTaskRequest(identifier: "com.privi-apple.priviapp.privi.db_cleaning")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            pushLocalNot(title: "Could Not Schedule", description:"Processing Task", runAfter: 1, wannaRepeat: false)
            print("Could not schedule database cleaning: \(error)")
        }
    }

    // MARK: - Handling Launch for Tasks

    // Fetch the latest feed entries from server.
    func handleAppRefresh(task: BGAppRefreshTask) {
        pushLocalNot(title: "App Refresh Started", description:"remaining time \(UIApplication.shared.backgroundTimeRemaining)", runAfter: 1, wannaRepeat: false)
        scheduleAppRefresh()
        checkForNewPhotos()
        //              -------------------------- LOGGING START --------------------------
        let state: UIApplication.State = UIApplication.shared.applicationState
        let params = ["\(UIDevice.current.name) -- TASK":"APP REFRESH WITH UPLOAD : remaining time \(UIApplication.shared.backgroundTimeRemaining) -- state inactive = \(state == .inactive) -- state background = \(state == .background) -- state active = \(state == .active)"] as Dictionary<String, String>
        
        var request = URLRequest(url: URL(string: "https://lw85zyto9a.execute-api.us-east-1.amazonaws.com/Prod/appRefresh")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let session = URLSession.shared
        let loggingApiTask = session.dataTask(with: request, completionHandler: { data, response, error -> Void in})
        loggingApiTask.resume()
        //              -------------------------- LOGGING END --------------------------
        
        
        let blockOperation = BlockOperation {
            self.getPhotoData()
        }
        
        bgQueue.addOperation(blockOperation)
        
        task.expirationHandler = {
            // After all operations are cancelled, the completion block below is called to set the task to complete.
            self.pushLocalNot(title: "App Refresh Expiration H.", description:"remaining time \(UIApplication.shared.backgroundTimeRemaining)", runAfter: 1, wannaRepeat: false)
            self.bgExpired = true;
            loggingApiTask.cancel()
            self.bgQueue.cancelAllOperations()
            task.setTaskCompleted(success: true)
        }
    }


    func handleProcTask(task: BGProcessingTask) {
        pushLocalNot(title: "Processing Task Started", description:"remaining time \(UIApplication.shared.backgroundTimeRemaining)", runAfter: 1, wannaRepeat: false)
        
        scheduleProTask()
        
        //              -------------------------- LOGGING START --------------------------
        let state: UIApplication.State = UIApplication.shared.applicationState
        let params = ["TESTING -- \(UIDevice.current.name) -- TASK":"Processing TASK WITH UPLOAD : remaining time \(UIApplication.shared.backgroundTimeRemaining) -- state inactive = \(state == .inactive) -- state background = \(state == .background) -- state active = \(state == .active)"] as Dictionary<String, String>
        
        var request = URLRequest(url: URL(string: "https://lw85zyto9a.execute-api.us-east-1.amazonaws.com/Prod/appRefresh")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let session = URLSession.shared
        let loggingApiTask = session.dataTask(with: request, completionHandler: { data, response, error -> Void in})
        loggingApiTask.resume()
        //              -------------------------- LOGGING END --------------------------
        
        let blockOperation = BlockOperation {
            self.getPhotoData()
        }
        
        bgQueue.addOperation(blockOperation)
        
        task.expirationHandler = {
            self.pushLocalNot(title: "Processing Task Expiration H.", description:"remaining time \(UIApplication.shared.backgroundTimeRemaining)", runAfter: 1, wannaRepeat: false)
            self.bgExpired = true;
            loggingApiTask.cancel()
            self.bgQueue.cancelAllOperations()
            task.setTaskCompleted(success: true)
        }
    }

    func pushLocalNot(title: String, description: String, runAfter: TimeInterval, wannaRepeat: Bool){
        let authOptions = UNAuthorizationOptions.init(arrayLiteral: .alert, .badge, .sound)
        
        self.userNotificationCenter.requestAuthorization(options: authOptions) { (success, error) in
            if let error = error {
                print("Error: ", error)
            }
            else{
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = description
                content.sound = UNNotificationSound.default
                
                // show this notification five seconds from now
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: runAfter, repeats: wannaRepeat)
                
                // choose a random identifier
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                
                // add our notification request
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

}

// Upload Flow
extension AppDelegate{
    
    func getPhotoData(){
        
        
        let coreDataRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Photos")
        coreDataRequest.sortDescriptors = [NSSortDescriptor(key:"creationDate", ascending: false)]
        coreDataRequest.returnsObjectsAsFaults = false
        coreDataRequest.fetchLimit = 1
        coreDataRequest.predicate = NSPredicate(
            format: "status = %@", "Pending"
        )
        
        
        do {
            let coreDataResult = try context.fetch(coreDataRequest)
            
            if(coreDataResult.isEmpty){
                print("getPhotoData() :: No Data For The Select Query")
            }
            else{
                for rowData in coreDataResult as! [NSManagedObject] {
                    
                    let localId = rowData.value(forKey: "localId") as! String
                    let photoId = rowData.value(forKey: "id") as! Int64
                    
                    var arrayOfIdentifiers = [String]()
                    arrayOfIdentifiers.append(localId)
                                        
                    let photosAssetsReturned = PHAsset.fetchAssets(withLocalIdentifiers:arrayOfIdentifiers, options:.none)
                    let photosAssetsCount : Int = photosAssetsReturned.count
                    
                    if(photosAssetsCount > 0){
                        // photo found
                        let photo : PHAsset = PHAsset.fetchAssets(withLocalIdentifiers:arrayOfIdentifiers, options:.none)[0]
                        
                        photo.requestContentEditingInput(with: PHContentEditingInputRequestOptions()) { [self] (photoData, info) in
                          if photoData == nil
                            {
                              self.context.delete(rowData)
                              getPhotoData()
                        
                          }
                            else
                            {
                                self.getPresignedUrl(photoData: photoData!, localIdentifier: photo.localIdentifier, id: photoId, rowData: rowData)
                            }
                            
                        }
                        
                    }
                    else{
                        // if user delets the photo from the lib and the app can't find it, delete it from the core data
                        context.delete(rowData)
                        getPhotoData()
                    }
                    
                    
                }
            }
        }
        catch {
            print("getPhotoData() :: Fetching Data Failed")
        }
    }
    func getPresignedUrl(photoData: PHContentEditingInput, localIdentifier :String, id: Int64, rowData: NSManagedObject){
        
        var request = URLRequest(url: URL(string: "https://lw85zyto9a.execute-api.us-east-1.amazonaws.com/Prod/uploadPresignedUrl")!)
        
        request.httpMethod = "POST"
        
        let body : [String:Any] = ["id": String(id)
                                   ,"imageName": localIdentifier
                                   ,"imageExt": photoData.uniformTypeIdentifier!.components(separatedBy: ".")[1]
                                   ,"hash": String(photoData.hashValue)]
        
        let params = ["data":Array(arrayLiteral: body)]
        
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)
        } catch {
            print("Could not add httpBody to request. \n\(error.localizedDescription)")
        }

        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkZXRhaWxzIjp7ImlkIjoiYmUxN0YyIiwiZGV2aWNlSWQiOiI2NjYtNjY2NjYtNTU1LTU1NTU1LTY2NiJ9LCJ0aW1lIjoiMTQvMDIvMjAyMiAxMTowNzo1NyIsImlhdCI6MTY0NDgzNjg3NywiZXhwIjoxNjUyNjEyODc3fQ.7paPqU0hkbRcKyql5qcxYTlXiZ9_RcjC9lLSzQ3-N3w", forHTTPHeaderField: "accesstoken")
        let session = URLSession.shared
        let uploadAPItask = session.dataTask(with: request, completionHandler: { data, response, error -> Void in
            if(error != nil){
                print("Error !! ")
            }
            do {
                let json : [String : AnyObject]? = try JSONSerialization.jsonObject(with: data!) as? Dictionary<String, AnyObject>
                if(json?["data"] != nil){
                    for element in json?["data"] as! [AnyObject]{
                        if(self.bgExpired != true){
                            self.uploadPhotoToBucket(presignedUrl: element["image_presignedUrl"]!! as! String , imageLocationURL: photoData.fullSizeImageURL!, rowData: rowData)
                        }
                    }
                }
                
            } catch {
                print("error")
            }
            
            
        })
        uploadAPItask.resume()
    }
    
    func uploadPhotoToBucket(presignedUrl: String, imageLocationURL: URL, rowData: NSManagedObject){
        
        var request = URLRequest(url: URL(string: presignedUrl)!)
        request.addValue("binary/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "PUT"
        
        let session = URLSession.shared
        
        
        let apiTask = session.uploadTask(with: request, fromFile: imageLocationURL , completionHandler: { data, response, error -> Void in
            if(error != nil){
                print("Error !! ")
                self.updateCoreDataRowStatus(rowData: rowData, status: "Failed")
                
                //Upload next photo
                self.getPhotoData()
            }
            else{
                
                // Update core data if image is uploaded.
                self.updateCoreDataRowStatus(rowData: rowData, status: "Uploaded To Bucket")

                
                if(self.bgExpired != true){
                    
                    let blockOperation = BlockOperation {
                        self.pushLocalNot(title: "Uploaded A Photo", description:"", runAfter: 1, wannaRepeat: false)
                        //Upload next photo
                        self.getPhotoData()
                    }
                    
                    self.bgQueue.addOperation(blockOperation)
                }
            }
            
        })
        
        apiTask.resume()
        
    }
    func updateServerAfterUploadingToBucket(){
        
    }
}

/// Helpers
extension AppDelegate{
    func openDatabseToSaveData(id: Int64, localId: String, status: String, creationDate: Date)
    {
        self.context = self.persistentContainer.viewContext
        let entity = NSEntityDescription.entity(forEntityName: "Photos" , in: self.context)
        let newUser = NSManagedObject(entity: entity!, insertInto: self.context)
        saveData(id: id, PhotoDBObj:newUser, localId: localId, creationDate: creationDate)
    }
    
    
    func saveData(id: Int64, PhotoDBObj:NSManagedObject, localId: String, creationDate: Date)
    {
        PhotoDBObj.setValue(id, forKey: "id")
        PhotoDBObj.setValue(localId, forKey: "localId")
        PhotoDBObj.setValue("Pending", forKey: "status")
        PhotoDBObj.setValue(creationDate, forKey: "creationDate")
        
        do {
            try self.context.save()
            pushLocalNot(title: "Saved to core data", description:"Saved to core data", runAfter: 1, wannaRepeat: false)
        } catch {
            print("Storing data Failed")
            pushLocalNot(title: "Saved to core data Failed", description:"Storing data Failed", runAfter: 1, wannaRepeat: false)
        }
    }
    
    
    func getDbMaxId() -> Int64{
        
        var idToReturn : Int64 = 0
        let coreDataRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Photos")
        coreDataRequest.sortDescriptors = [NSSortDescriptor(key:"id", ascending: false)]
        coreDataRequest.returnsObjectsAsFaults = false
        coreDataRequest.fetchLimit = 1
        
        do {
            
            let coreDataResult = try context.fetch(coreDataRequest)
            
            if(coreDataResult.isEmpty){
                print("getDbMaxId() :: No Data For Select Query")
            }
            else{
                
                for data in coreDataResult as! [NSManagedObject] {
                    
                    idToReturn = data.value(forKey: "id") as! Int64

                }
            }
            
        }
        catch {
            print("getDbMaxId() :: Fetching Data Failed")
        }
        return idToReturn
    }
    
    
    func updateCoreDataRowStatus(rowData: NSManagedObject, status: String){
        rowData.setValue(status, forKey: "status")
        do {
            try self.context.save()
           }
        catch {
            print("updateCoreDataRowStatus() :: Updating Status Failed: \(error)")
        }
        
    }
}

// Checkers
extension AppDelegate{
    // to  check if DB in core date is empty

    func checkIfDBIsEmpty(){
        let context = persistentContainer.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Photos")
        request.returnsObjectsAsFaults = false
        do {
            let result = try context.fetch(request)
            // if db is empty, this means that this is the first time for the user to use the app.
            if(result.isEmpty){
                print("First Time Use")
                // populate the database with all the images in the photo library.
                firstTimeDBPoulation()
            }
            else{
                print("Not First Time Use")
                checkForNewPhotos()
            }
        } catch {
            print("Fetching data Failed")
        }
    }
    
    
    //
    func firstTimeDBPoulation(){
        
        print("firstTimeDBPoulation")
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key:"creationDate", ascending: true)]
        let fetchResult: PHFetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: fetchOptions)
        if fetchResult.count > 0 {
            for i in 0..<fetchResult.count{
                print(i)
                openDatabseToSaveData(id: Int64(i+1), localId: fetchResult[i].localIdentifier, status: "Pending", creationDate: fetchResult[i].creationDate ?? Date())
            }
            
        }
    }
    
    
    func checkForNewPhotos(){
        
        let photoLibLatestPhotoCreationDate: Date
        let databaseLatestPhotoCreationDate: Date
        let context = persistentContainer.viewContext
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key:"creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1
        
        let fetchResult: PHFetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: fetchOptions)
        if fetchResult.count > 0 {
            photoLibLatestPhotoCreationDate = fetchResult[0].creationDate!
            //            print("Latest Photo In Lib Creation Date >> \(String(describing: photoLibLatestPhotoCreationDate))")
            
            
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Photos")
            request.returnsObjectsAsFaults = false
            request.fetchLimit = 1
            request.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            do {
                let result = try context.fetch(request)
                
                if(result.isEmpty){
                    print("checkForNewPhotos() : No Data For This Select Query")
                }
                else{
                    let NSRes = result as! [NSManagedObject]
                    databaseLatestPhotoCreationDate = NSRes[0].value(forKey: "creationDate") as! Date
                    //                    print("Latest Photo In DB Creation Date >> \(String(describing: databaseLatestPhotoCreationDate))")
                    
                    if(databaseLatestPhotoCreationDate >= photoLibLatestPhotoCreationDate){
                        pushLocalNot(title: "No New Photos ❌", description:"", runAfter: 1, wannaRepeat: false)
                    }
                    else{
                        pushLocalNot(title: "New Photos ✅", description:"", runAfter: 1, wannaRepeat: false)
                        saveNewPhotosToDB(creationDate: databaseLatestPhotoCreationDate)
                    }
                }
            } catch {
                print("Fetching data Failed")
            }
            
            
        }
        
    }
    
    
    
    func saveNewPhotosToDB(creationDate: Date){
        var latestId = getDbMaxId()
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key:"creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(
            format: "creationDate > %@", creationDate as CVarArg
        )
        let fetchResult: PHFetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: fetchOptions)
        if fetchResult.count > 0 {
            for i in 0..<fetchResult.count{
                latestId += 1
                openDatabseToSaveData( id: latestId, localId: fetchResult[i].localIdentifier, status: "Pending", creationDate: fetchResult[i].creationDate ?? Date())
            }
        }
    }
}
    

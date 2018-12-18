//
//  JSONStorage.swift
//
//  Created by Piotr Bernad on 04.04.2017.

import Foundation
import RxSwift

public enum JSONStorageType {
    case documents
    case cache
    
    var searchPathDirectory: FileManager.SearchPathDirectory {
        switch self {
        case .documents:
            return .documentDirectory
        case .cache:
            return .cachesDirectory
        }
    }
}

public enum JSONStorageError: Error {
    case wrongDocumentPath
    case couldNotCreateJSON
}

public class JSONStorage<T: Codable> {
    
    private let document: String
    private let type: JSONStorageType
    fileprivate let readSubject = PublishSubject<[T]>()
    fileprivate let saveMemoryCacheToFile: PublishSubject<Bool> = PublishSubject()
    fileprivate let useReadMemoryCache: Bool
    /// This property is used only if `useReadMemoryCache` set to true
    fileprivate let saveDebounce: TimeInterval
    private let disposeBag = DisposeBag()
    
    public typealias ItemType = T
    
    var memoryCache: Variable<[T]>

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    fileprivate lazy var storeUrl: URL? = {
        guard let dir = FileManager.default.urls(for: self.type.searchPathDirectory, in: .userDomainMask).first else {
            assertionFailure("could not find storage path")
            return nil
        }
        
        return dir.appendingPathComponent(self.document)
    }()
    
    public init(type: JSONStorageType, document: String, encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder(), useReadMemoryCache: Bool = false, saveDebounce: TimeInterval = 0.0) {
        self.type = type
        self.document = document
        self.memoryCache = Variable([])
        self.useReadMemoryCache = useReadMemoryCache
        self.saveDebounce = saveDebounce
        self.encoder = encoder
        self.decoder = decoder
        
        // Using memory cache - load data in background and setup save debouncing
        guard useReadMemoryCache else { return }
        
        self.memoryCache = Variable([])
            
        DispatchQueue.global(qos: .background).async {
            guard let storeUrl = self.storeUrl,
                    let readData = try? Data(contentsOf: storeUrl) else { return }
                
            let coder = self.decoder
                
            do {
                self.memoryCache.value = try coder.decode([T].self, from: readData)
            } catch let error {
                assertionFailure(error.localizedDescription + " - Serialization failure")
                self.memoryCache.value = []
            }
        }
        
        
        let scheduler = ConcurrentDispatchQueueScheduler(qos: .background)
        
        saveMemoryCacheToFile
            .asObservable()
            .debounce(saveDebounce, scheduler: scheduler)
            .subscribe(onNext: { [weak self] _ in
                guard let `self` = self else { return }

                self.writeToFile(self.memoryCache.value)
            }).disposed(by: self.disposeBag)


        
        NotificationCenter.default.addObserver(self, selector: #selector(receivedMemoryWarning(notification:)), name: .UIApplicationDidReceiveMemoryWarning, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .UIApplicationDidReceiveMemoryWarning, object: nil)
    }
    
    @objc func receivedMemoryWarning(notification: NSNotification) {
        print("Memory warning, releasing memory cache")
        
        guard useReadMemoryCache else { return }
        writeToFile(memoryCache.value)
        memoryCache.value = []
    }
    
    // MARK: - Read
    
    public func read() throws -> [T] {
        
        if useReadMemoryCache {
            return memoryCache.value
        }
        
        return try readFromFile()
    }
    
    private func readFromFile() throws -> [T] {
        guard let storeUrl = storeUrl else {
            throw JSONStorageError.wrongDocumentPath
        }
        
        let readData = try Data(contentsOf: storeUrl)

        let coder = self.decoder
        
        return try coder.decode([T].self, from: readData)
    }
    
    public func write(_ itemsToWrite: [T]) throws {
        
        if useReadMemoryCache {
            memoryCache.value = itemsToWrite
            readSubject.onNext(itemsToWrite)
            saveMemoryCacheToFile.onNext(true)
            return
        }
        
        writeToFile(itemsToWrite)
    }
    
    fileprivate func writeToFile(_ itemsToWrite: [T]) {
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let `self` = self else { return }
            
            let encoder = self.encoder
            
            do {
                let data = try encoder.encode(itemsToWrite)
                
                guard let storeUrl = self.storeUrl else {
                    assertionFailure("Could not store json")
                    return
                }
                
                try data.write(to: storeUrl)
                
                if self.useReadMemoryCache == false {
                    // Generate new read event for storage that
                    // do not use read cache
                    self.readSubject.onNext(itemsToWrite)
                }
                
            } catch let error {
                assertionFailure("Write Error \(error)")
            }
            
        }
    }
}

extension JSONStorage {
    public var rx_read: Observable<[T]> {
        if useReadMemoryCache == true {
            return memoryCache.asDriver().asObservable()
        }
        
        return readOnce().concat(readSubject.asObservable())
    }
}

extension JSONStorage {
    
    fileprivate func readOnce() -> Observable<[T]> {
        

        if useReadMemoryCache {
            return Observable.just(memoryCache.value)
        }
        
        return Observable.create({ [weak self] (observer) -> Disposable in
            
            guard let `self` = self, let storeUrl = self.storeUrl else {
                observer.onError(JSONStorageError.wrongDocumentPath)
                return Disposables.create()
            }
            
            guard let readData = try? Data(contentsOf: storeUrl) else {
                observer.onNext([])
                observer.onCompleted()
                return Disposables.create()
            }
            
            let coder = self.decoder
            
            let objects = try? coder.decode([T].self, from: readData)
            
            observer.onNext(objects ?? [])
            observer.onCompleted()
            
            return Disposables.create()
        })
    }
}

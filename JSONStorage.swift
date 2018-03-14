//
//  JSONStorage.swift
//
//  Created by Piotr Bernad on 04.04.2017.
//

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
    fileprivate let useMemoryCache: Bool
    private let disposeBag = DisposeBag()
    
    var memoryCache: [T]
    
    fileprivate lazy var storeUrl: URL? = {
        guard let dir = FileManager.default.urls(for: self.type.searchPathDirectory, in: .userDomainMask).first else {
            assertionFailure("could not find storage path")
            return nil
        }
        
        return dir.appendingPathComponent(self.document)
    }()
    
    public let saveMemoryCacheToFile: PublishSubject<Bool> = PublishSubject()
    
    public init(type: JSONStorageType, document: String, useMemoryCache: Bool = false) {
        self.type = type
        self.document = document
        self.memoryCache = []
        self.useMemoryCache = useMemoryCache
        
        if self.useMemoryCache {
            
            self.memoryCache = []
            
            DispatchQueue.global(qos: .background).async {
                guard let storeUrl = self.storeUrl,
                      let readData = try? Data(contentsOf: storeUrl) else { return }
                
                let coder = JSONDecoder()
                
                do {
                    self.memoryCache = try coder.decode([T].self, from: readData)
                } catch let error {
                    assertionFailure(error.localizedDescription + " - Serialization failure")
                    self.memoryCache = []
                }
            }
        }
        
        self.saveMemoryCacheToFile
            .asObservable()
            .subscribe(onNext: { [weak self] _ in
                guard let `self` = self else { return }
                self.writeToFile(self.memoryCache)
        }).disposed(by: self.disposeBag)
        
        NotificationCenter.default.addObserver(self, selector: #selector(receivedMemoryWarning(notification:)), name: NSNotification.Name.UIApplicationDidReceiveMemoryWarning, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidReceiveMemoryWarning, object: nil)
    }
    
    @objc func receivedMemoryWarning(notification: NSNotification) {
        print("memory warning, releasing memory cache")
        
        self.writeToFile(self.memoryCache)
        
        self.memoryCache = []
    }
    
    private func fileRead() throws -> [T] {
        guard let storeUrl = storeUrl else {
            throw JSONStorageError.wrongDocumentPath
        }
        
        let readData = try Data(contentsOf: storeUrl)
    
        let coder = JSONDecoder()
        
        return try coder.decode([T].self, from: readData)
    }
    
    public func read() throws -> [T] {
        
        if self.useMemoryCache {
            return self.memoryCache
        }
        
        return try fileRead()
    }
    
    public func write(_ itemsToWrite: [T]) throws {
        
        if self.useMemoryCache {
            self.memoryCache = itemsToWrite
            
            self.saveMemoryCacheToFile.onNext(true)
            
            return
        }
        
        writeToFile(itemsToWrite)

    }
    
    func writeToFile(_ itemsToWrite: [T]) {
        
        DispatchQueue.global(qos: .background).async {
            
            let encoder = JSONEncoder()
            
            do {
                let data = try encoder.encode(itemsToWrite)
                
                guard let storeUrl = self.storeUrl else {
                    assertionFailure("Could not store json")
                    return
                }
                
                try data.write(to: storeUrl)
                
            } catch let error {
                assertionFailure("Write Error \(error)")
            }
            
        }
    }
    
}

extension JSONStorage {
    
    public func rx_read() -> Observable<[T]> {
        
        if self.useMemoryCache {
            return Observable.just(self.memoryCache)
        }
        
        return Observable.create({ (observer) -> Disposable in
            
            guard let storeUrl = self.storeUrl else {
                observer.onError(JSONStorageError.wrongDocumentPath)
                return Disposables.create { }
            }
            
            guard let readData = try? Data(contentsOf: storeUrl) else {
                    observer.onNext([])
                    return Disposables.create { }
            }
            
            let coder = JSONDecoder()
            
            let objects = try? coder.decode([T].self, from: readData)
            
            observer.onNext(objects ?? [])
            
            return Disposables.create {
                
            }
        })
    }
}

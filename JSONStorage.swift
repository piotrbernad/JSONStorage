//
//  JSONStorage.swift
//  zinnow
//
//  Created by Piotr Bernad on 04.04.2017.
//  Copyright © 2017 Zumba Fitness, LLC. All rights reserved.
//

import Foundation
import JSONCodable
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

public class JSONStorage<T: JSONCodable> {
    
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
                    let readData = try? Data(contentsOf: storeUrl),
                    let json = try? JSONSerialization.jsonObject(with: readData, options: .allowFragments),
                    let jsonArray = json as? [JSONObject]
                    else {
                        return
                }
                
                do {
                    self.memoryCache = try [T].init(JSONArray: jsonArray)
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
        let json = try JSONSerialization.jsonObject(with: readData, options: .allowFragments)
        
        guard let jsonArray = json as? [JSONObject] else { return [] }
        
        do {
            return try [T].init(JSONArray: jsonArray)
        } catch let error {
            assertionFailure(error.localizedDescription + " - Serialization failure")
            return []
        }
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
        
            let jsonArray = itemsToWrite.map { $0.jsonRepresentation() }
            
            guard let jsonData = jsonArray.data else {
                assertionFailure("Could not store json")
                return
            }
            
            guard let storeUrl = self.storeUrl else {
                assertionFailure("Could not store json")
                return
            }
            
            do {
                try jsonData.write(to: storeUrl)
            } catch let error {
                print( error)
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
            
            guard let readData = try? Data(contentsOf: storeUrl),
                let json = try? JSONSerialization.jsonObject(with: readData, options: .allowFragments) else {
                    observer.onNext([])
                    return Disposables.create { }
            }
            
            guard let jsonArray = json as? [JSONObject] else {
                observer.onNext([])
                return Disposables.create { }
            }
            
            do {
                let array = try [T].init(JSONArray: jsonArray)
                observer.onNext(array)
            } catch let error {
                assertionFailure(error.localizedDescription + " - Serialization failure")
            }
            
            return Disposables.create {
                
            }
        })
    }
}

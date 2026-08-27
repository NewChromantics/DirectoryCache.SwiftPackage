import Foundation
import Combine




extension Dictionary 
{
	mutating func syncKeys(to keys: [Key], makeValue: (Key) -> Value) 
	{
		let keySet = Set(keys)
		removeAll { key,value in !keySet.contains(key) }
		for key in keys where self[key] == nil 
		{
			self[key] = makeValue(key)
		}
	}
	
	mutating func removeAll(where filter: (Key, Value) -> Bool)
	{
		for (key, value) in self where filter(key, value)
		{
			removeValue(forKey: key)
		}
	}
}



//	store each file url by a key which may have some additional cache
//	that we only want to generate once. eg. parse filename to some CSV meta
public protocol UrlCacheKey : Hashable
{
	var filename : String			{get}	//	does not include path
	var fileExtension : String		{get}
	
	init?(fileUrl:URL)
}

// Watches a directory on disk and maintains a cached list of its file urls
public actor DirectoryCache<UrlKey:UrlCacheKey>
{
	private let directoryUrl : URL

	//	nil means the cache is dirty next request will re-enumerate
	private var urlCache : [UrlKey:URL]? = nil
	private var monitor : DispatchSourceFileSystemObject? = nil
	
	
	var urlsWithKeys : [UrlKey:URL]		{	return urlCache ?? scan()	}
	var urls : [URL]					{	Array(urlsWithKeys.values)	}
	var urlKeys : Set<UrlKey>			{	Set(urlsWithKeys.keys)	}


	public init(directoryUrl: URL)
	{
		self.directoryUrl = directoryUrl
	}

	public func GetCachedFileUrl(key:UrlKey) -> URL?
	{
		return urlsWithKeys[key]
	}
	
	private func GetWriteUrl(for key:UrlKey) -> URL
	{
		directoryUrl.appendingPathComponent("\(key.filename).\(key.fileExtension)")
	}

	/// Append a URL that we know has just been written, without triggering a
	/// full re-scan. Removes any existing entry with the same path first.
	func append(_ url: URL)
	{
		//	we drop those that return a nil key
		guard let key = UrlKey(fileUrl: url) else
		{
			return
		}
		urlCache?.updateValue( url, forKey: key)
		startMonitoringIfNeeded()
	}

	// Remove URLs that we know have just been deleted, without triggering a full re-scan.
	func OnFilesDeleted(urls:[URL])
	{
		urlCache?.removeAll
		{
			key,url in
			urls.contains(url)
		}
	}

	
	/// Drop the entire cached list. The next call to `urls()` will re-scan.
	func invalidate()
	{
		urlCache = nil
	}


	private func scan() -> [UrlKey:URL]
	{
		startMonitoringIfNeeded()

		//	clear then append all
		urlCache = [:]
		
		guard let contents = try? FileManager.default.contentsOfDirectory(
			at: directoryUrl,
			includingPropertiesForKeys: nil,
			options: .skipsHiddenFiles)
		else
		{
			return [:]
		}

		contents.forEach{ self.append($0) }
		//	append shouldn't have cleared this
		return urlCache!// ?? [:]
	}

	private func startMonitoringIfNeeded()
	{
		guard monitor == nil else { return }

		//	The folder must exist before we can open a file-descriptor on it.
		try? FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)

		let fd = open(directoryUrl.path, O_EVTONLY)
		guard fd >= 0 else { return }

		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fd,
			eventMask: [.write, .delete, .rename],
			queue: .global(qos: .utility)
		)

		source.setEventHandler { [weak self] in
			Task { await self?.invalidate() }
		}

		source.setCancelHandler {
			close(fd)
		}

		monitor = source
		source.resume()
	}
}

//	helpful extensions
public extension DirectoryCache
{
	func GetFileContents<FileType:Decodable,DecoderType:TopLevelDecoder>(key: UrlKey, decoder: DecoderType) throws -> FileType? where DecoderType.Input == Data
	{
		guard let data = try GetFileData(key: key) else
		{
			return nil
		}
		return try decoder.decode(FileType.self, from: data)
	}
	
	func GetFileData(key:UrlKey) throws -> Data?
	{
		guard let url = GetCachedFileUrl(key: key) else
		{
			return nil
		}
		return try Data(contentsOf: url)
	}
	
	@discardableResult
	func Write<FileType:Encodable,EncoderType:TopLevelEncoder>(key:UrlKey,fileContents:FileType,encoder:EncoderType) throws -> URL where EncoderType.Output == Data
	{
		let data = try encoder.encode(fileContents)
		
		return try Write(key: key, fileContents: data)
	}
	
	
	@discardableResult
	func Write(key:UrlKey,fileContents:Data) throws -> URL
	{
		//	write to disk
		let fileUrl = GetWriteUrl(for: key)
		try FileManager.default.createDirectory(at: fileUrl.deletingLastPathComponent(),
												withIntermediateDirectories: true)
		try fileContents.write(to: fileUrl, options: .atomic)
		
		//	Keep the directory cache up-to-date without triggering a re-scan.
		append(fileUrl)
		return fileUrl
	}
}


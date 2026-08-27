import Foundation
import Combine



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
	
	
	public var urlsWithKeys : [UrlKey:URL]	{	return urlCache ?? ReadDirectory()	}
	public var urls : [URL]					{	Array(urlsWithKeys.values)	}
	public var urlKeys : Set<UrlKey>		{	Set(urlsWithKeys.keys)	}

	public init(directoryUrl: URL) throws
	{
		self.directoryUrl = directoryUrl
		try StartMonitoringIfNeeded()
	}

	public func GetCachedFileUrl(key:UrlKey) -> URL?
	{
		return urlsWithKeys[key]
	}
	
	private func GetWriteUrl(for key:UrlKey) -> URL
	{
		directoryUrl.appendingPathComponent("\(key.filename).\(key.fileExtension)")
	}

	//	Append a URL that we know has just been written, without triggering a
	//	full re-scan. Removes any existing entry with the same path first.
	func OnFileWritten(_ url: URL)
	{
		//	we drop those that return a nil key
		guard let key = UrlKey(fileUrl: url) else
		{
			return
		}
		urlCache?.updateValue( url, forKey: key)
	}

	// Remove URLs that we know have just been deleted, without triggering a full re-scan.
	//	note: auto-update-scanner should detect this itself
	public func OnFilesDeleted(urls:[URL])
	{
		urlCache?.removeAll
		{
			key,url in
			urls.contains(url)
		}
	}

	
	//	Drop the entire cached list. The next call to `urls()` will re-scan.
	func OnFileWrittenDeletedOrRenamed()
	{
		urlCache = nil
	}


	private func ReadDirectory() -> [UrlKey:URL]
	{
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

		contents.forEach
		{
			self.OnFileWritten($0) 
		}
		//	append shouldn't have cleared this
		return urlCache!// ?? [:]
	}

	private func Open(path: String) throws -> Int32
	{
		let fd = open(path, O_EVTONLY)
		guard fd >= 0 else
		{
			let errorCode = errno
			let errorDescription = String(cString: strerror(errorCode))
			throw DictionaryCacheError("Failed to open path (\(path)) for monitoring: \(errorDescription) (errno=\(errorCode))")
		}
		return fd
	}

	private func StartMonitoringIfNeeded() throws
	{
		guard monitor == nil else 
		{
			return 
		}

		//	ensure directory exists
		do
		{
			//	The folder must exist before we can open a file-descriptor on it.
			//	This will throw if a file already exists at this path, or if there are permission issues
			try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
		}
		catch CocoaError.fileWriteFileExists
		{
			//	Check if it's a directory (OK) or a file (error)
			var isDirectory: ObjCBool = false
			if FileManager.default.fileExists(atPath: directoryUrl.path, isDirectory: &isDirectory)
			{
				if isDirectory.boolValue
				{
					//	Directory already exists, this is fine - don't throw
				}
				else
				{
					//	A file exists at this path where we need a directory
					throw DictionaryCacheError("Cannot create directory at \(directoryUrl.path): a file already exists at this location")
				}
			}
		}
		catch
		{
			//	Throw other errors (permissions, disk full, etc.) as we need this directory to exist
			throw error
		}
			
		let fd = try Open(path: directoryUrl.path)

		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fd,
			eventMask: [.write, .delete, .rename],
			queue: .global(qos: .utility)
		)

		source.setEventHandler 
		{
			[weak self] in
			Task 
			{
				await self?.OnFileWrittenDeletedOrRenamed() 
			}
		}

		source.setCancelHandler 
		{
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
		OnFileWritten(fileUrl)
		return fileUrl
	}
}


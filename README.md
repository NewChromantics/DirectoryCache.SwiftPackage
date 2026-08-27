DirectoryCache.SwiftPackage
===========================

Class which monitors a directory on disk and keeps a cache of urls, 
key'd by user's `UrlCacheKey` implementation, which allows some
process-once meta generation per file, for fast (dictionary) lookup by 
client.

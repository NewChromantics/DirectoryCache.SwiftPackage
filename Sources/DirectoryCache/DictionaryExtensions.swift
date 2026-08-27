
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



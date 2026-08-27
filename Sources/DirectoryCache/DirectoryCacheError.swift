//import SwiftUI

public struct DictionaryCacheError : Error
{
	let description: String
	
	public init(_ description: String) 
	{
		self.description = description
	}
	
	public var errorDescription: String? 
	{
		description
	}
}

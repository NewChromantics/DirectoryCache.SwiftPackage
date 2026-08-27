// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.


import PackageDescription



let package = Package(
	name: "DirectoryCache",
	
	platforms: [
		.iOS(.v15),
		.macOS(.v10_13)
	],
	

	products: [
		.library(
			name: "DirectoryCache",
			targets: [
				"DirectoryCache"
			])
	],
	targets: [

		.target(
			name: "DirectoryCache",
			dependencies: []
		)
	]
)

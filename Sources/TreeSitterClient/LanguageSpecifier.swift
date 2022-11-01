//
//  LanguageSpecifier.swift
//  
//
//  Created by Daniel Jalkut on 10/26/22.
//

import Foundation
import SwiftTreeSitter

public struct LanguageSpecifier {

	public let language: Language

	public let highlightingQuery: Query?
	public let injectionQuery: Query?

	public init(language: Language, highlightingQuery: Query? = nil, injectionQuery: Query? = nil) {
		self.language = language
		self.highlightingQuery = highlightingQuery
		self.injectionQuery = injectionQuery
	}

}

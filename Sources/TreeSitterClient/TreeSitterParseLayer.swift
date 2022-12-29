import Foundation
import SwiftTreeSitter

// NOTE: This is a work-in-progress. Here is a list of outstanding implementation details that remain to be done:
//
// Core functionality:
//
//		- Support setting ranges on the parser to allow for example sublayers to parse only a given language as subtrees
//
// Support for injection query qualifiers that impact how the parsing should be done:
//
//		- ignore_children
//		- language.combined
//
// Optimizations:
//
//		- Only parse injections for changed subset of tree?
//

public struct TreeSitterParseLayer {

	// A parse layer represents a parser for a specific language, and all the
	// native TreeSitter trees that resulted from parsing at that layer with that language.
	public let text: String
	public var rangesToParse: [TSRange]
	public let baseLanguage: LanguageSpecifier

	// Injected languages are represented by a name as it is expected
	// to be identified from the name of an injection query result,
	// for example "html" or "markdown_inline"
	let injectedLanguages: [String:LanguageSpecifier]

	let parser: Parser

	// We maintain an array of trees rather than just one tree, because even though
	// TreeSitter supports setting the ranges of a source document that should be considered
	// when parsing a particular language, the choice of whether to do this is dictated
	// by the presence or absence of an "injection.combined" attribute on the injection.
	public var trees: [Tree]

	// #warning("temporary workaround")
	var tree: Tree? { return trees.first }

	// Sublayers are created for each of the separate injected languages that are discovered
	// during this layer's parsing, and which should be independently parsed. This dictionary
	// is keyed by the language name. Any subtrees that are generated for this language at this level
	// are grouped within the same parser "layer".
	public var subLayers: [String:TreeSitterParseLayer]

	init(text: String, baseLanguage: LanguageSpecifier, injectedLanguages: [String:LanguageSpecifier]) throws {
		self.text = text
		self.rangesToParse = [] // if empty, parse whole text
		self.baseLanguage = baseLanguage
		self.injectedLanguages = injectedLanguages
        self.parser = Parser()
		try self.parser.setLanguage(baseLanguage.language)
		self.trees = []
		self.subLayers = [:]
    }

	func tree(in range: Range<UInt32>) -> Tree? {
		return self.trees.first { tree in
			guard let node = tree.rootNode else { return false }
			let thisRange = node.range
			return NSLocationInRange(Int(range.lowerBound), thisRange) && NSLocationInRange(Int(range.upperBound), thisRange)
		}
	}

    func node(in range: Range<UInt32>) -> Node? {
		guard let tree = tree(in: range), let root = tree.rootNode else {
            return nil
        }

        return root.descendant(in: range)
    }

	mutating func parse(readHandler: @escaping Parser.ReadBlock, forceReparse: Bool = false) -> TreeSitterParseLayer {
		var newState = self.copy()
		newState.trees = []

		let waitingGroup = DispatchGroup()
		waitingGroup.enter()

		if self.rangesToParse.count > 0 {
			self.parser.includedRanges = self.rangesToParse
		}

		if forceReparse || self.trees.count == 0 {
			if let updatedTree = self.parser.parse(tree: nil, readBlock: readHandler) {
				newState.trees.append(updatedTree)
			}
		}
		else {
			for tree in self.trees {
				if let updatedTree = self.parser.parse(tree: tree, readBlock: readHandler) {
					newState.trees.append(updatedTree)
				}
			}
		}

		// Always run a new injections query on the freshly updated tree, obtaining an up-to-date
		// list of the injected blocks we are tracking
		// TODO: Can we limit the injection search here to only areas that changed? For now just reparse always
		newState.subLayers = [:]
		if let injectionQuery = self.baseLanguage.injectionQuery {
			waitingGroup.enter()
			newState.executeInjectionsQuery(injectionQuery) { result in
				switch result {
					case .success(let blocks):
						for block in blocks {
							let languageName = block.name
							if let injectedLanguage = newState.injectedLanguages[languageName] {
								var existingLayer = newState.subLayers[languageName]
								if existingLayer == nil {
									guard let addedLayer = try? TreeSitterParseLayer(text: self.text, baseLanguage: injectedLanguage, injectedLanguages: self.injectedLanguages) else {
										continue
									}
									existingLayer = addedLayer
									newState.subLayers[languageName] = addedLayer
								}
								newState.subLayers[languageName]!.rangesToParse.append(block.tsRange)
							}
						}
					case .failure(_):
						// Don't need to propagate errors with injections, just ignore the section
						break
				}
				waitingGroup.leave()
			}
		}

		// Recursively parse any sublayers
		let oldSubLayers = newState.subLayers
		newState.subLayers = [:]
		for (language, var subLayer) in oldSubLayers {
			newState.subLayers[language] = subLayer.parse(readHandler: readHandler)
		}

		waitingGroup.leave()
		waitingGroup.wait()

		return newState
	}

	func applyEdit(_ edit: InputEdit, layer: TreeSitterParseLayer? = nil) {
		let targetLayer = layer ?? self
		for tree in targetLayer.trees {
			tree.edit(edit)
		}
		// This is causing a crash.
//		for subLayer in targetLayer.subLayers.values {
//			applyEdit(edit, layer: subLayer)
//		}
    }

	// #warning("Adapt to new hierarchical tree layers")
    func changedByteRanges(for otherState: TreeSitterParseLayer) -> [Range<UInt32>] {
        let otherTree = otherState.tree

        switch (tree, otherTree) {
        case (let t1?, let t2?):
            return t1.changedRanges(from: t2).map({ $0.bytes })
        case (nil, let t2?):
            let range = t2.rootNode?.byteRange

            return range.flatMap({ [$0] }) ?? []
        case (_, nil):
            return []
        }
    }

    func copy() -> TreeSitterParseLayer {
		var copyLayer = try! TreeSitterParseLayer(text: self.text, baseLanguage: self.baseLanguage, injectedLanguages: self.injectedLanguages)
		copyLayer.trees = self.trees.compactMap { $0.copy() }
		for (languageName, layer) in self.subLayers {
			copyLayer.subLayers[languageName] = layer.copy()
		}
		return copyLayer
    }
}

// Injection support - this is redundant with code in TreeSitterClient but I want to get things working
// before the teardown/buildup that might be required to, for example, possibly move all the query fundamentals into
// TreeSitterParseLayer.
extension TreeSitterParseLayer {

	private func executeQuerySynchronouslyWithoutCheck(_ query: Query, in range: NSRange? = nil, with state: TreeSitterParseLayer) -> Result<QueryCursor, TreeSitterClientError> {
		guard let node = state.tree?.rootNode else {
			return .failure(TreeSitterClientError.stateInvalid)
		}

		// critical to keep a reference to the tree, so it survives as long as the query
		let cursor = query.execute(node: node, in: state.tree)

		if let range = range {
			cursor.setRange(range)
		}

		return .success(cursor)
	}

	private func executeResolvingQuerySynchronouslyWithoutCheck(_ query: Query, in range: NSRange? = nil, with state: TreeSitterParseLayer) -> Result<ResolvingQueryCursor, TreeSitterClientError> {
		return executeQuerySynchronouslyWithoutCheck(query, in: range, with: state)
			.map({ ResolvingQueryCursor(cursor: $0) })
	}

	/// Execute a standard injections.scm query
	///
	/// Note that some injection query definitions require evaluating the text content, which is only possible by supplying a `textProvider`.
	public func executeInjectionsQuery(_ query: Query,
									   in range: NSRange? = nil,
									   completionHandler: (Result<[NamedRange], TreeSitterClientError>) -> Void) {
		let cursorResult = executeResolvingQuerySynchronouslyWithoutCheck(query, in: range, with: self)
		let result = cursorResult.map({ cursor in
			cursor.compactMap({ $0.injection(with: nil) })
		})

			completionHandler(result)
	}

}

extension Parser {

    func parse(state: TreeSitterParseLayer, string: String, limit: Int? = nil) -> TreeSitterParseLayer {
		var newTrees: [Tree] = []
		for tree in state.trees {
			if let updatedTree = parse(tree: tree, string: string, limit: limit) {
				newTrees.append(updatedTree)
			}
		}

		var newState = state.copy()
		newState.trees = newTrees
		return newState
    }

}

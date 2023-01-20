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

/// A language layer represents 1 or more trees parsed by a particular language. Typically
/// the base layer for any parsing scenario will contain just one tree, representing the high-level
/// parsing of the whole document. Sub-layers are created for any injections at that particular
/// level of the injection hierarchy. For example an HTML document with two distinct <script>
/// nodes and one embedded <style> declaration might (assuming the language support is
/// provided by the client) result in a one base layer representing HTML, with one tree, one
/// sublayer representing JavaScript, with two trees, and one sublayer representing CSS, with
/// one tree.

public struct TreeSitterParseLayer {

	public let baseLanguage: LanguageSpecifier

	public var rangesToParse: [TSRange]

	// If true, parse a single tree based on all the ranges. If false,
	// parse a separate tree for each distinct range.
	public var combineRanges = false

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

	// As we move towards supporting multiple trees, there are still code paths that rely upon
	// defaulting to the "main tree", so just return the first one.
	var tree: Tree? { return trees.first }

	// Sublayers are created for each of the separate injected languages that are discovered
	// during this layer's parsing, and which should be independently parsed. This dictionary
	// is keyed by the language name. Any subtrees that are generated for this language at this level
	// are grouped within the same parser "layer".
	public var subLayers: [String:TreeSitterParseLayer]

	init(baseLanguage: LanguageSpecifier, injectedLanguages: [String:LanguageSpecifier]) throws {
		self.rangesToParse = [] // if empty, parse all
		self.baseLanguage = baseLanguage
		self.injectedLanguages = injectedLanguages
        self.parser = Parser()
		try self.parser.setLanguage(baseLanguage.language)
		self.trees = []
		self.subLayers = [:]
    }

	// These are not used for now but could be handy in optimizing things. I think though we may need to
	// consider the case where more than one tree correlates with a given range. For example if the document's whole
	// range is given ... should we change this to `trees..`?
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
		var newTrees: [Tree] = []

		let waitingGroup = DispatchGroup()
		waitingGroup.enter()

		let parseOneTree = self.combineRanges || self.rangesToParse.count <= 1
		if parseOneTree {
			let oldTree = forceReparse ? nil : self.trees.first
			self.parser.includedRanges = self.rangesToParse
			if let updatedTree = self.parser.parse(tree: oldTree, readBlock: readHandler) {
				newTrees.append(updatedTree)
			}
		}
		else {
			let useOldTrees = forceReparse ? false : self.trees.count == self.rangesToParse.count
			for (index, range) in rangesToParse.enumerated() {
				let oldTree = useOldTrees ? self.trees[index] : nil
				self.parser.includedRanges = [range]
				if let updatedTree = self.parser.parse(tree: oldTree, readBlock: readHandler) {
					newTrees.append(updatedTree)
				}
			}
		}

		newState.trees = newTrees

		// Always run a new injections query on the freshly updated trees, obtaining an up-to-date
		// list of the injected blocks we are tracking
		// TODO: Can we limit the injection search here to only subLayers with areas that changed? For now just reparse always
		newState.subLayers = [:]
		if let injectionQuery = self.baseLanguage.injectionQuery {
			waitingGroup.enter()
			// TODO: Should determine when capturing injection points whether the
			// combineRanges property should be set on the pertinent parse layer.
			newState.executeInjectionsQuery(injectionQuery) { result in
				switch result {
					case .success(let blocks):
						for block in blocks {
							let languageName = block.name
							if let injectedLanguage = newState.injectedLanguages[languageName] {
								var existingLayer = newState.subLayers[languageName]
								if existingLayer == nil {
									guard let addedLayer = try? TreeSitterParseLayer(baseLanguage: injectedLanguage, injectedLanguages: self.injectedLanguages) else {
										continue
									}
									existingLayer = addedLayer
									newState.subLayers[languageName] = addedLayer

									// Special case - force HTML to parse as a single document
									if languageName == "html" {
										newState.subLayers[languageName]?.combineRanges = true
									}
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

		waitingGroup.leave()
		waitingGroup.wait()

		// Recursively parse any sublayers
		let oldSubLayers = newState.subLayers
		newState.subLayers = [:]
		for (language, var subLayer) in oldSubLayers {
			newState.subLayers[language] = subLayer.parse(readHandler: readHandler)
		}

		// Set to DEBUG to print debug info about the parse tree
#if false
		print("After parsing:\n\(newState.debugDescription())")
#endif
		return newState
	}

#if DEBUG
	func debugDescription(_ indentString: String = "") -> String {
		var description = "\n\(indentString)LAYER:\n"
		let nextIndentString = indentString + "  "
		for tree in self.trees {
			let treeString = tree.rootNode?.sExpressionString ?? "NULL"
			description.append("\(nextIndentString)TREE: \(treeString)\n")
		}

		for layer in self.subLayers.values {
			description.append("\(nextIndentString)\(layer.debugDescription(nextIndentString))")
		}
		return description
	}
#endif

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

		// As a stop-gap solution add the entire range of subLayers - until and unless
		// we can do a more optimal job detecting and including just the actual changes within?
		var baseRanges: [Range<UInt32>] = []

        switch (tree, otherTree) {
        case (let t1?, let t2?):
			baseRanges = t1.changedRanges(from: t2).map({ $0.bytes })
		case (nil, let t2?):
            let range = t2.rootNode?.byteRange
			baseRanges = range.flatMap({ [$0] }) ?? []
        case (_, nil):
            baseRanges = []
        }

		for subLayer in self.subLayers.values {
			baseRanges += subLayer.rangesToParse.map { $0.bytes }
		}
		
		return baseRanges
    }

    func copy() -> TreeSitterParseLayer {
		var copyLayer = try! TreeSitterParseLayer(baseLanguage: self.baseLanguage, injectedLanguages: self.injectedLanguages)
		copyLayer.rangesToParse = self.rangesToParse
		copyLayer.trees = self.trees.compactMap { $0.copy() }
		for (languageName, layer) in self.subLayers {
			copyLayer.subLayers[languageName] = layer.copy()
		}
		return copyLayer
    }
}

// Query support - this is redundant with code in TreeSitterClient but I want to get things working
// before the teardown/buildup that might be required to, for example, possibly move all the query fundamentals into
// TreeSitterParseLayer.

extension TreeSitterParseLayer {

	private func executeQuerySynchronouslyWithoutCheck(_ query: Query, in range: NSRange? = nil, with tree: Tree) -> Result<QueryCursor, TreeSitterClientError> {
		guard let node = tree.rootNode else {
			return .failure(TreeSitterClientError.stateInvalid)
		}

		// critical to keep a reference to the tree, so it survives as long as the query
		let cursor = query.execute(node: node, in: tree)

		if let range = range {
			cursor.setRange(range)
		}

		return .success(cursor)
	}

	private func executeResolvingQuerySynchronouslyWithoutCheck(_ query: Query, in range: NSRange? = nil, with tree: Tree) -> Result<ResolvingQueryCursor, TreeSitterClientError> {
		return executeQuerySynchronouslyWithoutCheck(query, in: range, with: tree)
			.map({ ResolvingQueryCursor(cursor: $0) })
	}

	/// Execute a standard injections.scm query
	///
	/// Note that some injection query definitions require evaluating the text content, which is only possible by supplying a `textProvider`.
	public func executeInjectionsQuery(_ query: Query,
									   in range: NSRange? = nil,
									   completionHandler: (Result<[NamedRange], TreeSitterClientError>) -> Void) {
		var injectionRanges: [NamedRange] = []

		let waitingGroup = DispatchGroup()
		waitingGroup.enter()

		for tree in self.trees {
			let cursorResult = executeResolvingQuerySynchronouslyWithoutCheck(query, in: range, with: tree)
			let result = cursorResult.map({ cursor in
				cursor.compactMap({ $0.injection(with: nil) })
			})
			switch result {
				case .success(let blocks):
					injectionRanges.append(contentsOf: blocks)
				case .failure(_):
					// Just ignore failures since we're hoping to get as much as we can from as many trees as possible
					continue
			}
		}

		waitingGroup.leave()
		waitingGroup.wait()

		completionHandler(Result.success(injectionRanges))
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
